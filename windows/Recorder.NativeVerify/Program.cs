using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Recorder.Native;
using Recorder.Windows;
using NAudio.Wave;

if (args.Length == 2 && args[0] == "--transport")
{
    await using var host = await NativeClient.StartAsync(args[1]);
    await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => host.CallAsync("hello")));
    bool rejected = false;
    try { await host.CallAsync("invalid-command"); } catch (InvalidOperationException) { rejected = true; }
    if (!rejected) throw new Exception("Unknown command accepted");
    await host.CallAsync("hello");
    rejected = false;
    try { await host.CallAsync("asr", pcm: new byte[3]); } catch (InvalidDataException) { rejected = true; }
    if (!rejected) throw new Exception("Odd PCM payload accepted");
    using var stop = new CancellationTokenSource(); stop.Cancel();
    try { await host.CallAsync("hello", ct: stop.Token); throw new Exception("Cancelled call accepted"); } catch (OperationCanceledException) { }
    await host.CallAsync("hello");
    Console.WriteLine("Native transport: handshake, serialization, errors, payload validation, cancellation and recovery passed.");
    return 0;
}

if (args.Length < 4) { Console.Error.WriteLine("Usage: <host.exe> <model-root> <repo-root> <cpu|cuda> [model-id]"); return 2; }
var catalog = JsonNode.Parse(File.ReadAllText(Path.Combine(args[2], "windows/models.lock.json")))!["models"]!.AsArray();
var reports = new JsonArray();
try
{
    foreach (var m in catalog.OfType<JsonObject>().Where(m => args.Length < 5 || (string?)m["id"] == args[4]))
    {
        var modelRoot = Path.Combine(args[1], (string)m["id"]!);
        var files = m["files"]!.AsArray();
        var load = new JsonObject { ["path"] = Path.Combine(modelRoot, (string)files[0]!["name"]!), ["engine"] = (string)m["engine"]!, ["device"] = args[3] };
        if (files.Count > 1) load["projector"] = Path.Combine(modelRoot, (string)files[1]!["name"]!);
        await using var host = await NativeClient.StartAsync(args[0]);
        var clock = Stopwatch.StartNew();
        await host.CallAsync("load", load); var loadMs = clock.ElapsedMilliseconds;
        var report = new JsonObject { ["model"] = (string)m["id"]!, ["device"] = args[3], ["load_ms"] = loadMs, ["loaded_private_bytes"] = host.PrivateBytes };
        report["loaded_gpu_memory"] = (await host.CallAsync("memory"))["devices"]?.DeepClone();
        if ((string?)m["role"] == "asr")
        {
            var samples = new JsonArray();
            foreach (var fixture in new[] { "chinese", "english", "mixed" })
            {
                var pcm = ReadAiff(Path.Combine(args[2], "tests/fixtures/" + fixture + ".aiff"));
                clock.Restart();
                var result = await host.CallAsync("asr", new JsonObject { ["language"] = "auto" }, pcm);
                var text = (string?)result["text"] ?? "";
                if (string.IsNullOrWhiteSpace(text) || text.Contains("<asr_text>")) throw new Exception("Invalid ASR output");
                samples.Add(new JsonObject { ["fixture"] = fixture, ["text"] = text, ["elapsed_ms"] = clock.ElapsedMilliseconds, ["audio_seconds"] = pcm.Length / 32000.0 });
                Console.WriteLine($"{m["id"]} {args[3]} {fixture}: {text}");
            }
            var cancelPcm = ReadAiff(Path.Combine(args[2], "tests/fixtures/english.aiff"));
            using var cancel = new CancellationTokenSource(150);
            bool cancelled = false;
            try { await host.CallAsync("asr", pcm: cancelPcm, ct: cancel.Token); } catch (OperationCanceledException) { cancelled = true; }
            if (!cancelled) throw new Exception("Cancellation did not interrupt inference");
            var resumed = await host.CallAsync("asr", pcm: cancelPcm);
            if (string.IsNullOrWhiteSpace((string?)resumed["text"])) throw new Exception("ASR did not recover after cancellation");
            report["samples"] = samples; report["cancel_recovery"] = true;
        }
        else
        {
            string? first = null;
            for (var cycle = 0; cycle < 2; ++cycle)
            {
                var messages = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "Translate the following into English, only output the translation:\n你好，今天下午三点开会，请记住数字12345。" });
                await host.CallAsync("begin", new JsonObject { ["messages"] = messages, ["max_tokens"] = 128 });
                var raw = new List<byte>();
                for (;;) { var token = await host.CallAsync("next"); raw.AddRange(token["token_bytes"]!.AsArray().Select(v => (byte)v!.GetValue<int>())); if ((bool)token["done"]!) break; }
                var text = Encoding.UTF8.GetString(raw.ToArray());
                if (string.IsNullOrWhiteSpace(text)) throw new Exception("Empty translation");
                first ??= text;
                Console.WriteLine($"{m["id"]} {args[3]}: {text}");
                await host.CallAsync("end");
            }
            report["translation"] = first;
            // Abandon a live generation, then start a new independent one.
            await host.CallAsync("begin", new JsonObject { ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "Translate into English: 你好" }), ["max_tokens"] = 32 });
            await host.CallAsync("next"); await host.CallAsync("end"); report["generation_release"] = true;
            using var cancellation = new CancellationTokenSource(100);
            bool cancelled = false;
            try { await host.CallAsync("begin", new JsonObject { ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = string.Concat(Enumerable.Repeat("Please translate this sentence into Chinese. ", 600)) }), ["max_tokens"] = 32 }, ct: cancellation.Token); }
            catch (OperationCanceledException) { cancelled = true; }
            if (!cancelled) throw new Exception("Translation prefill cancellation not observed");
            await host.CallAsync("end");
            await host.CallAsync("begin", new JsonObject { ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "Translate into English: 你好" }), ["max_tokens"] = 32 });
            await host.CallAsync("next"); await host.CallAsync("end"); report["cancel_recovery"] = true;
        }
        var unloaded = new JsonArray(); var gpuUnloaded = new JsonArray();
        for (int i = 0; i < 3; ++i) { await host.CallAsync("unload"); unloaded.Add(host.PrivateBytes); gpuUnloaded.Add((await host.CallAsync("memory"))["devices"]?.DeepClone()); if (i < 2) await host.CallAsync("load", load); }
        if (unloaded[^1]!.GetValue<long>() > unloaded[0]!.GetValue<long>() + 64L * 1024 * 1024) throw new Exception("Model reload retains more than 64 MiB additional private memory");
        if (args[3] == "cuda" && gpuUnloaded[0]!.AsArray().Count > 0 &&
            gpuUnloaded[^1]![0]!["free_bytes"]!.GetValue<long>() + 64L * 1024 * 1024 < gpuUnloaded[0]![0]!["free_bytes"]!.GetValue<long>())
            throw new Exception("Model reload retains more than 64 MiB additional GPU memory");
        report["unloaded_gpu_memory"] = gpuUnloaded;
        report["unloaded_private_bytes"] = unloaded; report["passed"] = true; reports.Add(report);
        File.WriteAllText(Path.Combine(args[2], ".bootstrap/native-verification-" + args[3] + (args.Length > 4 ? "-" + args[4] : "") + ".json"), reports.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }
    File.WriteAllText(Path.Combine(args[2], ".bootstrap/native-verification-" + args[3] + (args.Length > 4 ? "-" + args[4] : "") + ".json"), reports.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    return 0;
}
catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }

static byte[] ReadAiff(string path)
{
    using var reader = new PcmAiffReader(path);
    using var resampler = new MediaFoundationResampler(reader, new WaveFormat(16000, 16, 1)) { ResamplerQuality = 60 };
    using var output = new MemoryStream();
    var buffer = new byte[3200]; int n;
    while ((n = resampler.Read(buffer, 0, buffer.Length)) > 0) output.Write(buffer, 0, n);
    return output.ToArray();
}
