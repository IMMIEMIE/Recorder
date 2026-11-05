using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Recorder.Backend;
using Recorder.Windows;
internal static class LongInputChecks
{
    private sealed class ContinuousVoice : IVoiceDetector { public bool IsSpeech(ReadOnlySpan<byte> pcm) => true; public void Dispose() { } }
    public static async Task<int> Run(string root)
    {
        var data = Path.Combine(root, ".bootstrap/long-input-" + Guid.NewGuid().ToString("N")); using var manager = new ModelManager(data);
        var engine = new NativeEngine(Path.Combine(AppContext.BaseDirectory, "runtime"));
        await using var core = new BackendCore(new ConfigStore(data), engine, new NativeEngine(Path.Combine(AppContext.BaseDirectory, "runtime")), manager);
        core.SetVoiceDetectorFactory(() => new ContinuousVoice());
        JsonObject Command(string name) => new() { ["protocol_version"] = 1, ["command"] = name, ["session_id"] = "continuous" };
        var finals = new List<JsonObject>();
        async Task Ready()
        {
            using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            while (await core.Events.WaitToReadAsync(ct.Token)) while (core.Events.TryRead(out var e)) { if ((string?)e["type"] == "error") throw new Exception((string?)e["message"]); if ((string?)e["type"] == "final") finals.Add(e); if ((string?)e["type"] == "status" && (string?)e["state"] == "ready") return; }
        }
        var load = Command("load"); load["config"] = BackendJson.Object(new ModelConfig { ModelId = "local/custom", LocalModelPath = Path.Combine(root, ".bootstrap/verification-models/whisper-tiny/ggml-tiny.bin"), Language = "English" }); load["runtime"] = BackendJson.Object(new RuntimeConfig { AsrEngine = "whisper", Device = "cuda" }); core.Control(load); await Ready();
        using var clip = new MemoryStream(); await AudioInput.ReadFileAsync(Path.Combine(root, "tests/fixtures/english.aiff"), bytes => clip.Write(bytes), false, CancellationToken.None); byte[] bytes = clip.ToArray();
        core.Control(Command("start")); long sequence = 0, samples = 0;
        for (int repeat = 0; repeat < 8; repeat++) for (int at = 0; at < bytes.Length; at += 3200) { int n = Math.Min(3200, bytes.Length - at); core.Audio("continuous", sequence++, samples, bytes.AsSpan(at, n).ToArray()); samples += n / 2; }
        core.Control(Command("stop")); await Ready();
        if (finals.Count != 1 || (bool?)finals[0]["forced_cut"] == true || Regex.Matches((string)finals[0]["text"]!, "test", RegexOptions.IgnoreCase).Count < 2) throw new Exception("Input chunks changed final boundary or removed repeated words.");
        await File.WriteAllTextAsync(Path.Combine(root, ".bootstrap/long-input-verification.json"), JsonSerializer.Serialize(new { audio_seconds = samples / 16000.0, input_chunk_seconds = 18, final_count = finals.Count, passed = true, text = (string)finals[0]["text"]! }, new JsonSerializerOptions { WriteIndented = true })); return 0;
    }
}
