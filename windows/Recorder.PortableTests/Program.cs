using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Recorder.Backend;

// Usage: Recorder.PortableTests <fake-native-output-dir> [workspace] [--rounds N]
if (args.Length < 1) { Console.Error.WriteLine("Usage: Recorder.PortableTests <fake-native-output-dir> [workspace] [--rounds N]"); return 2; }
int rounds = args.SkipWhile(a => a != "--rounds").Skip(1).Select(int.Parse).DefaultIfEmpty(60).First();
var workspace = args.Length > 1 && !args[1].StartsWith("--") ? Path.GetFullPath(args[1]) : Directory.GetCurrentDirectory();
var root = Path.Combine(workspace, ".bootstrap", "portable-tests-" + Guid.NewGuid().ToString("N"));
var runtime = Path.Combine(root, "runtime");
var unhandled = new ConcurrentQueue<string>();
AppDomain.CurrentDomain.UnhandledException += (_, e) => { unhandled.Enqueue("UnhandledException: " + e.ExceptionObject); Console.Error.WriteLine("UNHANDLED: " + e.ExceptionObject); };
TaskScheduler.UnobservedTaskException += (_, e) => { unhandled.Enqueue("UnobservedTaskException: " + e.Exception); e.SetObserved(); };
int checks = 0;
void Check(bool value, string detail) { if (!value) throw new Exception("FAIL: " + detail); checks++; Console.WriteLine("PASS: " + detail); }
try
{
    FakeRuntime.Install(Path.GetFullPath(args[0]), runtime);
    await Scenarios.TargetLanguageStorm(root, runtime, rounds, Check);
    await Scenarios.TargetDuringTranslatorLoad(root, runtime, Check);
    await Scenarios.RecognitionLanguageSwitch(root, runtime, rounds, Check);
    await Scenarios.NativeExitDuringSwitch(root, runtime, Check);
    await Scenarios.MissingCudaRuntime(runtime, Check);
    await CudaRuntimeChecks.Run(root, workspace, Check);
    GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
    Check(unhandled.IsEmpty, "no unhandled or unobserved exceptions" + (unhandled.IsEmpty ? "" : ":\n" + string.Join("\n", unhandled)));
    Console.WriteLine($"ALL {checks} PORTABLE CHECKS PASSED"); return 0;
}
catch (Exception ex) { Console.Error.WriteLine(ex); foreach (var item in unhandled) Console.Error.WriteLine(item); return 1; }
finally { try { Directory.Delete(root, true); } catch { } }

static class FakeRuntime
{
    public static void Install(string build, string runtime)
    {
        string host = OperatingSystem.IsWindows() ? "recorder-fake-native.exe" : "recorder-fake-native";
        if (!File.Exists(Path.Combine(build, host))) throw new FileNotFoundException("Build Recorder.FakeNative first.", Path.Combine(build, host));
        foreach (var device in new[] { "cpu", "cuda" })
        {
            var target = Path.Combine(runtime, device); Directory.CreateDirectory(target);
            foreach (var file in Directory.GetFiles(build)) File.Copy(file, Path.Combine(target, Path.GetFileName(file)), true);
            // The apphost locates recorder-fake-native.dll by its embedded name, so a renamed copy still starts the fake.
            File.Copy(Path.Combine(build, host), Path.Combine(target, "recorder-native.exe"), true);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(Path.Combine(target, "recorder-native.exe"), (UnixFileMode)0b111_101_101);
        }
    }
}

sealed class Resolver : IModelResolver
{
    public ModelResolution Resolve(ModelConfig config, RuntimeConfig runtime) => new(new(runtime.AsrEngine, "/fake/" + config.ModelId, runtime.AsrEngine == "qwen" ? "/fake/mmproj.gguf" : "", runtime.Device), "rev");
    public ModelResolution Resolve(TranslationConfig config, RuntimeConfig runtime) => new(new(runtime.TranslatorEngine, "/fake/" + config.ModelId, "", runtime.TranslatorDevice), "rev");
}
sealed class LoudVad : IVoiceDetector { public bool IsSpeech(ReadOnlySpan<byte> pcm) => pcm[0] != 0; public void Dispose() { } }

