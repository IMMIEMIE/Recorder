using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using NAudio.Wave;
using Recorder.Windows;

internal static class Program
{
    private static int checks;
    private static void Check(bool pass, string description)
    { if (!pass) throw new Exception("FAIL: " + description); checks++; Console.WriteLine("PASS: " + description); }
    private static async Task<int> Main(string[] args)
    {
        try
        {
            Check(IntPtr.Size == 4, "test process is actually x86 / 32-bit");
            var secret = SettingsStore.Protect("test-key-not-a-real-credential");
            Check(!secret.Contains("test-key") && SettingsStore.Reveal(secret) == "test-key-not-a-real-credential", "DPAPI current-user secret round trip");
            TestResampling(); TestSegmenter(); TestLiveMerge(); TestExport();
            await TestHttpAsync(); await TestStreamingAsync(false); await TestStreamingAsync(true); await TestSessionAsync();
            if (args.Length > 1 && args[0] == "--model") await TestRealModelAsync(args[1]);
            Console.WriteLine($"ALL {checks} CHECKS PASSED"); return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
    }
    private static byte[] Tone(double seconds, double amplitude = .15, int rate = 16000)
    {
        var data = new byte[(int)(seconds * rate) * 2];
        for (int i = 0; i < data.Length / 2; i++) BitConverter.GetBytes((short)(Math.Sin(i * 2 * Math.PI * 440 / rate) * amplitude * 32767)).CopyTo(data, i * 2);
        return data;
    }
    private static void TestResampling()
    {
        var format = WaveFormat.CreateIeeeFloatWaveFormat(44100, 2);
        var data = new byte[44100 * 8];
        for (int i = 0; i < 44100; i++) { var sample = BitConverter.GetBytes((float)(Math.Sin(i * 2 * Math.PI * 440 / 44100) * .2)); sample.CopyTo(data, i * 8); sample.CopyTo(data, i * 8 + 4); }
        var whole = new PcmConverter(format).Convert(data, data.Length);
        var converter = new PcmConverter(format); using var chunks = new MemoryStream();
        for (int p = 0; p < data.Length; p += 4088) chunks.Write(converter.Convert(data.AsSpan(p, Math.Min(4088, data.Length - p)).ToArray(), Math.Min(4088, data.Length - p)));
        Check(whole.Length == 32000 && whole.SequenceEqual(chunks.ToArray()), "44.1 kHz stereo float -> 16 kHz PCM, identical across callback boundaries");
        var wav = ServiceHttp.Wav(whole);
        Check(Encoding.ASCII.GetString(wav, 0, 4) == "RIFF" && BitConverter.ToInt32(wav, 24) == 16000 && BitConverter.ToInt32(wav, 40) == whole.Length, "WAV header format and payload length");
    }
    private static void TestSegmenter()
    {
        var segments = new List<AudioSegment>(); var s = new Segmenter(300); s.Final += segments.Add;
        s.Append(new byte[32000]); s.Append(Tone(.4)); s.Append(new byte[16000]); s.Append(Tone(.4)); s.Finish();
        Check(segments.Count == 2 && segments[0].Seconds >= .7 && segments[1].Seconds > segments[0].Seconds, "silence boundaries, stop-tail flush, repeated speech preserved");
        var silent = new Segmenter(300); silent.Final += _ => throw new Exception("silence emitted speech"); silent.Append(new byte[32000]); silent.Finish();
        Check(true, "pure silence does not invoke recognition");
    }
    private static void TestLiveMerge()
    {
        var t = new LiveTranscript();
        t.Apply(JsonNode.Parse("""{"type":"response.text.done","item_id":"out","text":"你好"}""")!);
        t.Apply(JsonNode.Parse("""{"type":"conversation.item.created","item":{"id":"out","role":"assistant"},"previous_item_id":"in"}""")!);
        var row = t.Apply(JsonNode.Parse("""{"type":"conversation.item.input_audio_transcription.completed","event_id":"e1","item_id":"in","transcript":"Hello"}""")!).Single();
        Check(row.Final && row.Text == "Hello" && row.Translation == "你好", "LiveTranslate joins out-of-order source/translation by IDs");
        Check(!t.Apply(JsonNode.Parse("""{"type":"conversation.item.input_audio_transcription.completed","event_id":"e1","item_id":"in","transcript":"wrong"}""")!).Any(), "duplicate events ignored");
    }
    private static void TestExport()
    {
        TranscriptRow[] rows = [new("a", 1.25, "你好", "Hello"), new("b", 3, "世界")];
        Check(TranscriptExport.Text(rows).Contains("Hello") && TranscriptExport.Srt(rows).Contains("00:00:01,250 --> 00:00:03,000"), "bilingual TXT and SRT timestamps");
    }
    private static HttpListener Listen(out string url)
    {
        var tcp = new TcpListener(IPAddress.Loopback, 0); tcp.Start(); int port = ((IPEndPoint)tcp.LocalEndpoint).Port; tcp.Stop();
        url = $"http://127.0.0.1:{port}/";
        var server = new HttpListener(); server.Prefixes.Add(url); server.Start(); return server;
    }
    private static async Task Reply(HttpListenerContext context, string body, int status = 200)
    {
        var bytes = Encoding.UTF8.GetBytes(body); context.Response.StatusCode = status; context.Response.ContentType = "application/json";
        context.Response.ContentLength64 = bytes.Length; await context.Response.OutputStream.WriteAsync(bytes); context.Response.Close();
    }
    private static async Task TestHttpAsync()
    {
        using var server = Listen(out var url);
        var config = new AppSettings { ApiBase = url.TrimEnd('/'), ApiModel = "test-asr", Language = "en", TranslationBase = url.TrimEnd('/'), TranslationModel = "test-chat" };
        var serve = Task.Run(async () =>
        {
            var c = await server.GetContextAsync();
            using var reader = new StreamReader(c.Request.InputStream, Encoding.Latin1); var body = await reader.ReadToEndAsync();
            Check(c.Request.Url!.AbsolutePath == "/audio/transcriptions" && body.Contains("test-asr") && body.Contains("RIFF") && body.Contains("audio.wav"), "ASR multipart request contains model and WAV");
            await Reply(c, """{"text":"hello hello"}""");
            c = await server.GetContextAsync();
            using var r2 = new StreamReader(c.Request.InputStream); var json = JsonNode.Parse(await r2.ReadToEndAsync())!;
            Check(c.Request.Url!.AbsolutePath == "/chat/completions" && (string?)json["messages"]?[1]?["content"] == "hello hello", "translation sends finalized text");
            await Reply(c, """{"choices":[{"message":{"content":"你好你好"}}]}""");
            c = await server.GetContextAsync(); c.Response.RedirectLocation = url + "should-not-follow"; await Reply(c, "{}", 302);
        });
        using var recognizer = new ApiRecognizer(config);
        var text = await recognizer.TranscribeAsync(Tone(.5), CancellationToken.None);
        Check(text == "hello hello", "REST ASR keeps repeated words");
        Check(await ApiTranslation.TranslateAsync(config, text, CancellationToken.None) == "你好你好", "API translation response");
        try { await recognizer.TranscribeAsync(Tone(.5), CancellationToken.None); throw new Exception("redirect accepted"); }
        catch (InvalidOperationException ex) { Check(ex.Message.Contains("302"), "HTTP redirects rejected"); }
        await serve;
        try { ServiceHttp.Endpoint("http://example.com", "/audio/transcriptions"); throw new Exception("plaintext accepted"); }
        catch (InvalidOperationException) { Check(true, "remote plaintext endpoints rejected"); }
    }
    private static async Task<string> Receive(WebSocket ws)
    {
        var buffer = new byte[16384]; using var ms = new MemoryStream(); WebSocketReceiveResult result;
        do { result = await ws.ReceiveAsync(buffer, CancellationToken.None); ms.Write(buffer, 0, result.Count); } while (!result.EndOfMessage);
        return result.MessageType == WebSocketMessageType.Binary ? "binary:" + ms.Length : Encoding.UTF8.GetString(ms.ToArray());
    }
    private static Task Send(WebSocket ws, object value) => ws.SendAsync(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(value), WebSocketMessageType.Text, true, CancellationToken.None);
    private static async Task TestStreamingAsync(bool live)
    {
        using var server = Listen(out var url);
        var config = new AppSettings { Mode = live ? "live" : "stream", StreamingSecret = SettingsStore.Protect("mock-key"), LiveSecret = SettingsStore.Protect("mock-key") };
        var serve = Task.Run(async () =>
        {
            var c = await server.GetContextAsync();
            Check(c.Request.Headers["Authorization"] == "Bearer mock-key", (live ? "LiveTranslate" : "streaming ASR") + " auth header");
            var upgraded = await c.AcceptWebSocketAsync(null); using var ws = upgraded.WebSocket;
            string? taskId = null;
            if (live)
            {
                await Send(ws, new { type = "session.created" });
                var update = JsonNode.Parse(await Receive(ws))!;
                Check((string?)update["session"]?["translation"]?["language"] == "zh", "LiveTranslate session setup");
                await Send(ws, new { type = "session.updated", session = new { output_modalities = new[] { "text" }, translation = new { language = "zh" } } });
            }
            else
            {
                var start = JsonNode.Parse(await Receive(ws))!; taskId = (string?)start["header"]?["task_id"];
                Check((string?)start["payload"]?["model"] == "qwen-audio-3.0-asr-flash-streaming", "streaming ASR fixed model and run-task");
                await Send(ws, new { header = new { @event = "task-started", task_id = taskId } });
            }
            var audio = await Receive(ws);
            Check(live ? JsonNode.Parse(audio)?["type"]?.ToString() == "input_audio_buffer.append" : audio == "binary:3200", "16 kHz PCM audio transport");
            var stop = await Receive(ws);
            Check(live ? JsonNode.Parse(stop)?["type"]?.ToString() == "session.finish" : JsonNode.Parse(stop)?["header"]?["action"]?.ToString() == "finish-task", "graceful finish request");
            if (live)
            {
                await Send(ws, new { type = "conversation.item.input_audio_transcription.completed", item_id = "in", transcript = "tail phrase" });
                await Send(ws, new { type = "conversation.item.created", previous_item_id = "in", item = new { id = "out", role = "assistant" } });
                await Send(ws, new { type = "response.text.done", item_id = "out", text = "尾句" });
                await Send(ws, new { type = "session.finished" });
            }
            else
            {
                await Send(ws, new { header = new { @event = "result-generated", task_id = taskId }, payload = new { output = new { sentence = new { sentence_id = 1, sentence_end = true, begin_time = 500, text = "tail phrase" } } } });
                await Send(ws, new { header = new { @event = "task-finished", task_id = taskId } });
            }
            // Keep transport open until the client has consumed the finish event.
            try { await Receive(ws); } catch (WebSocketException) { }
        });
        await using var client = new StreamingClient(config); var rows = new List<TranscriptRow>(); client.Row += rows.Add;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await client.ConnectAsync(timeout.Token, url.Replace("http:", "ws:"));
        await client.AppendAsync(new byte[3200], timeout.Token); await client.FinishAsync(timeout.Token);
        Check(rows.Any(r => r.Final && r.Text == "tail phrase" && (!live || r.Translation == "尾句")), "tail results delivered before completion");
        await client.DisposeAsync(); await serve.WaitAsync(timeout.Token);
    }
    private static async Task TestRealModelAsync(string path)
    {
        if (!File.Exists(path)) await ModelDownload.DownloadAsync(path, new Progress<int>(p => { if (p % 20 == 0) Console.WriteLine("Model download: " + p + "%"); }), CancellationToken.None);
        var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));
        using var recognizer = new LocalRecognizer(path, "auto");
        foreach (var name in new[] { "english", "chinese" })
        {
            using var pcm = new MemoryStream();
            await AudioInput.ReadFileAsync(Path.Combine(root, "tests", "fixtures", name + ".aiff"), b => pcm.Write(b), false, CancellationToken.None);
            var text = await recognizer.TranscribeAsync(pcm.ToArray(), CancellationToken.None);
            Console.WriteLine(name + ": " + text);
            Check(!string.IsNullOrWhiteSpace(text), "real offline inference: " + name + " AIFF fixture");
        }
        await using var session = new RecordingSession(new AppSettings { Mode = "local", ModelPath = path, Language = "en" });
        var rows = new List<TranscriptRow>(); session.Row += rows.Add;
        await session.StartAsync(2, 0, Path.Combine(root, "tests", "fixtures", "english.aiff"));
        await session.Completion.WaitAsync(TimeSpan.FromSeconds(60));
        Check(rows.Count > 0 && rows.Any(r => r.Text.Contains("speech", StringComparison.OrdinalIgnoreCase)), "real local file session emits transcript before completion");
    }
    private static async Task TestSessionAsync()
    {
        var root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", ".."));
        var file = Path.Combine(root, "tests", "fixtures", "english.aiff");
        using var server = Listen(out var url);
        var config = new AppSettings { Mode = "api", ApiBase = url.TrimEnd('/'), SilenceMs = 1000 };
        var serve = Task.Run(async () =>
        {
            var context = await server.GetContextAsync();
            using var sink = new MemoryStream(); await context.Request.InputStream.CopyToAsync(sink);
            await Reply(context, """{"text":"tail preserved"}""");
        });
        await using (var session = new RecordingSession(config))
        {
            var rows = new List<TranscriptRow>(); session.Row += rows.Add;
            await session.StartAsync(2, 0, file);
            await session.Completion.WaitAsync(TimeSpan.FromSeconds(20)); await session.StopAsync();
            Check(rows.Count == 1 && rows[0].Text == "tail preserved" && session.AudioSeconds > 5, "file EOF drains audio, segmentation and recognition before completion");
        }
        await serve;
        await using (var session = new RecordingSession(config))
        {
            int emitted = 0; session.Row += _ => emitted++;
            await session.StartAsync(2, 0, file); await Task.Delay(150); session.Cancel();
            try { await session.Completion.WaitAsync(TimeSpan.FromSeconds(3)); } catch (OperationCanceledException) { }
            Check(emitted == 0, "early cancellation stops file session without posting stale text");
        }
    }
}
