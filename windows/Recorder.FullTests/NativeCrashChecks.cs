using System.Diagnostics;
using System.Text.Json.Nodes;
using Recorder.Backend;
using Recorder.Windows;
internal static class NativeCrashChecks
{
    public static async Task<int> Run(string root)
    {
        string data = Path.Combine(root, ".bootstrap/native-crash-" + Guid.NewGuid().ToString("N")); using var models = new ModelManager(data);
        var asr = new NativeEngine(Path.Combine(AppContext.BaseDirectory, "runtime")); var translator = new NativeEngine(Path.Combine(AppContext.BaseDirectory, "runtime"));
        await using var core = new BackendCore(new ConfigStore(data), asr, translator, models); var finalText = new List<string>();
        async Task Wait(Func<JsonObject, bool> test)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            while (await core.Events.WaitToReadAsync(timeout.Token)) while (core.Events.TryRead(out var e)) { if ((string?)e["type"] == "final") finalText.Add((string)e["text"]!); if (test(e)) return; }
            throw new Exception("Missing crash recovery event");
        }
        JsonObject Command(string command) => new() { ["protocol_version"] = 1, ["command"] = command, ["session_id"] = "recovery" };
        async Task Load()
        {
            while (!core.CanSelectAsr) await Task.Delay(20);
            var message = Command("load"); message["config"] = BackendJson.Object(new ModelConfig { ModelId = "ggerganov/whisper.cpp", LocalModelPath = Path.Combine(root, ".bootstrap/verification-models/whisper-tiny/ggml-tiny.bin") });
            message["runtime"] = BackendJson.Object(new RuntimeConfig { Device = "cpu", AsrEngine = "whisper" }); core.Control(message);
            await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        }
        using var pcm = new MemoryStream(); await AudioInput.ReadFileAsync(Path.Combine(root, "tests/fixtures/english.aiff"), bytes => pcm.Write(bytes), false, CancellationToken.None);
        async Task Recognize()
        {
            core.Control(Command("start")); core.Audio("recovery", 0, 0, pcm.ToArray()); core.Control(Command("stop"));
            await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        }
        await Load(); await Recognize(); if (finalText.Count != 1) throw new Exception("No initial final transcript");
        using (var worker = Process.GetProcessById(asr.ProcessId!.Value)) { worker.Kill(); await worker.WaitForExitAsync(); }
        await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "error");
        if (finalText.Count != 1 || asr.IsLoaded) throw new Exception("Worker crash lost completed transcript or stayed loaded");
        await Load(); await Recognize(); if (finalText.Count != 2) throw new Exception("Recognition did not recover after worker restart");
        var change = Command("load"); change["config"] = BackendJson.Object(new ModelConfig { ModelId = "ggerganov/whisper.cpp", LocalModelPath = Path.Combine(root, ".bootstrap/verification-models/whisper-turbo/ggml-large-v3-turbo.bin") }); change["runtime"] = BackendJson.Object(new RuntimeConfig { Device = "cpu", AsrEngine = "whisper" }); core.Control(change);
        await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "warming"); await Task.Delay(60); var cancelClock = Stopwatch.StartNew(); core.Control(Command("cancel_operation"));
        await Wait(e => (string?)e["type"] == "error");
        if (!asr.IsLoaded || !core.Config.LocalModelPath.EndsWith("ggml-tiny.bin") || cancelClock.Elapsed.TotalSeconds > 15) throw new Exception("Real model warmup cancellation did not restore previous model promptly");
        await Recognize(); if (finalText.Count != 3) throw new Exception("Model unusable after warmup cancellation");
        await File.WriteAllTextAsync(Path.Combine(root, ".bootstrap/native-crash.txt"), "PASS: unexpected native worker exit detected while idle; completed text retained; model reload and next transcription succeed.\nPASS: real Whisper Turbo CPU warmup cancellation restores Tiny and next recognition succeeds.\nCancellation and restore milliseconds: " + cancelClock.ElapsedMilliseconds + "\n" + string.Join("\n", finalText)); return 0;
    }
}