/// <summary>Same request correlation as the desktop app: one waiter per request id, completed by backend events.</summary>
sealed class Harness : IAsyncDisposable
{
    public readonly BackendCore Core; public readonly BackendChannel Channel; public readonly NativeEngine Asr, Translator;
    private readonly Task receiver;
    private readonly BackendRequests requests = new();
    public readonly ConcurrentQueue<JsonObject> Events = new();
    public Harness(string root, string runtime)
    {
        Asr = new NativeEngine(runtime); Translator = new NativeEngine(runtime);
        Core = new BackendCore(new ConfigStore(root), Asr, Translator, new Resolver());
        Core.SetVoiceDetectorFactory(() => new LoudVad());
        Channel = new(Core); receiver = Task.Run(ReceiveAsync);
    }
    public static JsonObject Command(string command, string session = "") => new() { ["protocol_version"] = 1, ["request_id"] = Guid.NewGuid().ToString("N"), ["command"] = command, ["session_id"] = session };
    public Task CallAsync(JsonObject command, string role, TimeSpan timeout) =>
        requests.RunAsync(Channel, command, role switch { "asr" => BackendRequests.Kind.Asr, "translator" => BackendRequests.Kind.Translator, _ => BackendRequests.Kind.Preferences }, timeout);
    public Task LoadAsr(ModelConfig config, RuntimeConfig options) { var c = Command("load"); c["config"] = BackendJson.Object(config); c["runtime"] = BackendJson.Object(options); return CallAsync(c, "asr", TimeSpan.FromSeconds(20)); }
    public Task LoadTranslator(TranslationConfig config, RuntimeConfig options) { var c = Command("load"); c["role"] = "translator"; c["translation"] = BackendJson.Object(config); c["runtime"] = BackendJson.Object(options); return CallAsync(c, "translator", TimeSpan.FromSeconds(20)); }
    public Task Preferences(TranslationConfig t)
    {
        var c = Command("translation_settings"); c["enabled"] = t.Enabled; c["provider"] = t.Provider; c["api_profile"] = t.ApiProfile; c["target_language"] = t.TargetLanguage;
        return CallAsync(c, "preferences", TimeSpan.FromSeconds(10));
    }
    private async Task ReceiveAsync()
    {
        await foreach (var message in Core.Events.ReadAllAsync())
        {
            Events.Enqueue(message);
            requests.Observe(message);
        }
        requests.FailAll(new IOException("后端已关闭。"));
    }
    public async Task<JsonObject> WaitEvent(Func<JsonObject, bool> test, TimeSpan timeout)
    {
        var until = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < until) { foreach (var e in Events) if (test(e)) return e; await Task.Delay(10); }
        throw new TimeoutException("Missing backend event");
    }
    public async ValueTask DisposeAsync() { await Channel.DisposeAsync(); await receiver; }
}

static class Scenarios
{
    static readonly string[] Targets = Languages.Targets;
    static readonly RuntimeConfig Cpu = new() { Device = "cpu", TranslatorDevice = "cpu", AsrEngine = "qwen", TranslatorEngine = "qwen3" };

