using System.Text.Json.Nodes;
using System.Threading.Channels;
using Recorder.Backend;
namespace Recorder.Windows;

public sealed class RecordingSession(AppSettings config) : IAsyncDisposable
{
    private readonly DesktopBackend backend = DesktopBackend.Shared;
    private readonly string id = Guid.NewGuid().ToString("N");
    private readonly CancellationTokenSource cancel = new(), inputCancel = new();
    private readonly TaskCompletionSource complete = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Channel<byte[]> outgoing = Channel.CreateBounded<byte[]>(100);
    private readonly Dictionary<int, TranscriptRow> rows = new();
    private readonly Dictionary<int, SortedDictionary<int, string>> translations = new();
    private AudioInput? input;
    private ProcessLoopbackInput? loopback;
    private LivePlayer? player;
    private LivePlaybackQueue? playback;
    private bool playbackFailed;
    private StreamingClient? stream;
    private Task? fileTask, sender;
    private long audioBytes, sequence;
    private int stopping;
    private bool started;
    public double AudioSeconds => Interlocked.Read(ref audioBytes) / 32000.0;
    public Task Completion => complete.Task;
    public event Action<TranscriptRow>? Row;
    public event Action<string>? Partial;
    public event Action<string>? Notice;
    public event Action<float>? Level;
    public event Action? FileEnded;
    public async Task StartAsync(int source, int microphone, string? file)
    {
        if (config.Mode != "live")
        {
            await backend.EnsureAsync(config, cancel.Token);
            backend.Register(id, Receive);
        }
        else await backend.SuspendAsync(cancel.Token);
        if (config.Mode is "stream" or "live")
        {
            stream = new(config); stream.Partial += text => Partial?.Invoke(text);
            stream.Row += row =>
            {
                if (config.Mode == "live") { Row?.Invoke(row with { AudioId = id + ":live:" + row.Id }); return; }
                if (!row.Final || !int.TryParse(row.Id.AsSpan(4), out int number)) return;
                var message = DesktopBackend.Command("asr_stream_final", id);
                message["segment_id"] = number; message["start_sample"] = (long)(row.Seconds * 16000); message["text"] = row.Text;
                _ = backend.Channel.ControlAsync(message);
            };
            if (config.Mode == "live")
            {
                LiveHistory.Cache.BeginSession();
                if (config.LiveAudioOutput)
                {
                    playback = new(config.LiveTiming == "final"); player = new(); player.Failure += text => { playbackFailed = true; Notice?.Invoke(text); };
                    try { player.Start(config.LiveVolume); } catch (Exception ex) { playbackFailed = true; Notice?.Invoke("译音播放不可用，字幕继续更新：" + ex.Message); }
                }
                stream.LiveEvent += (message, transcript) =>
                {
                    var rows = transcript.Snapshot(); LiveHistory.Cache.Consume(message, rows, id);
                    if (playback == null || playbackFailed) return;
                    try { foreach (var pcm in playback.Consume(message, rows)) player!.Append(pcm); }
                    catch (Exception ex) { playbackFailed = true; Notice?.Invoke(ex.Message); }
                };
            }
            await stream.ConnectAsync(cancel.Token);
            sender = Task.Run(SendAsync);
        }
        cancel.Token.ThrowIfCancellationRequested();
        if (config.Mode != "live") await backend.Channel.ControlAsync(DesktopBackend.Command("start", id));
        started = true;
        if (source == 2)
        {
            fileTask = Task.Run(async () =>
            {
                try { await AudioInput.ReadFileAsync(file!, Append, true, inputCancel.Token); }
                catch (OperationCanceledException) when (inputCancel.IsCancellationRequested) { }
                catch (Exception ex) { complete.TrySetException(ex); }
            });
            _ = FinishFileAsync(fileTask);
        }
        else
        {
            if (source == 1)
            {
                loopback = new(); loopback.Data += Append; loopback.Ended += ex => { if (ex != null) { complete.TrySetException(ex); _ = Task.Run(StopAsync); } };
                await Task.Run(loopback.Start, cancel.Token); return;
            }
            input = new(); input.Data += Append;
            input.Ended += ex => { if (ex != null) { complete.TrySetException(ex); _ = StopAsync(); } };
            input.Start(source == 1, microphone);
        }
    }
    private async Task FinishFileAsync(Task reading)
    {
        await reading; FileEnded?.Invoke();
        try { await StopAsync(); } catch (Exception ex) { complete.TrySetException(ex); }
    }
    private void Append(byte[] pcm)
    {
        if (cancel.IsCancellationRequested) return;
        var start = Interlocked.Add(ref audioBytes, pcm.Length) - pcm.Length;
        bool accepted = stream == null ? backend.Channel.Audio(id, sequence++, start / 2, pcm) : outgoing.Writer.TryWrite(pcm);
        if (!accepted) { Notice?.Invoke("音频缓冲已满，正在排空已接收的尾句。"); _ = Task.Run(StopAsync); }
        float peak = 0;
        for (int i = 0; i + 1 < pcm.Length; i += 2) peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(pcm, i) / 32768f));
        Level?.Invoke(peak);
    }
    private async Task SendAsync()
    {
        try
        {
            var sending = SendPacketsAsync();
            var first = await Task.WhenAny(sending, stream!.Completion);
            if (first == stream.Completion) await stream.Completion;
            await sending; await stream.FinishAsync(cancel.Token);
        }
        catch (Exception ex) { complete.TrySetException(ex); inputCancel.Cancel(); }
    }
    private async Task SendPacketsAsync()
    { await foreach (var pcm in outgoing.Reader.ReadAllAsync(cancel.Token)) await stream!.AppendAsync(pcm, cancel.Token); }
    private void Receive(JsonObject message)
    {
        string type = (string)message["type"]!;
        switch (type)
        {
            case "partial": Partial?.Invoke((string?)message["text"] ?? ""); break;
            case "final":
                int segment = (int)message["segment_id"]!;
                var row = new TranscriptRow(segment.ToString(), (long?)message["start_sample"] / 16000.0 ?? 0, (string?)message["text"] ?? "");
                rows[segment] = row; Row?.Invoke(row); Partial?.Invoke(""); break;
            case "translation":
                int target = (int)message["segment_id"]!, unit = checked((int)Recorder.Backend.BackendJson.Integer(message["unit_id"]));
                if (!rows.TryGetValue(target, out var original)) break;
                if (!translations.TryGetValue(target, out var parts)) translations[target] = parts = new();
                parts[unit] = (string?)message["text"] ?? "";
                rows[target] = original with { Translation = string.Join(" ", parts.Values.Where(p => p.Length > 0)) }; Row?.Invoke(rows[target]); break;
            case "error": Notice?.Invoke((string?)message["message"] ?? "后端错误。"); break;
            case "status":
                var state = (string?)message["state"];
                if (started && state == "ready") complete.TrySetResult();
                if (state == "error") complete.TrySetException(new InvalidOperationException((string?)message["detail"] ?? "识别服务失败，已有文字已保留。"));
                break;
        }
    }
    public async Task StopAsync()
    {
        if (Interlocked.Exchange(ref stopping, 1) == 0)
        {
            inputCancel.Cancel();
            if (input != null) await input.StopAsync();
            if (loopback != null) await loopback.StopAsync();
            if (fileTask != null) await fileTask;
            outgoing.Writer.TryComplete();
            if (sender != null) await sender;
            if (config.Mode == "live")
            {
                if (playback?.HasPending == true) Notice?.Invoke("部分译音未完成关联，已保留字幕。");
                if (player != null) await player.FinishAsync(cancel.Token);
                complete.TrySetResult();
            }
            else if (started) await backend.Channel.ControlAsync(DesktopBackend.Command("stop", id));
            else complete.TrySetCanceled();
        }
        await Completion;
    }
    public void Cancel()
    {
        cancel.Cancel(); inputCancel.Cancel(); outgoing.Writer.TryComplete();
        if (started && config.Mode != "live") _ = backend.Channel.ControlAsync(DesktopBackend.Command("stop", id));
        complete.TrySetCanceled();
    }
    public async ValueTask DisposeAsync()
    {
        Cancel();
        if (input != null) { try { await input.StopAsync(); } catch { } input.Dispose(); }
        if (loopback != null) { try { await loopback.StopAsync(); } catch { } loopback.Dispose(); }
        if (fileTask != null) { try { await fileTask; } catch { } }
        if (stream != null) await stream.DisposeAsync();
        if (sender != null) { try { await sender; } catch { } }
        player?.Dispose();
        cancel.Dispose(); inputCancel.Dispose();
    }
}
