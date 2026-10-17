using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Recorder.Backend;
using Recorder.Windows;
internal static class SoakChecks
{
    public static async Task<int> Run(string root, int seconds)
    {
        string reportPath = Path.Combine(root, ".bootstrap/soak-report.json"), data = Path.Combine(root, ".bootstrap/soak-" + Guid.NewGuid().ToString("N"));
        string runtime = Path.Combine(AppContext.BaseDirectory, "runtime");
        var asr = new NativeEngine(runtime); var translator = new NativeEngine(runtime); using var manager = new ModelManager(data);
        await using var core = new BackendCore(new ConfigStore(data), asr, translator, manager);
        await using var channel = new BackendChannel(core);
        var failures = new ConcurrentQueue<string>(); var completions = new ConcurrentDictionary<string, TaskCompletionSource>();
        int finals = 0, translated = 0; long maxLatency = 0; var unique = new HashSet<int>();
        var reader = Task.Run(async () =>
        {
            await foreach (var e in core.Events.ReadAllAsync())
            {
                if ((string?)e["type"] == "error") failures.Enqueue((string?)e["message"] ?? "error");
                if ((string?)e["type"] == "final") { if (!unique.Add((int)e["segment_id"]!)) failures.Enqueue("duplicate final"); Interlocked.Increment(ref finals); maxLatency = Math.Max(maxLatency, BackendJson.Integer(e["elapsed_ms"])); }
                if ((string?)e["type"] == "translation" && (bool?)e["done"] == true) Interlocked.Increment(ref translated);
                string request = (string?)e["request_id"] ?? "";
                if (completions.TryGetValue(request, out var completion) && (string?)e["state"] == "ready") completion.TrySetResult();
            }
        });
        JsonObject Command(string name) => new() { ["protocol_version"] = 1, ["command"] = name, ["request_id"] = Guid.NewGuid().ToString("N"), ["session_id"] = "one-hour" };
        async Task Ready(JsonObject message) { string id = (string)message["request_id"]!; var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); completions[id] = done; await channel.ControlAsync(message); await done.Task.WaitAsync(TimeSpan.FromMinutes(2)); completions.TryRemove(id, out _); }
        var options = new RuntimeConfig { Device = "cuda", AsrProjectorPath = Path.Combine(root, ".bootstrap/verification-models/qwen-asr/mmproj-Qwen3-ASR-1.7B-bf16.gguf"), TranslatorPath = Path.Combine(root, ".bootstrap/verification-models/qwen-translate/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf") };
        var load = Command("load"); load["config"] = BackendJson.Object(new ModelConfig { LocalModelPath = Path.Combine(root, ".bootstrap/verification-models/qwen-asr/Qwen3-ASR-1.7B-bf16.gguf") }); load["runtime"] = BackendJson.Object(options); await Ready(load);
        load = Command("load"); load["role"] = "translator"; load["translation"] = BackendJson.Object(new TranslationConfig { Enabled = true, TargetLanguage = "English" }); load["runtime"] = BackendJson.Object(options); await Ready(load);
        using var speech = new MemoryStream(); await AudioInput.ReadFileAsync(Path.Combine(root, "tests/fixtures/chinese.aiff"), bytes => speech.Write(bytes), false, CancellationToken.None); speech.Write(new byte[64000]); byte[] pcm = speech.ToArray();
        await channel.ControlAsync(Command("start")); var clock = Stopwatch.StartNew(); long sequence = 0, samples = 0; int offset = 0;
        var memory = new List<object>(); long nextMemory = 0;
        while (clock.Elapsed.TotalSeconds < seconds)
        {
            if (reader.IsFaulted) await reader;
            int n = Math.Min(3200, pcm.Length - offset); if (!channel.Audio("one-hour", sequence++, samples, pcm.AsSpan(offset, n).ToArray())) failures.Enqueue("mailbox overflow"); samples += n / 2; offset = (offset + n) % pcm.Length;
            if (core.State != "recording") { failures.Enqueue("recording ended early: " + core.State); break; }
            if (clock.ElapsedMilliseconds >= nextMemory)
            {
                memory.Add(new { seconds = clock.Elapsed.TotalSeconds, app = Process.GetCurrentProcess().PrivateMemorySize64, asr = asr.PrivateBytes, translator = translator.PrivateBytes }); nextMemory += 60000;
                File.WriteAllText(reportPath, JsonSerializer.Serialize(new { complete = false, duration_seconds = clock.Elapsed.TotalSeconds, finals, translated, max_latency_ms = maxLatency, failures = failures.ToArray(), memory }, new JsonSerializerOptions { WriteIndented = true }));
            }
            double delay = samples / 16000.0 - clock.Elapsed.TotalSeconds; if (delay > 0) await Task.Delay(TimeSpan.FromSeconds(delay));
        }
        await Ready(Command("stop"));
        var drain = Stopwatch.StartNew(); while (translated < finals && drain.Elapsed.TotalSeconds < 60) await Task.Delay(100);
        await channel.DisposeAsync(); await reader;
        bool passed = failures.IsEmpty && clock.Elapsed.TotalSeconds >= seconds && finals > 0 && translated == finals;
        File.WriteAllText(reportPath, JsonSerializer.Serialize(new { complete = true, passed, duration_seconds = clock.Elapsed.TotalSeconds, finals, translated, max_latency_ms = maxLatency, failures = failures.ToArray(), memory }, new JsonSerializerOptions { WriteIndented = true }));
        return passed ? 0 : 1;
    }
}
