using System.Text.Json.Nodes;
using Recorder.Backend;

int checks = 0;
var observed = new List<JsonObject>();
void Check(bool value, string detail) { if (!value) throw new Exception("FAIL: " + detail); checks++; Console.WriteLine("PASS: " + detail); }
void Reject(Action action, string detail) { try { action(); } catch { Check(true, detail); return; } throw new Exception("FAIL: " + detail); }
JsonObject Command(string name, string session = "test") => new() { ["protocol_version"] = 1, ["command"] = name, ["request_id"] = Guid.NewGuid().ToString("N"), ["session_id"] = session };
async Task<JsonObject> Event(BackendCore core, Func<JsonObject, bool> test)
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    while (await core.Events.WaitToReadAsync(timeout.Token)) while (core.Events.TryRead(out var item)) { observed.Add(item); if (test(item)) return item; }
    throw new Exception("Missing backend event");
}
var workspace = args.Length > 0 ? Path.GetFullPath(args[0]) : Directory.GetCurrentDirectory();
var root = Path.Combine(workspace, ".bootstrap", "backend-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
try
{
    Reject(() => BackendJson.Parse<ModelConfig>(new JsonObject { ["preview_interval_ms"] = true }), "boolean rejected for integer setting");
    Reject(() => BackendJson.Parse<ModelConfig>(new JsonObject { ["save_audio"] = true }), "unknown config keys rejected");
    Reject(() => BackendJson.Parse<ModelConfig>(new JsonObject { ["endpoint_silence_ms"] = 299 }), "out-of-range endpoint rejected");
    Reject(() => BackendJson.Parse<ModelConfig>(new JsonObject { ["schema_version"] = 2 }), "unsupported schema rejected");
    Reject(() => BackendJson.Parse<ModelConfig>(new JsonObject { ["local_model_path"] = null }), "null rejected for required string setting");
    Reject(() => ServiceAddress.Endpoint("http://example.com/v1", "/audio/transcriptions"), "remote plaintext refused");
    Reject(() => ServiceAddress.Endpoint("https://key@example.com/v1", "/audio/transcriptions"), "URL credentials refused");
    Check(ServiceAddress.Endpoint("http://127.0.0.1:1234/v1", "/audio/transcriptions").IsLoopback, "localhost HTTP permitted");
    var legacy = Path.Combine(root, "legacy"); Directory.CreateDirectory(legacy);
    var secret = SecretStore.Protect("synthetic-test-secret");
    var legacySettings = new JsonObject { ["Mode"] = "local", ["ModelPath"] = "tiny.bin", ["Language"] = "zh", ["Translation"] = true, ["TargetLanguage"] = "ja", ["ApiSecret"] = secret };
    var original = legacySettings.ToJsonString(); File.WriteAllText(Path.Combine(legacy, "settings.json"), original);
    var migrated = new ConfigStore(Path.Combine(root, "migrated")); migrated.MigrateLegacy(legacy);
    var migratedConfig = migrated.Load("config.json", new ModelConfig());
    Check(migratedConfig.Language == "Chinese" && migratedConfig.LocalModelPath == "tiny.bin", "legacy recognition selection migrated");
    Check(migrated.Load("translation.json", new TranslationConfig()).TargetLanguage == "日本語", "legacy target migrated");
    var migratedSecrets = JsonNode.Parse(File.ReadAllText(Path.Combine(migrated.Root, "legacy-secrets.json")))!;
    Check(SecretStore.Reveal((string)migratedSecrets["ApiSecret"]!) == "synthetic-test-secret", "legacy DPAPI secret remains decryptable");
    Check(File.ReadAllText(Path.Combine(legacy, "settings.json")) == original, "legacy settings never modified");
    migrated.MigrateLegacy(legacy); Check(migrated.Load("config.json", new ModelConfig()) == migratedConfig, "migration is idempotent");

    var shared = JsonNode.Parse(File.ReadAllText(Path.Combine(workspace, "tests/shared/backend-cases.json")))!;
    foreach (var item in shared["sentence_cases"]!.AsArray()) Check(SentenceText.Complete((string)item!["text"]!) == (bool)item["complete"]!, "shared sentence: " + item["text"]);
    foreach (var item in shared["segment_cases"]!.AsArray())
    {
        var jobs = new List<SegmentJob>(); var segmentation = new Recorder.Backend.Segmenter(BackendJson.Parse<ModelConfig>(item!["config"]!.AsObject()), jobs.Add);
        foreach (var action in item["actions"]!.AsArray())
        {
            if (action!["frames"] is JsonNode frames) for (int i = 0; i < (int)frames; ++i) segmentation.Feed(new byte[640], (bool)action["voiced"]!);
            if (action["feedback"] is JsonNode feedback) segmentation.AcceptPreview(jobs.Last(j => !j.Final), (string)feedback!);
            if ((bool?)action["flush"] == true) segmentation.Flush();
        }
        var finals = jobs.Where(j => j.Final).ToArray(); var expected = item["finals"]!.AsArray();
        Check(finals.Length == expected.Count && finals.Select((j, i) => j.StartSample == (long)expected[i]![0]! && j.EndSample == (long)expected[i]![1]! && !j.ForcedCut).All(v => v), "shared segment: " + item["name"]);
    }
    using (var vad = new WebRtcVad(Path.Combine(workspace, ".bootstrap/runtime-x64/cpu/recorder-vad.dll"))) Check(!vad.IsSpeech(new byte[640]), "real WebRTC VAD rejects silence");
    var cache = new RecognitionCache(); var cachedAsr = new FakeAsr { Output = "hello" }; var cacheConfig = new ModelConfig { MaxSegmentSeconds = 5 };
    var cachedJob = new SegmentJob("cache", 1, 1, 0, 12 * 16000, false, new byte[12 * 32000], 12 * 16000);
    var cacheResult = await cache.TranscribeAsync(cachedAsr, cacheConfig, cachedJob, () => false, default);
    Check(cachedAsr.Calls == 3 && cacheResult.Text == "hello hello hello", "bounded inputs preserve actual repeated words");
    await cache.TranscribeAsync(cachedAsr, cacheConfig, cachedJob with { Pcm = new byte[13 * 32000], Final = true }, () => false, default);
    Check(cachedAsr.Calls == 3, "silence-only final reuses preview result");
    await cache.TranscribeAsync(cachedAsr, cacheConfig, cachedJob with { Pcm = new byte[13 * 32000], LastVoicedSample = 13 * 16000 }, () => false, default);
    Check(cachedAsr.Calls == 4, "new speech reuses complete chunks and refreshes only tail");
    cache.Forget(cachedJob); Check(cache.Count == 0, "finalized cache entry released");
    await ModelManagerChecks.Run(root, workspace, Check, Reject);

    var store = new ConfigStore(Path.Combine(root, "core")); var asr = new FakeAsr(); var translator = new FakeTranslator(); var downloader = new FakeDownloader();
    await using (var core = new BackendCore(store, asr, translator, new FakeResolver(), downloader))
    {
        core.Control(Command("hello"));
        await Event(core, e => (string?)e["type"] == "config");
        Check(core.State == "idle", "initial backend idle");
        var hold = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); asr.Hold = hold.Task;
        var load = Command("load"); load["config"] = BackendJson.Object(new ModelConfig { ModelId = "test/good" }); core.Control(load);
        await asr.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Check(!File.Exists(Path.Combine(store.Root, "config.json")), "loading model does not commit config");
        core.Control(Command("hello")); await Event(core, e => (string?)e["type"] == "status" && (string?)e["state"] == "loading");
        Check(core.State == "loading", "control remains responsive during blocked model load");
        hold.SetResult(); await Event(core, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        Check(store.Load("config.json", new ModelConfig()).ModelId == "test/good", "model selection committed after warmup");
        var bad = Command("load"); bad["config"] = BackendJson.Object(new ModelConfig { ModelId = "test/bad" }); core.Control(bad);
        await Event(core, e => (string?)e["type"] == "error");
        Check(core.Config.ModelId == "test/good" && asr.Model == "test/good" && core.State == "ready", "failed switch reloads previous model and retains config");
        Check(store.Load("config.json", new ModelConfig()).ModelId == "test/good", "failed switch never overwrites persisted selection");
        using (var locked = new FileStream(Path.Combine(store.Root, "config.json"), FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var diskFailure = Command("load"); diskFailure["config"] = BackendJson.Object(new ModelConfig { ModelId = "test/other" });
            diskFailure["runtime"] = BackendJson.Object(new RuntimeConfig { Device = "cpu" }); core.Control(diskFailure);
            await Event(core, e => (string?)e["type"] == "error");
            Check(core.Config.ModelId == "test/good" && asr.Model == "test/good", "disk commit failure restores loaded model");
            Check(store.Load("runtime.json", new RuntimeConfig()).Device == "auto", "disk commit failure rolls back runtime settings");
        }
        var warm = Command("load"); warm["config"] = BackendJson.Object(new ModelConfig { ModelId = "test/warm-failure" }); core.Control(warm);
        await Event(core, e => (string?)e["type"] == "error");
        Check(core.Config.ModelId == "test/good" && asr.IsLoaded, "warmup failure restores previous model");
        var download = Command("download"); download["config"] = BackendJson.Object(new ModelConfig { ModelId = "test/download" }); core.Control(download);
        await downloader.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5)); core.Control(Command("cancel_download"));
        Check(core.State == "ready", "download cancellation restores usable state immediately");
        downloader.Result.SetResult(new(new("qwen", "stale"), "rev")); await Task.Delay(30);
        Check(core.Config.ModelId == "test/good", "cancelled download cannot load stale model");
        var stream = Command("load"); stream["config"] = BackendJson.Object(new ModelConfig { Provider = "api", ApiProtocol = "qwen_realtime" }); core.Control(stream);
        await Event(core, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready" && (string?)e["request_id"] == (string?)stream["request_id"]);
        core.Control(Command("start")); Check(core.State == "recording", "streaming session starts without local model");
        var sentence = Command("asr_stream_final"); sentence["segment_id"] = 1; sentence["start_sample"] = 0; sentence["text"] = "保留这句"; core.Control(sentence); core.Control(sentence.DeepClone().AsObject());
        await Event(core, e => (string?)e["type"] == "final" && (string?)e["text"] == "保留这句");
        core.Control(Command("stop")); await Event(core, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        Check(!core.Events.TryRead(out var extra) || (string?)extra["type"] != "final", "duplicate streaming sentence emitted once");
        var invalid = Command("unknown"); core.Control(invalid); await Event(core, e => (string?)e["type"] == "error");
        Check(core.State == "ready", "invalid command preserves ready state");
    }
    Check(!asr.IsLoaded && !translator.IsLoaded, "shutdown releases engine resources");

    var audioAsr = new FakeAsr();
    await using (var audioCore = new BackendCore(new ConfigStore(Path.Combine(root, "audio")), audioAsr, new FakeTranslator(), new FakeResolver()))
    {
        audioCore.SetVoiceDetectorFactory(() => new MarkedVad());
        var load = Command("load"); load["config"] = BackendJson.Object(new ModelConfig { ModelId = "test/audio", EndpointMode = "fixed" }); audioCore.Control(load);
        await Event(audioCore, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        await using var channel = new BackendChannel(audioCore);
        await channel.ControlAsync(Command("start", "audio-tail"));
        var voice = Enumerable.Range(0, 3 * 320).SelectMany(_ => new byte[] { 1, 0 }).ToArray();
        Check(channel.Audio("audio-tail", 0, 0, voice), "capture mailbox accepts valid audio");
        await channel.ControlAsync(Command("stop", "audio-tail"));
        var final = await Event(audioCore, e => (string?)e["type"] == "final");
        Check((long)final["end_sample"]! == 960 && audioAsr.Calls == 1, "stop barrier drains accepted tail before finalization");
        await Event(audioCore, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        audioCore.Control(Command("start", "gap")); audioCore.Audio("gap", 0, 0, voice); audioCore.Audio("gap", 2, 960, new byte[640]);
        await Event(audioCore, e => (string?)e["type"] == "error"); await Event(audioCore, e => (string?)e["type"] == "final");
        await Event(audioCore, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready"); Check(true, "sequence gap stops and finalizes valid received audio");
        audioAsr.InferenceEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var inferenceGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); audioAsr.InferenceHold = inferenceGate.Task;
        audioCore.Control(Command("start", "obsolete"));
        var continuous = Enumerable.Range(0, 60 * 320).SelectMany(_ => new byte[] { 1, 0 }).ToArray(); audioCore.Audio("obsolete", 0, 0, continuous);
        await audioAsr.InferenceEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        audioCore.Audio("obsolete", 1, 19200, new byte[50 * 640]); audioCore.Control(Command("stop", "obsolete")); inferenceGate.SetResult();
        await Event(audioCore, e => (string?)e["type"] == "final" && (string?)e["session_id"] == "obsolete");
        await Event(audioCore, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        Check(!observed.Any(e => (string?)e["type"] == "partial" && (string?)e["session_id"] == "obsolete"), "in-flight preview cannot overwrite finalized segment");
        audioAsr.Calls = 0; audioAsr.InferenceEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var pressureGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); audioAsr.InferenceHold = pressureGate.Task;
        audioCore.Control(Command("start", "pressure"));
        var pressure = new byte[7 * 53 * 640];
        for (int i = 0; i < 7; ++i) voice.CopyTo(pressure, i * 53 * 640);
        audioCore.Audio("pressure", 0, 0, pressure);
        await Event(audioCore, e => (string?)e["type"] == "error" && ((string?)e["message"])!.Contains("6 句"));
        await audioAsr.InferenceEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)); pressureGate.SetResult();
        for (int i = 0; i < 7; ++i) await Event(audioCore, e => (string?)e["type"] == "final" && (string?)e["session_id"] == "pressure");
        await Event(audioCore, e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        Check(audioAsr.Calls == 7 && observed.Count(e => (string?)e["type"] == "final" && (string?)e["session_id"] == "pressure") == 7, "backpressure stops capture and drains all accepted finals exactly once");
        var detector = new BlockingVad(); audioCore.SetVoiceDetectorFactory(() => detector);
        await channel.ControlAsync(Command("start", "overflow")); channel.Audio("overflow", 0, 0, new byte[640]);
        Check(detector.Entered.Wait(TimeSpan.FromSeconds(5)), "slow audio processing fixture entered");
        channel.Audio("overflow", 1, 320, new byte[150000]); channel.Audio("overflow", 2, 75320, new byte[150000]);
        Check(!channel.Audio("overflow", 3, 150320, new byte[32000]), "capture mailbox refuses over 320 KB without blocking producer");
        detector.Release.Set(); await channel.ControlAsync(Command("stop", "overflow"));
        await Event(audioCore, e => (string?)e["type"] == "error" && ((string?)e["message"])!.Contains("320 KB")); Check(true, "mailbox overflow is reported after draining accepted packets");
    }
    await TranslationChecks.Run(root, Check);
    await NetworkChecks.Run(root, Check);
    LiveAudioChecks.Run(Check);
    Console.WriteLine($"ALL {checks} BACKEND CHECKS PASSED"); return 0;
}
catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }

sealed class FakeAsr : IAsrEngine
{
    public bool IsLoaded { get; private set; }
    public string Model = "";
    public string Output = "测试。";
    public int Calls;
    public Task? InferenceHold;
    public TaskCompletionSource InferenceEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task? Hold;
    public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public async Task LoadAsync(EngineModel model, string language, CancellationToken ct)
    {
        IsLoaded = false; Entered.TrySetResult(); if (Hold != null) { await Hold.WaitAsync(ct); Hold = null; }
        if (model.Path.EndsWith("bad")) throw new InvalidOperationException("模拟模型损坏。"); Model = model.Path; IsLoaded = true;
    }
    public Task WarmupAsync(CancellationToken ct) => Model.EndsWith("warm-failure") ? Task.FromException(new Exception("模拟预热失败。")) : Task.CompletedTask;
    public async Task<string> TranscribeAsync(ReadOnlyMemory<byte> pcm, CancellationToken ct) { Interlocked.Increment(ref Calls); InferenceEntered.TrySetResult(); if (InferenceHold is Task hold) { InferenceHold = null; await hold.WaitAsync(ct); } return Output; }
    public Task UnloadAsync() { IsLoaded = false; return Task.CompletedTask; }
    public ValueTask DisposeAsync() { IsLoaded = false; return ValueTask.CompletedTask; }
}
sealed class FakeTranslator : ITranslatorEngine
{
    public bool IsLoaded { get; private set; }
    public Task LoadAsync(EngineModel model, CancellationToken ct) { IsLoaded = true; return Task.CompletedTask; }
    public Task WarmupAsync(CancellationToken ct) => Task.CompletedTask;
    public async IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatMessage> messages, int maxTokens, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct) { await Task.Yield(); yield return "translation"; }
    public Task UnloadAsync() { IsLoaded = false; return Task.CompletedTask; }
    public ValueTask DisposeAsync() { IsLoaded = false; return ValueTask.CompletedTask; }
}
sealed class FakeResolver : IModelResolver
{
    public ModelResolution Resolve(ModelConfig config, RuntimeConfig runtime) => new(new("qwen", config.ModelId), "test-revision");
    public ModelResolution Resolve(TranslationConfig config, RuntimeConfig runtime) => new(new("qwen3", config.ModelId), "test-revision");
}
sealed class FakeDownloader : IModelDownloader
{
    public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource<ModelResolution> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<ModelResolution> DownloadAsync(string role, string modelId, string revision, RuntimeConfig runtime, IProgress<(string Detail, long Completed, long Total)> progress, CancellationToken ct) { Entered.SetResult(); return Result.Task; }
}
sealed class MarkedVad : IVoiceDetector
{
    public bool IsSpeech(ReadOnlySpan<byte> pcm) => pcm[0] == 1;
    public void Dispose() { }
}
sealed class BlockingVad : IVoiceDetector
{
    public readonly ManualResetEventSlim Entered = new(), Release = new();
    public bool IsSpeech(ReadOnlySpan<byte> pcm) { Entered.Set(); Release.Wait(TimeSpan.FromSeconds(10)); return false; }
    public void Dispose() { Entered.Dispose(); Release.Dispose(); }
}
