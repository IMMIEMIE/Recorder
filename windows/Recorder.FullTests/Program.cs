using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Recorder.Windows;

int checks = 0;
void Check(bool value, string message) { if (!value) throw new Exception("FAIL: " + message); checks++; Console.WriteLine("PASS: " + message); }
HttpListener Listen(out string url)
{ var tcp = new TcpListener(IPAddress.Loopback, 0); tcp.Start(); int port = ((IPEndPoint)tcp.LocalEndpoint).Port; tcp.Stop(); url = $"http://127.0.0.1:{port}/"; var listener = new HttpListener(); listener.Prefixes.Add(url); listener.Start(); return listener; }
async Task<string> Receive(WebSocket ws)
{ var buffer = new byte[16384]; using var data = new MemoryStream(); WebSocketReceiveResult part; do { part = await ws.ReceiveAsync(buffer, CancellationToken.None); if (part.MessageType == WebSocketMessageType.Close) return "close"; data.Write(buffer, 0, part.Count); } while (!part.EndOfMessage); return part.MessageType == WebSocketMessageType.Binary ? "binary:" + data.Length : Encoding.UTF8.GetString(data.ToArray()); }
Task Send(WebSocket ws, object value) => ws.SendAsync(JsonSerializer.SerializeToUtf8Bytes(value), WebSocketMessageType.Text, true, CancellationToken.None);
try
{
    if (args.Length > 0 && args[0] == "--tone") { await AudioChecks.Tone(); return 0; }
    if (args.Length > 1 && args[0] == "--audio-check") return await AudioChecks.Loopback(args[1]);
    Environment.SetEnvironmentVariable("SHENGJIAN_DATA_ROOT", Path.Combine(Directory.GetCurrentDirectory(), ".bootstrap/full-tests-" + Guid.NewGuid().ToString("N")));
    foreach (bool failure in new[] { false, true })
    {
        using var listener = Listen(out string url);
        var server = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync(); Check(context.Request.Headers["Authorization"] == "Bearer synthetic", "stream key stays in WebSocket authorization header");
            using var ws = (await context.AcceptWebSocketAsync(null)).WebSocket;
            var start = JsonNode.Parse(await Receive(ws))!; string task = (string)start["header"]!["task_id"]!;
            Check((string?)start["payload"]?["parameters"]?["language_hints"]?[0] == "zh", "recognition language maps to streaming language hint");
            await Send(ws, new { header = new { @event = failure ? "task-failed" : "task-started", task_id = task } });
            if (!failure)
            {
                Check(await Receive(ws) == "binary:3200" && await Receive(ws) == "binary:320", "stream coalesces 100 ms PCM and drains short tail before finish");
                Check((string?)JsonNode.Parse(await Receive(ws))?["header"]?["action"] == "finish-task", "stream sends graceful finish after audio tail");
                var zero = new { header = new { @event = "result-generated", task_id = task }, payload = new { output = new { sentence = new { sentence_id = 0, sentence_end = true, begin_time = 0, text = "first" } } } };
                await Send(ws, zero); await Send(ws, zero);
                await Send(ws, new { header = new { @event = "result-generated", task_id = "unrelated" }, payload = new { output = new { sentence = new { sentence_id = 8, sentence_end = true, text = "wrong" } } } });
                await Send(ws, new { header = new { @event = "result-generated", task_id = task }, payload = new { output = new { sentence = new { sentence_id = 1, sentence_end = true, begin_time = 100, text = "tail" } } } });
                await Send(ws, new { header = new { @event = "task-finished", task_id = task } });
            }
            try { await Receive(ws); } catch (WebSocketException) { }
        });
        await using var client = new StreamingClient(new() { Mode = "stream", Language = "Chinese", StreamingSecret = SettingsStore.Protect("synthetic") });
        var rows = new List<TranscriptRow>(); client.Row += rows.Add;
        using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(10)); bool failed = false;
        try { await client.ConnectAsync(ct.Token, url.Replace("http:", "ws:")); await client.AppendAsync(new byte[1600], ct.Token); await client.AppendAsync(new byte[1600], ct.Token); await client.AppendAsync(new byte[320], ct.Token); await client.FinishAsync(ct.Token); } catch { failed = true; }
        Check(failed == failure && (failure || rows.Count == 2 && rows[0].Id == "asr:1" && rows[1].Text == "tail"), failure ? "stream task failure propagates" : "zero-based sentence boundary, duplicate filtering and finish tail are preserved");
        await client.DisposeAsync(); await server.WaitAsync(ct.Token);
    }
    using (var listener = Listen(out string url))
    {
        using var stop = new CancellationTokenSource();
        var server = Task.Run(async () =>
        {
            try { while (!stop.IsCancellationRequested) { var c = await listener.GetContextAsync().WaitAsync(stop.Token); using var sink = new MemoryStream(); await c.Request.InputStream.CopyToAsync(sink); c.Response.ContentType = "application/json"; await c.Response.OutputStream.WriteAsync("{\"text\":\"tail preserved\"}"u8.ToArray()); c.Response.Close(); } } catch (OperationCanceledException) { }
        });
        var config = new AppSettings { Mode = "api", ApiBase = url.TrimEnd('/'), Translation = false, EndpointMode = "fixed" };
        await using var session = new RecordingSession(config); var rows = new List<TranscriptRow>(); session.Row += rows.Add;
        await session.StartAsync(2, 0, Path.Combine(Directory.GetCurrentDirectory(), "tests/fixtures/english.aiff")); await session.Completion.WaitAsync(TimeSpan.FromSeconds(25));
        Check(rows.Count > 0 && rows.All(r => r.Text.Contains("tail preserved")) && session.AudioSeconds > 5, "HTTP ASR uses new VAD/cache pipeline and EOF drains accepted tail");
        stop.Cancel(); await server;
    }
    using (var listener = Listen(out string url))
    {
        var server = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync(); using var ws = (await context.AcceptWebSocketAsync(null)).WebSocket;
            await Send(ws, new { type = "session.created" }); var update = JsonNode.Parse(await Receive(ws))!;
            Check((int?)update["session"]?["audio"]?["output"]?["format"]?["sample_rate"] == 24000 && update["session"]?["output_modalities"]?.AsArray().Count == 2, "LiveTranslate negotiates text and 24 kHz PCM audio");
            await Send(ws, new { type = "session.updated", session = new { output_modalities = new[] { "audio", "text" }, translation = new { language = "en" } } });
            Check(JsonNode.Parse(await Receive(ws))?["type"]?.ToString() == "session.finish", "LiveTranslate uses independent graceful finish protocol");
            await Send(ws, new { type = "response.audio.delta", item_id = "out", event_id = "audio-first", delta = Convert.ToBase64String(new byte[] { 1, 2, 3 }) });
            await Send(ws, new { type = "response.audio.delta", item_id = "out", event_id = "audio-second", delta = Convert.ToBase64String(new byte[] { 4 }) });
            await Send(ws, new { type = "response.audio.done", item_id = "out" });
            await Send(ws, new { type = "conversation.item.input_audio_transcription.completed", item_id = "in", transcript = "你好" });
            await Send(ws, new { type = "response.audio_transcript.done", item_id = "out", transcript = "Hello" });
            await Send(ws, new { type = "conversation.item.created", previous_item_id = "in", item = new { id = "out", role = "assistant" } });
            await Send(ws, new { type = "session.finished" }); try { await Receive(ws); } catch (WebSocketException) { }
        });
        await using var client = new StreamingClient(new() { Mode = "live", TargetLanguage = "en", LiveAudioOutput = true, LiveSecret = SettingsStore.Protect("synthetic") });
        var queue = new Recorder.Backend.LivePlaybackQueue(true); var pcm = new List<byte>(); var rows = new List<TranscriptRow>();
        client.LiveEvent += (message, transcript) => { foreach (var chunk in queue.Consume(message, transcript.Snapshot())) pcm.AddRange(chunk); }; client.Row += rows.Add;
        using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(10)); await client.ConnectAsync(ct.Token, url.Replace("http:", "ws:")); await client.FinishAsync(ct.Token);
        Check(pcm.SequenceEqual(new byte[] { 1, 2, 3, 4 }) && rows.Any(r => r.Final && r.Text == "你好" && r.Translation == "Hello"), "LiveTranslate audio before association pairs with final source and subtitle");
        await client.DisposeAsync(); await server.WaitAsync(ct.Token);
    }
    Console.WriteLine($"ALL {checks} FULL DESKTOP CHECKS PASSED"); return 0;
}
catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
