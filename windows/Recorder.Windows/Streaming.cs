using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Recorder.Windows;

// Port of StreamingASR.swift and the text-only LiveTranslate protocol.
public sealed class StreamingClient : IAsyncDisposable
{
    public const string AsrEndpoint = "wss://maas.qianwenaiapi.com/api-ws/v1/inference";
    private readonly ClientWebSocket socket = new();
    private readonly SemaphoreSlim sending = new(1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly string taskId = Guid.NewGuid().ToString("N");
    private readonly LiveTranscript liveRows = new();
    private readonly AppSettings config;
    private readonly bool live;
    private Task? receiver;
    private bool finishing;
    private int disposed;
#if FULL_BACKEND
    private readonly MemoryStream coalesced = new();
    private readonly HashSet<int> finalIds = new();
#endif
    public event Action<string>? Partial;
    public event Action<TranscriptRow>? Row;
#if FULL_BACKEND
    public event Action<JsonNode, LiveTranscript>? LiveEvent;
#endif
    public Task Completion => finished.Task;
    public StreamingClient(AppSettings config) { this.config = config; live = config.Mode == "live"; }
    public async Task ConnectAsync(CancellationToken ct, string? testEndpoint = null)
    {
        var endpoint = testEndpoint ?? (live ? config.LiveEndpoint : AsrEndpoint);
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) ||
            !(uri.Scheme == "wss" || uri.Scheme == "ws" && uri.IsLoopback && testEndpoint != null) ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Fragment) || !string.IsNullOrEmpty(uri.Query))
            throw new InvalidOperationException("请填写有效的 WSS 实时服务地址，不要附带参数。");
        if (live) uri = new Uri(uri + "?model=qwen3.8-livetranslate-flash-realtime");
        var key = SettingsStore.Reveal(live ? config.LiveSecret : config.StreamingSecret);
        if (string.IsNullOrWhiteSpace(key)) throw new InvalidOperationException("请先在设置中填写此服务专用的 API Key。");
        socket.Options.SetRequestHeader("Authorization", "Bearer " + key);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        using var handler = new HttpMessageInvoker(new SocketsHttpHandler { AllowAutoRedirect = false });
        await socket.ConnectAsync(uri, handler, timeout.Token);
        receiver = ReceiveAsync();
        if (!live)
        {
            var parameters = new JsonObject { ["format"] = "pcm", ["sample_rate"] = 16000,
                ["max_sentence_silence"] = config.SilenceMs, ["heartbeat"] = true };
            if (config.Language != "auto") parameters["language_hints"] = new JsonArray(config.Language switch { "Chinese" => "zh", "Cantonese" => "zh", "English" => "en", "Japanese" => "ja", "Korean" => "ko", _ => config.Language });
            await JsonAsync(new { header = new { action = "run-task", task_id = taskId, streaming = "duplex" },
                payload = new { task_group = "audio", task = "asr", function = "recognition", model = "qwen-audio-3.0-asr-flash-streaming", parameters, input = new { } } }, timeout.Token);
        }
        await ready.Task.WaitAsync(timeout.Token);
    }
#if FULL_BACKEND
    public async Task AppendAsync(byte[] pcm, CancellationToken ct)
    {
        if (finishing || (pcm.Length & 1) != 0) throw new InvalidOperationException("音频必须为完整 PCM16 样本，且会话仍在录制。");
        coalesced.Write(pcm); if (coalesced.Length < 3200) return;
        var bytes = coalesced.ToArray(); coalesced.SetLength(0);
        for (int at = 0; at < bytes.Length; at += 3200)
        {
            int n = Math.Min(3200, bytes.Length - at);
            if (n < 3200) { coalesced.Write(bytes, at, n); break; }
            await AudioAsync(bytes.AsSpan(at, n).ToArray(), ct);
        }
    }
    private Task AudioAsync(byte[] pcm, CancellationToken ct) => live
#else
    public Task AppendAsync(byte[] pcm, CancellationToken ct) => live