    /// <summary>Main-window translation menu: switch target while finals keep queueing and tokens are streaming.</summary>
    public static async Task TargetLanguageStorm(string root, string runtime, int rounds, Action<bool, string> check)
    {
        Environment.SetEnvironmentVariable("FAKE_TOKEN_MS", "4");
        await using var h = new Harness(Path.Combine(root, "storm"), runtime);
        await h.LoadAsr(new ModelConfig { Provider = "api", ApiProtocol = "qwen_realtime" }, Cpu);
        await h.LoadTranslator(new TranslationConfig { Enabled = true, TargetLanguage = "English" }, Cpu);
        var random = new Random(7); int segment = 0, failures = 0; var translation = new TranslationConfig { Enabled = true, TargetLanguage = "English" };
        for (int round = 0; round < rounds; round++)
        {
            string session = "storm-" + round;
            await h.Channel.ControlAsync(Harness.Command("start", session));
            for (int i = 0; i < 3; i++)
            {
                var f = Harness.Command("asr_stream_final", session); f["segment_id"] = ++segment; f["start_sample"] = 0; f["text"] = "第" + segment + "句话。"; await h.Channel.ControlAsync(f);
            }
            await h.Channel.ControlAsync(Harness.Command("stop", session));
            await Task.Delay(random.Next(0, 25));
            translation = translation with { TargetLanguage = Targets[random.Next(Targets.Length)], Enabled = random.Next(12) != 0 };
            try { await h.Preferences(translation); }
            catch (InvalidOperationException ex) when (ex.Message.Contains("请等待")) { failures++; translation = h.Core.Translation; }
            if (!translation.Enabled) { translation = translation with { Enabled = true }; await RetryPreferences(h, translation); }
        }
        var final = await WaitIdle(h);
        check(final, "translation queue drains after target-language storm");
        check(h.Core.Translation.TargetLanguage == translation.TargetLanguage && new ConfigStore(Path.Combine(root, "storm")).Load("translation.json", new TranslationConfig()).TargetLanguage == translation.TargetLanguage, "last chosen target language is active and persisted");
        var units = h.Events.Where(e => (string?)e["type"] == "translation").GroupBy(e => (long)e["unit_id"]!).ToArray();
        check(units.All(u => u.Any(e => (bool)e["done"]!)), $"every one of {units.Length} translation units ends exactly with a done event");
        check(h.Core.State == "ready" && h.Asr.IsLoaded == false && h.Core.TranslationReady, "backend stays ready with translator loaded after storm");
        Console.WriteLine($"INFO: {failures} enable/disable toggles were refused while the translator was loading.");
    }

