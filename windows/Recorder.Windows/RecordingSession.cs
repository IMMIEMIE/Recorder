using System.Threading.Channels;

namespace Recorder.Windows;

public sealed class RecordingSession(AppSettings config) : IAsyncDisposable
{
    private readonly CancellationTokenSource cancel = new();
    private readonly CancellationTokenSource inputCancel = new();
    private readonly Channel<byte[]> audio = Channel.CreateBounded<byte[]>(100);
    private readonly Channel<AudioSegment> segments = Channel.CreateBounded<AudioSegment>(6);
    private readonly Channel<TranscriptRow> translations = Channel.CreateBounded<TranscriptRow>(4);
    private AudioInput? input;
    private Task? fileTask, worker;
    private IRecognizer? recognizer;
    private StreamingClient? stream;
    private int stopping;
    private long audioBytes;
    public double AudioSeconds => Interlocked.Read(ref audioBytes) / 32000.0;
    public event Action<TranscriptRow>? Row;
    public event Action<string>? Partial;
    public event Action<string>? Notice;
    public event Action<float>? Level;
    public event Action? FileEnded;
    public Task Completion => worker ?? Task.CompletedTask;
    public async Task StartAsync(int source, int microphone, string? file)
    {
        if (config.Mode is "stream" or "live")
        {
            stream = new(config);
            stream.Partial += s => Partial?.Invoke(s);
            stream.Row += r => { Row?.Invoke(r); if (config.Mode != "live" && r.Final) QueueTranslation(r); };
            await stream.ConnectAsync(cancel.Token);
        }
        else recognizer = config.Mode == "local"
            ? await Task.Run(() => new LocalRecognizer(config.ModelPath, config.Language), cancel.Token)
            : new ApiRecognizer(config);
        cancel.Token.ThrowIfCancellationRequested();
        worker = RunAsync();
        if (source == 2)
        {
            fileTask = Task.Run(async () =>
            {
                try { await AudioInput.ReadFileAsync(file!, Append, true, inputCancel.Token); FileEnded?.Invoke(); }
                catch (OperationCanceledException) when (inputCancel.IsCancellationRequested) { }
                catch (Exception ex) { audio.Writer.TryComplete(ex); FileEnded?.Invoke(); }
                finally { audio.Writer.TryComplete(); }
            });
        }
        else
        {
            input = new(); input.Data += Append;
            input.Ended += ex => { if (ex != null) { audio.Writer.TryComplete(ex); FileEnded?.Invoke(); } };
            input.Start(source == 1, microphone);
        }
    }
    private void Append(byte[] pcm)
    {
        if (cancel.IsCancellationRequested) return;
        Interlocked.Add(ref audioBytes, pcm.Length);
        if (!audio.Writer.TryWrite(pcm))
        {
            audio.Writer.TryComplete(new InvalidOperationException("识别速度跟不上音频，缓冲已满。已有文字已保留，请改用更小模型或流式服务。"));
            inputCancel.Cancel(); FileEnded?.Invoke();
        }
        float peak = 0;
        for (int i = 0; i < pcm.Length - 1; i += 2) peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(pcm, i) / 32768f));
        Level?.Invoke(peak);
    }
    private void QueueTranslation(TranscriptRow r)
    {
        if (config.Translation && !translations.Writer.TryWrite(r)) Notice?.Invoke("翻译队列已满，此句保留原文。可先停止转写并等待翻译完成。");
    }
    private async Task RunAsync()
    {
        var translationTask = TranslateAsync();
        try
        {
            if (stream != null)
            {
                var sending = SendStreamAsync();
                try
                {
                    var first = await Task.WhenAny(sending, stream.Completion);
                    if (first == stream.Completion) await stream.Completion;
                    await sending;
                    await stream.FinishAsync(cancel.Token);
                }
                catch
                {
                    cancel.Cancel(); audio.Writer.TryComplete();
                    try { await sending; } catch { }
                    throw;
                }
            }
            else
            {
                var segmenter = new Segmenter(config.SilenceMs);
                segmenter.Final += segment =>
                {
                    if (!segments.Writer.TryWrite(segment)) throw new InvalidOperationException("本地识别积压超过 6 句，已停止。请改用较小模型或流式服务。");
                };
                var recognizeTask = RecognizeAsync();
                _ = recognizeTask.ContinueWith(t => audio.Writer.TryComplete(t.Exception!.GetBaseException()),
                    CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
                Exception? inputFailure = null;
                try
                {
                    await foreach (var pcm in audio.Reader.ReadAllAsync(cancel.Token))
                    {
                        if (recognizeTask.IsFaulted) await recognizeTask;
                        segmenter.Append(pcm);
                    }
                    segmenter.Finish();
                }
                catch (Exception ex) { inputFailure = ex; }
                finally { segments.Writer.TryComplete(); }
                await recognizeTask;
                if (inputFailure != null) throw inputFailure;
            }
        }
        finally
        {
            translations.Writer.TryComplete();
            try { await translationTask; } catch (OperationCanceledException) when (cancel.IsCancellationRequested) { }
        }
    }
    private async Task SendStreamAsync()
    {
        await foreach (var pcm in audio.Reader.ReadAllAsync(cancel.Token)) await stream!.AppendAsync(pcm, cancel.Token);
    }
    private async Task RecognizeAsync()
    {
        await foreach (var segment in segments.Reader.ReadAllAsync(cancel.Token))
        {
            Partial?.Invoke("正在识别此句…");
            var text = await recognizer!.TranscribeAsync(segment.Pcm, cancel.Token);
            Partial?.Invoke("");
            if (text.Length == 0) continue;
            var row = new TranscriptRow(Guid.NewGuid().ToString(), segment.Seconds, text);
            Row?.Invoke(row); QueueTranslation(row);
        }
    }
    private async Task TranslateAsync()
    {
        await foreach (var row in translations.Reader.ReadAllAsync(cancel.Token))
        {
            try { Row?.Invoke(row with { Translation = await ApiTranslation.TranslateAsync(config, row.Text, cancel.Token) }); }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { break; }
            catch (Exception) { Notice?.Invoke("逐句翻译失败，原文已保留。请检查翻译设置、网络和额度。"); }
        }
    }
    public async Task StopAsync()
    {
        if (Interlocked.Exchange(ref stopping, 1) == 0)
        {
            inputCancel.Cancel();
            if (input != null) await input.StopAsync();
            if (fileTask != null) await fileTask;
            audio.Writer.TryComplete();
        }
        if (worker != null) await worker;
    }
    public void Cancel() { cancel.Cancel(); inputCancel.Cancel(); audio.Writer.TryComplete(); }
    public async ValueTask DisposeAsync()
    {
        Cancel();
        if (input != null) { try { await input.StopAsync(); } catch { } input.Dispose(); }
        if (fileTask != null) { try { await fileTask; } catch { } }
        if (worker != null) { try { await worker; } catch { } }
        if (stream != null) await stream.DisposeAsync();
        recognizer?.Dispose(); cancel.Dispose(); inputCancel.Dispose();
    }
}