#endif
        ? JsonAsync(new { type = "input_audio_buffer.append", event_id = Guid.NewGuid().ToString(), audio = Convert.ToBase64String(pcm) }, ct)
        : SendAsync(pcm, WebSocketMessageType.Binary, ct);
    public async Task FinishAsync(CancellationToken ct)
    {
        finishing = true;
#if FULL_BACKEND
        if (coalesced.Length > 0) { await AudioAsync(coalesced.ToArray(), ct); coalesced.SetLength(0); }
#endif
        if (live) await JsonAsync(new { type = "session.finish", event_id = Guid.NewGuid().ToString() }, ct);
        else await JsonAsync(new { header = new { action = "finish-task", task_id = taskId, streaming = "duplex" }, payload = new { input = new { } } }, ct);
        try { await finished.Task.WaitAsync(TimeSpan.FromSeconds(30), ct); }
        catch (TimeoutException) { throw new InvalidOperationException("服务尾句处理超时，已有文字已保留，末句可能不完整。"); }
    }
    private Task JsonAsync(object value, CancellationToken ct) => SendAsync(JsonSerializer.SerializeToUtf8Bytes(value), WebSocketMessageType.Text, ct);
    private async Task SendAsync(byte[] data, WebSocketMessageType type, CancellationToken ct)
    {
        await sending.WaitAsync(ct);
        try { await socket.SendAsync(data, type, true, ct); }
        finally { sending.Release(); }
    }
    private async Task ReceiveAsync()
    {
        try
        {
            var buffer = new byte[16384];
            while (!lifetime.IsCancellationRequested)
            {
                using var message = new MemoryStream(); WebSocketReceiveResult part;
                do
                {
                    part = await socket.ReceiveAsync(buffer, lifetime.Token);
                    if (part.MessageType == WebSocketMessageType.Close) throw new IOException("实时服务连接已关闭，已有文字已保留。");
                    if (message.Length + part.Count > 2_000_000) throw new InvalidDataException("实时服务消息过大。");
                    message.Write(buffer, 0, part.Count);
                } while (!part.EndOfMessage);
                var json = JsonNode.Parse(message.ToArray()) ?? throw new InvalidDataException("实时服务返回无效数据。");
                if (live)
                {
                    var type = (string?)json["type"];
                    switch (type)
                    {
                        case "session.created":
#if FULL_BACKEND
                            var audioOptions = new JsonObject { ["input"] = new JsonObject { ["format"] = new JsonObject { ["type"] = "pcm", ["sample_rate"] = 16000 }, ["turn_detection"] = new JsonObject { ["type"] = "server_vad", ["threshold"] = .5, ["silence_duration_ms"] = config.SilenceMs } } };
                            if (config.LiveAudioOutput) audioOptions["output"] = new JsonObject { ["format"] = new JsonObject { ["type"] = "pcm", ["sample_rate"] = 24000 } };
                            await JsonAsync(new JsonObject { ["type"] = "session.update", ["event_id"] = Guid.NewGuid().ToString(), ["session"] = new JsonObject { ["output_modalities"] = config.LiveAudioOutput ? new JsonArray("text", "audio") : new JsonArray("text"), ["translation"] = new JsonObject { ["language"] = config.TargetLanguage }, ["audio"] = audioOptions } }, lifetime.Token);
#else
                            await JsonAsync(new { type = "session.update", event_id = Guid.NewGuid().ToString(), session = new {
                                output_modalities = new[] { "text" }, translation = new { language = config.TargetLanguage },
                                audio = new { input = new { format = new { type = "pcm", sample_rate = 16000 },
                                    turn_detection = new { type = "server_vad", threshold = .5, silence_duration_ms = config.SilenceMs } } } } }, lifetime.Token);
#endif
                            break;
                        case "session.updated":
                            if ((string?)json["session"]?["translation"]?["language"] != config.TargetLanguage ||
                                json["session"]?["output_modalities"] is not JsonArray modes ||
#if FULL_BACKEND
                                modes.Count != (config.LiveAudioOutput ? 2 : 1) || !modes.Any(m => (string?)m == "text") || config.LiveAudioOutput && !modes.Any(m => (string?)m == "audio"))
#else
                                modes.Count != 1 || (string?)modes[0] != "text")
#endif
                                throw new InvalidDataException("LiveTranslate 未确认目标语言和文字输出方式。");
                            ready.TrySetResult(); break;
                        case "session.finished": Complete(); return;
                        case "error": case "conversation.item.input_audio_transcription.failed":
                            throw new InvalidOperationException("LiveTranslate 服务处理失败，请检查密钥、模型权限、额度及区域。");
                        case "response.done":
                            if ((string?)json["response"]?["status"] != "completed") throw new InvalidOperationException("实时译文未完成，已有文字已保留。");
                            break;
                    }
                    foreach (var row in liveRows.Apply(json)) Row?.Invoke(row);
#if FULL_BACKEND
                    LiveEvent?.Invoke(json, liveRows);
#endif
                }
                else
                {
                    if ((string?)json["header"]?["task_id"] != taskId) continue;
                    switch ((string?)json["header"]?["event"])
                    {
                        case "task-started": ready.TrySetResult(); break;
                        case "task-finished": Complete(); return;
                        case "task-failed": throw new InvalidOperationException("流式识别任务失败，请检查千问AI平台密钥、模型权限及额度。");
                        case "result-generated":
                            var sentence = json["payload"]?["output"]?["sentence"];
                            if (sentence == null || (bool?)sentence["heartbeat"] == true) break;
                            var text = (string?)sentence["text"] ?? "";
                            if ((bool?)sentence["sentence_end"] == true)
                            {
                                var id = (int?)sentence["sentence_id"] ?? 0;
#if FULL_BACKEND
                                if (sentence["sentence_id"] != null && id >= 0 && id < int.MaxValue && finalIds.Add(id)) Row?.Invoke(new("asr:" + (id + 1), Math.Max(0, (double?)sentence["begin_time"] ?? 0) / 1000, text));
#else
                                if (id > 0) Row?.Invoke(new("asr:" + id, Math.Max(0, (double?)sentence["begin_time"] ?? 0) / 1000, text));
#endif
                            }
                            else Partial?.Invoke(text);
                            break;
                    }
                }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { ready.TrySetCanceled(); finished.TrySetCanceled(); }
        catch (Exception ex) { ready.TrySetException(ex); finished.TrySetException(ex); }
    }
    private void Complete()
    {
        if (!finishing) throw new IOException("实时服务意外结束，已有文字已保留。");
        finished.TrySetResult();
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel(); socket.Abort();
        if (receiver != null) await receiver;
        // Observe failures even when the connection failed before readiness.
        _ = ready.Task.Exception; _ = finished.Task.Exception;
        socket.Dispose(); sending.Dispose(); lifetime.Dispose();
#if FULL_BACKEND
        coalesced.Dispose();
#endif
    }
}

