using Recorder.Backend;
using Recorder.Windows;
internal static class CpuChecks
{
    public static async Task<int> Run(string root)
    {
        string directory = Path.Combine(root, ".bootstrap/cpu-only-runtime/cpu"); Directory.CreateDirectory(directory);
        foreach (var file in Directory.GetFiles(Path.Combine(AppContext.BaseDirectory, "runtime/cpu"))) File.Copy(file, Path.Combine(directory, Path.GetFileName(file)), true);
        await using var engine = new NativeEngine(Path.GetDirectoryName(directory)!); int notices = 0; engine.Notice += _ => notices++;
        var model = new EngineModel("whisper", Path.Combine(root, ".bootstrap/verification-models/whisper-tiny/ggml-tiny.bin"));
        await engine.LoadAsync(model, "English", CancellationToken.None); await engine.WarmupAsync(CancellationToken.None);
        using var pcm = new MemoryStream(); await AudioInput.ReadFileAsync(Path.Combine(root, "tests/fixtures/english.aiff"), bytes => pcm.Write(bytes), false, CancellationToken.None);
        string text = await engine.TranscribeAsync(pcm.ToArray(), CancellationToken.None);
        if (engine.ActiveDevice != "cpu" || notices != 1 || text.Length == 0) throw new Exception("Automatic CPU fallback failed.");
        await engine.UnloadAsync(); bool rejected = false;
        try { await engine.LoadAsync(model with { Device = "cuda" }, "auto", CancellationToken.None); } catch (FileNotFoundException) { rejected = true; }
        if (!rejected) throw new Exception("Explicit CUDA silently fell back.");
        string? previous = Environment.GetEnvironmentVariable("CUDA_VISIBLE_DEVICES");
        try
        {
            Environment.SetEnvironmentVariable("CUDA_VISIBLE_DEVICES", "-1");
            await using var hiddenGpu = new NativeEngine(Path.Combine(AppContext.BaseDirectory, "runtime")); int fallback = 0; hiddenGpu.Notice += _ => fallback++;
            await hiddenGpu.LoadAsync(model, "English", CancellationToken.None); await hiddenGpu.WarmupAsync(CancellationToken.None);
            if (hiddenGpu.ActiveDevice != "cpu" || fallback != 1 || (await hiddenGpu.TranscribeAsync(pcm.ToArray(), CancellationToken.None)).Length == 0) throw new Exception("Hidden-GPU fallback failed with CUDA component present.");
        }
        finally { Environment.SetEnvironmentVariable("CUDA_VISIBLE_DEVICES", previous); }
        await File.WriteAllTextAsync(Path.Combine(root, ".bootstrap/cpu-fallback.txt"), "PASS: automatic mode reports CUDA failure and completes real CPU inference.\nPASS: explicit CUDA fails without silent fallback.\nPASS: CUDA component present, CUDA_VISIBLE_DEVICES=-1 hides all GPUs; automatic mode still completes CPU inference.\n" + text);
        return 0;
    }
}
