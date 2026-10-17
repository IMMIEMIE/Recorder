using System.Text.Json.Nodes;
using Recorder.Backend;

int checks = 0;
void Check(bool value, string detail) { if (!value) throw new Exception("FAIL: " + detail); checks++; Console.WriteLine("PASS: " + detail); }
void Reject(Action action, string detail) { try { action(); } catch { Check(true, detail); return; } throw new Exception("FAIL: " + detail); }
JsonObject Command(string name, string session = "test") => new() { ["protocol_version"] = 1, ["command"] = name, ["request_id"] = Guid.NewGuid().ToString("N"), ["session_id"] = session };
async Task<JsonObject> Event(BackendCore core, Func<JsonObject, bool> test)
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
    while (await core.Events.WaitToReadAsync(timeout.Token)) while (core.Events.TryRead(out var item)) if (test(item)) return item;
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
    Console.WriteLine($"ALL {checks} BACKEND CHECKS PASSED"); return 0;
}
catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }

sealed class FakeAsr : IAsrEngine
{
    public bool IsLoaded { get; private set; }
    public string Model = "";
    public Task? Hold;
    public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public async Task LoadAsync(EngineModel model, string language, CancellationToken ct)
    {
        IsLoaded = false; Entered.TrySetResult(); if (Hold != null) { await Hold.WaitAsync(ct); Hold = null; }
        if (model.Path.EndsWith("bad")) throw new InvalidOperationException("模拟模型损坏。"); Model = model.Path; IsLoaded = true;
    }
    public Task WarmupAsync(CancellationToken ct) => Model.EndsWith("warm-failure") ? Task.FromException(new Exception("模拟预热失败。")) : Task.CompletedTask;
    public Task<string> TranscribeAsync(ReadOnlyMemory<byte> pcm, CancellationToken ct) => Task.FromResult("测试。");
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
    public Task<ModelResolution> DownloadAsync(string role, string modelId, string revision, IProgress<(string Detail, long Completed, long Total)> progress, CancellationToken ct) { Entered.SetResult(); return Result.Task; }
}
