using System.Text.Json.Nodes;
using Recorder.Backend;
internal static class TranslationChecks
{
    public static async Task Run(string root, Action<bool, string> check)
    {
        check(TranslationText.AlreadyInTarget("这是中文。", "简体中文") && !TranslationText.AlreadyInTarget("这是中文。", "繁體中文"), "script skip distinguishes simplified target from traditional conversion");
        check(!TranslationText.AlreadyInTarget("Hello world", "English") && TranslationText.AlreadyInTarget("日本語です", "日本語") && TranslationText.AlreadyInTarget("안녕하세요", "한국어"), "unambiguous scripts skip while Latin languages still translate");
        check(TranslationText.Same("Hello, WORLD!", "hello world") && !TranslationText.Same("你好你好", "你好"), "translation comparison ignores punctuation but preserves repeated words");
        var planner = new TranslationPlanner();
        check(planner.Add("a", 1, "这是测试。", true) == null, "forced cut holds incomplete last sentence");
        check(planner.Add("a", 2, "继续。", false) == new TranslationUnit(2, "这是测试继续。"), "translation carry joins once and anchors current final");
        check(planner.Add("a", 3, "First. Second.", true) == new TranslationUnit(3, "First."), "forced cut releases complete preceding sentence");
        check(planner.Flush("a") == new TranslationUnit(3, "Second") && planner.Flush("a") == null, "stop flushes translation carry once");
        check(TranslationText.Messages("hunyuan", "你好", "English", []).Single().Role == "user", "Hunyuan uses single-turn model prompt");
        var translator = new ControlledTranslator();
        await using var core = new BackendCore(new ConfigStore(Path.Combine(root, "translation")), new FakeAsr(), translator, new FakeResolver());
        JsonObject Command(string name, string session = "old") => new() { ["command"] = name, ["protocol_version"] = 1, ["session_id"] = session };
        var seen = new List<JsonObject>();
        async Task<JsonObject> Wait(Func<JsonObject, bool> predicate)
        {
            using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            while (await core.Events.WaitToReadAsync(ct.Token)) while (core.Events.TryRead(out var e)) { seen.Add(e); if (predicate(e)) return e; }
            throw new Exception("Missing translation event");
        }
        var load = Command("load"); load["config"] = BackendJson.Object(new ModelConfig { Provider = "api", ApiProtocol = "qwen_realtime" }); core.Control(load);
        await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        load = Command("load"); load["role"] = "translator"; load["translation"] = BackendJson.Object(new TranslationConfig { Enabled = true, TargetLanguage = "English" }); core.Control(load);
        await Wait(e => (string?)e["type"] == "translator" && (string?)e["state"] == "ready");
        core.Control(Command("start"));
        void Final(int segment, string session = "old") { var f = Command("asr_stream_final", session); f["segment_id"] = segment; f["start_sample"] = 0; f["text"] = "你好" + segment; core.Control(f); }
        Final(1); await translator.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Final(2); core.Control(Command("stop"));
        translator.Release.TrySetResult();
        await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        core.Control(Command("start", "new")); Final(1, "new");
        var done = await Wait(e => (string?)e["type"] == "translation" && (bool?)e["done"] == true && (string?)e["session_id"] == "old");
        check((string?)done["text"] == "Hello world." && (bool?)done["skipped"] == false, "translation finishes with cumulative text on original session");
        int final2 = seen.FindIndex(e => (string?)e["type"] == "final" && (int?)e["segment_id"] == 2);
        int translated = seen.FindIndex(e => (string?)e["type"] == "translation" && (bool?)e["done"] == true);
        check(final2 >= 0 && final2 < translated, "ASR finals preempt translation between token pulls");
        await Wait(e => (string?)e["type"] == "translation" && (bool?)e["done"] == true && (string?)e["session_id"] == "new");
        check(translator.Messages.Last().Count == 2, "translation context never leaks across sessions");
        core.Control(Command("stop", "new")); await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
        translator.Release = new(TaskCreationOptions.RunContinuationsAsynchronously); translator.Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        core.Control(Command("start", "pressure")); Final(1, "pressure"); await translator.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        for (int i = 2; i <= 8; i++) Final(i, "pressure");
        translator.Release.TrySetResult();
        await Wait(e => (string?)e["type"] == "error" && ((string?)e["message"] ?? "").Contains("翻译跟不上"));
        check(core.State == "recording" && seen.Any(e => (string?)e["type"] == "translation" && (bool?)e["skipped"] == true), "translation overload drops old waiting units and preserves recording");
        await Wait(e => (string?)e["type"] == "translation" && (bool?)e["done"] == true && (int?)e["segment_id"] == 8);
        translator.Release = new(TaskCreationOptions.RunContinuationsAsynchronously); translator.Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        Final(9, "pressure"); await translator.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var disable = Command("translation_settings"); disable["enabled"] = false; core.Control(disable);
        await Wait(e => (string?)e["type"] == "translator" && (string?)e["state"] == "idle");
        check(!translator.IsLoaded, "disabling translation releases generator and model");
        check(core.State == "recording", "cancelling blocked translation never changes ASR recording state");
        core.SetApiTranslationFactory(_ => new FailingTranslator());
        var api = Command("translation_settings"); api["enabled"] = true; api["provider"] = "api"; core.Control(api);
        await Wait(e => (string?)e["type"] == "translator" && (string?)e["state"] == "idle");
        Final(10, "pressure"); await Wait(e => (string?)e["type"] == "error" && ((string?)e["message"] ?? "").Contains("翻译失败"));
        check(core.State == "recording", "translation transport failure preserves active ASR session");
        core.Control(Command("stop", "pressure")); await Wait(e => (string?)e["type"] == "status" && (string?)e["state"] == "ready");
    }
}
internal sealed class FailingTranslator : ITranslatorEngine
{
    public bool IsLoaded => true;
    public Task LoadAsync(EngineModel model, CancellationToken ct) => Task.CompletedTask;
    public Task WarmupAsync(CancellationToken ct) => Task.CompletedTask;
    public async IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatMessage> messages, int maxTokens, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct) { yield return await Task.FromException<string>(new IOException("synthetic connection failure")); }
    public Task UnloadAsync() => Task.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
internal sealed class ControlledTranslator : ITranslatorEngine
{
    public bool IsLoaded { get; private set; }
    public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously), Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public List<IReadOnlyList<ChatMessage>> Messages = new();
    public Task LoadAsync(EngineModel model, CancellationToken ct) { IsLoaded = true; return Task.CompletedTask; }
    public Task WarmupAsync(CancellationToken ct) => Task.CompletedTask;
    public async IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatMessage> messages, int maxTokens, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
    { Messages.Add(messages); Entered.TrySetResult(); await Release.Task.WaitAsync(ct); yield return "Hello "; await Task.Yield(); yield return "world."; }
    public Task UnloadAsync() { IsLoaded = false; return Task.CompletedTask; }
    public ValueTask DisposeAsync() { IsLoaded = false; return ValueTask.CompletedTask; }
}