public sealed partial class LiveTranscript
{
    private sealed class Part { public string Text = ""; public bool Done; }
    private sealed class RowData { public Part Source = new(); public double Seconds; public List<string> Outputs = new(); }
    private readonly Dictionary<string, RowData> rows = new();
    private readonly Dictionary<string, Part> outputs = new();
    private readonly HashSet<string> events = new();
    public IEnumerable<TranscriptRow> Apply(JsonNode e)
    {
        var eventId = (string?)e["event_id"];
        if (eventId != null && !events.Add(eventId)) return [];
        var type = (string?)e["type"];
        string? id = (string?)e["item_id"];
        RowData Ensure(string key) { if (!rows.TryGetValue(key, out var row)) rows[key] = row = new(); return row; }
        if (type == "conversation.item.created" && (string?)e["item"]?["role"] == "assistant" &&
            (string?)e["item"]?["id"] is string output && (string?)e["previous_item_id"] is string source)
        {
            var row = Ensure(source); if (!row.Outputs.Contains(output)) row.Outputs.Add(output);
        }
        if (id != null) switch (type)
        {
            case "input_audio_buffer.speech_started": Ensure(id).Seconds = ((double?)e["audio_start_ms"] ?? 0) / 1000; break;
            case "conversation.item.input_audio_transcription.delta":
                var delta = Ensure(id).Source; if (!delta.Done) delta.Text += (string?)e["delta"] ?? ""; break;
            case "conversation.item.input_audio_transcription.completed":
                Ensure(id).Source = new() { Text = (string?)e["transcript"] ?? "", Done = true }; break;
            case "response.text.delta": case "response.audio_transcript.delta":
                if (!outputs.TryGetValue(id, out var part)) outputs[id] = part = new();
                if (!part.Done) part.Text += (string?)e["delta"] ?? ""; break;
            case "response.text.done": case "response.audio_transcript.done":
                outputs[id] = new() { Text = (string?)e["text"] ?? (string?)e["transcript"] ?? "", Done = true }; break;
        }
        return rows.Where(r => r.Value.Source.Text.Length > 0 || r.Value.Outputs.Any(o => outputs.ContainsKey(o)))
            .Select(r => new TranscriptRow(r.Key, r.Value.Seconds, r.Value.Source.Text,
                string.Join(" ", r.Value.Outputs.Where(outputs.ContainsKey).Select(o => outputs[o].Text)),
                r.Value.Source.Done && r.Value.Outputs.Count > 0 && r.Value.Outputs.All(o => outputs.TryGetValue(o, out var p) && p.Done))).ToArray();
    }
}