    /// <summary>Choosing a target language while the translator is still loading is accepted and survives the load commit.</summary>
    public static async Task TargetDuringTranslatorLoad(string root, string runtime, Action<bool, string> check)
    {
        Environment.SetEnvironmentVariable("FAKE_LOAD_MS", "400");
        try
        {
            await using var h = new Harness(Path.Combine(root, "deferred"), runtime);
            await h.LoadAsr(new ModelConfig { Provider = "api", ApiProtocol = "qwen_realtime" }, Cpu);
            // The control channel is FIFO: a command sent right after a 400 ms load is processed while that load runs.
            var loading = h.LoadTranslator(new TranslationConfig { Enabled = true, TargetLanguage = "English" }, Cpu);
            await h.Preferences(new TranslationConfig { Enabled = true, TargetLanguage = "日本語" });
            check(h.Core.TranslatorState is "loading" or "warming", "target switch accepted while translator is loading");
            await loading;
            check(h.Core.TranslationReady && h.Core.Translation.TargetLanguage == "日本語", "target chosen during load is kept when the load commits");
            check(new ConfigStore(Path.Combine(root, "deferred")).Load("translation.json", new TranslationConfig()).TargetLanguage == "日本語", "target chosen during load is persisted");
            var switching = h.LoadTranslator(new TranslationConfig { Enabled = true, TargetLanguage = "日本語", ModelId = "test/other" }, Cpu);
            await h.Preferences(new TranslationConfig { Enabled = false, TargetLanguage = "日本語" });
            try { await switching; } catch (InvalidOperationException) { }
            for (int i = 0; i < 200 && h.Core.TranslatorState != "idle"; i++) await Task.Delay(10);
            check(h.Core.TranslatorState == "idle" && !h.Translator.IsLoaded && !h.Core.Translation.Enabled, "turning translation off during a load cancels the load and unloads the model");
            check(!h.Events.Any(e => (string?)e["type"] == "translator" && (string?)e["state"] == "error"), "user cancellation of a translator load is not reported as an error");
            await h.Preferences(new TranslationConfig { Enabled = true, TargetLanguage = "한국어" });
            for (int i = 0; i < 300 && !h.Core.TranslationReady; i++) await Task.Delay(10);
            check(h.Core.TranslationReady && h.Core.Translation.TargetLanguage == "한국어", "re-enabling translation auto-loads the translator with the chosen target");
        }
        finally { Environment.SetEnvironmentVariable("FAKE_LOAD_MS", null); }
    }
    static async Task RetryPreferences(Harness h, TranslationConfig t)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { await h.Preferences(t); return; }
            catch (InvalidOperationException ex) when (ex.Message.Contains("请等待") && attempt < 400) { await Task.Delay(25); }
        }
    }
    static async Task<bool> WaitIdle(Harness h)
    {
        // Settled = every unit done, backend ready, and nothing new for several polls (finals may still be planning units).
        int stable = 0, seen = -1;
        for (int i = 0; i < 1500 && stable < 5; i++)
        {
            var units = h.Events.Where(e => (string?)e["type"] == "translation").GroupBy(e => (long)e["unit_id"]!).ToArray();
            bool settled = units.All(u => u.Any(e => (bool)e["done"]!)) && h.Core.TranslatorState is "ready" or "idle" && h.Core.State == "ready" && h.Events.Count == seen;
            stable = settled ? stable + 1 : 0; seen = h.Events.Count;
            await Task.Delay(20);
        }
        return stable >= 5;
    }

    /// <summary>Settings page: change only the recognition language and save while translations of the last session still run.</summary>
    public static async Task RecognitionLanguageSwitch(string root, string runtime, int rounds, Action<bool, string> check)
    {
        Environment.SetEnvironmentVariable("FAKE_TOKEN_MS", "6");
        await using var h = new Harness(Path.Combine(root, "recognition"), runtime);
        var config = new ModelConfig { ModelId = "ggml-org/Qwen3-ASR-1.7B-GGUF", EndpointMode = "fixed" };
        await h.LoadAsr(config, Cpu);
        await h.LoadTranslator(new TranslationConfig { Enabled = true, TargetLanguage = "English" }, Cpu);
        int asrProcess = h.Asr.ProcessId ?? 0, reloads = 0;
        var voice = Enumerable.Range(0, 60 * 320).SelectMany(_ => new byte[] { 1, 0 }).ToArray();
        for (int round = 0; round < Math.Max(4, rounds / 6); round++)
        {
            string session = "lang-" + round;
            await h.Channel.ControlAsync(Harness.Command("start", session));
            h.Channel.Audio(session, 0, 0, voice);
            await h.Channel.ControlAsync(Harness.Command("stop", session));
            await h.WaitEvent(e => (string?)e["type"] == "status" && (string?)e["state"] == "ready" && (string?)e["session_id"] == session, TimeSpan.FromSeconds(20));
            config = config with { Language = Languages.Recognition[(round + 1) % Languages.Recognition.Length] };
            await h.LoadAsr(config, Cpu);
            if (h.Asr.ProcessId != asrProcess) { reloads++; asrProcess = h.Asr.ProcessId ?? 0; }
            check(h.Core.Config.Language == config.Language, "recognition language switched to " + config.Language);
        }
        check(await WaitIdle(h), "translations of earlier sessions finish after recognition-language switches");
        var expected = h.Events.Where(e => (string?)e["type"] == "final").Select(e => (string?)e["text"]).ToArray();
        check(expected.Any(t => t!.Contains("(English)")) && expected.Any(t => t!.Contains("(Chinese)")), "new language hint reaches the native engine");
        check(reloads == 0, $"language-only changes keep the loaded model and native worker ({reloads} restarts)");
        check(new ConfigStore(Path.Combine(root, "recognition")).Load("config.json", new ModelConfig()).Language == config.Language, "in-place language switch is persisted");
        await h.LoadAsr(config with { ModelId = "test/other-asr" }, Cpu);
        check(h.Asr.ProcessId != asrProcess, "changing the model itself still reloads the worker");
    }

    /// <summary>Native translator dies mid-generation; switching language afterwards and reloading must recover without stale errors.</summary>
    public static async Task NativeExitDuringSwitch(string root, string runtime, Action<bool, string> check)
    {
        Environment.SetEnvironmentVariable("FAKE_TOKEN_MS", "10");
        // Warmup generates one token, so the worker dies on the first real translation token.
        Environment.SetEnvironmentVariable("FAKE_EXIT_AFTER_TOKENS", "2");
        await using var h = new Harness(Path.Combine(root, "exit"), runtime);
        await h.LoadAsr(new ModelConfig { Provider = "api", ApiProtocol = "qwen_realtime" }, Cpu);
        await h.LoadTranslator(new TranslationConfig { Enabled = true, TargetLanguage = "English" }, Cpu);
        Environment.SetEnvironmentVariable("FAKE_EXIT_AFTER_TOKENS", null);
        await h.Channel.ControlAsync(Harness.Command("start", "exit"));
        for (int i = 1; i <= 3; i++) { var f = Harness.Command("asr_stream_final", "exit"); f["segment_id"] = i; f["start_sample"] = 0; f["text"] = "崩溃前第" + i + "句。"; await h.Channel.ControlAsync(f); }
        await h.Channel.ControlAsync(Harness.Command("stop", "exit"));
        await h.WaitEvent(e => (string?)e["type"] == "translator" && (string?)e["state"] == "error", TimeSpan.FromSeconds(10));
        check(!h.Translator.IsLoaded, "native translator exit is reported as translator error");
        await h.Preferences(new TranslationConfig { Enabled = true, TargetLanguage = "日本語" });
        check(h.Core.Translation.TargetLanguage == "日本語", "target language can be switched after the translator crashed");
        Environment.SetEnvironmentVariable("FAKE_LOAD_MS", "300");
        var reload = h.LoadTranslator(new TranslationConfig { Enabled = true, TargetLanguage = "日本語" }, Cpu);
        await h.Preferences(new TranslationConfig { Enabled = true, TargetLanguage = "한국어" });
        check(h.Core.TranslatorState is "loading" or "warming", "target switch arrives while the reload is running");
        await reload; Environment.SetEnvironmentVariable("FAKE_LOAD_MS", null);
        check(h.Core.TranslationReady && h.Core.Translation.TargetLanguage == "한국어", "translator reload after native exit succeeds and keeps the target chosen during reload");
        Environment.SetEnvironmentVariable("FAKE_EXIT_ON_LANGUAGE", "Korean");
        var local = new ModelConfig { ModelId = "ggml-org/Qwen3-ASR-1.7B-GGUF", EndpointMode = "fixed" };
        await h.LoadAsr(local, Cpu);
        Environment.SetEnvironmentVariable("FAKE_EXIT_ON_LANGUAGE", null);
        await h.LoadAsr(local with { Language = "Korean" }, Cpu);
        var voice = Enumerable.Range(0, 60 * 320).SelectMany(_ => new byte[] { 1, 0 }).ToArray();
        await h.Channel.ControlAsync(Harness.Command("start", "korean")); h.Channel.Audio("korean", 0, 0, voice);
        var failure = await h.WaitEvent(e => (string?)e["type"] == "status" && (string?)e["state"] == "error", TimeSpan.FromSeconds(10));
        // POSIX keeps only the low 8 bits of the exit status.
        string code = OperatingSystem.IsWindows() ? "0xC0000005" : "退出码 5";
        var notice = await h.WaitEvent(e => (string?)e["type"] == "error" && ((string?)e["message"] ?? "").Contains(code), TimeSpan.FromSeconds(10));
        check(true, "native ASR crash reports the exit code: " + notice["message"]);
        await h.Channel.ControlAsync(Harness.Command("stop", "korean"));
        await h.LoadAsr(local with { Language = "Chinese" }, Cpu);
        check(h.Core.State == "ready" && h.Asr.IsLoaded, "ASR reload after a native crash recovers");
    }

    /// <summary>Without the downloadable CUDA libraries, auto uses the CPU silently and explicit CUDA explains what to install.</summary>
    public static async Task MissingCudaRuntime(string runtime, Action<bool, string> check)
    {
        await using var engine = new NativeEngine(runtime, device => device == "cuda" ? null : []);
        int notices = 0; engine.Notice += _ => notices++;
        await engine.LoadAsync(new EngineModel("qwen3", "/fake/translator", "", "auto"), default);
        check(engine.ActiveDevice == "cpu" && notices == 0, "auto device skips CUDA quietly when the GPU runtime is not installed");
        try { await engine.LoadAsync(new EngineModel("qwen3", "/fake/translator", "", "cuda"), default); check(false, "explicit CUDA without runtime must fail"); }
        catch (InvalidOperationException ex) { check(ex.Message.Contains("GPU 加速组件") && !engine.IsLoaded, "explicit CUDA without runtime asks to install the GPU component"); }
    }
}
