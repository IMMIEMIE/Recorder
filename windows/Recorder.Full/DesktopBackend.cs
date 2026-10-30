using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Recorder.Backend;

namespace Recorder.Windows;

internal sealed class DesktopBackend : IAsyncDisposable
{
    private static readonly Lazy<DesktopBackend> shared = new(() => new());
    public static DesktopBackend Shared => shared.Value;
    public static ValueTask ShutdownAsync() => shared.IsValueCreated ? shared.Value.DisposeAsync() : ValueTask.CompletedTask;
    public ModelManager Models { get; }
    public CudaRuntime Cuda { get; }
    public BackendCore Core { get; }
    public BackendChannel Channel { get; }
    private readonly Task receiver;
    private readonly BackendRequests requests = new();
    private readonly ConcurrentDictionary<string, Action<JsonObject>> sessions = new();
    public event Action<JsonObject>? Event;
    private DesktopBackend()
    {
        Models = new ModelManager(SettingsStore.Root); var runtime = Path.Combine(AppContext.BaseDirectory, "runtime");
        Cuda = new CudaRuntime(SettingsStore.Root, runtime);
        var asr = new NativeEngine(runtime, Cuda.DllDirectories); var translator = new NativeEngine(runtime, Cuda.DllDirectories);
        Core = new BackendCore(new ConfigStore(SettingsStore.Root), asr, translator, Models, Models,
            (config, key) => new HttpEngine(new AppSettings { ApiBase = config.ApiBaseUrl, ApiModel = config.ApiModel, Language = config.Language switch { "Chinese" => "zh", "English" => "en", "Cantonese" => "yue", "Japanese" => "ja", "Korean" => "ko", _ => "auto" }, ApiSecret = SettingsStore.Protect(key) }));
        Core.SetVoiceDetectorFactory(() => new WebRtcVad(Path.Combine(runtime, "cpu/recorder-vad.dll")));
        Core.SetApiTranslationFactory(t =>
        {
            var profiles = new ProfileStore(SettingsStore.Root);
            if (t.ApiProfile.Length > 0) { var p = profiles.Get(t.ApiProfile); return new ChatClient(p, profiles.Key(p)); }
            var s = SettingsStore.Load(); return new ChatClient(new ServiceProfile(ServiceProfile.Normalize(s.TranslationBase), s.TranslationModel), SettingsStore.Reveal(s.TranslationSecret));
        });
        asr.Notice += message => Publish(new JsonObject { ["type"] = "error", ["message"] = message });
        translator.Notice += message => Publish(new JsonObject { ["type"] = "translator", ["state"] = "loading", ["detail"] = message });
        Channel = new(Core); receiver = Task.Run(ReceiveAsync);
    }
    public static JsonObject Command(string command, string? session = null) => new() { ["protocol_version"] = 1, ["request_id"] = Guid.NewGuid().ToString("N"), ["command"] = command, ["session_id"] = session ?? "" };
    public async Task ApplyAsync(AppSettings settings, bool download = false, string role = "asr", CancellationToken ct = default)
    {
        if (settings.Mode == "live" && role == "asr") return;
        if (role == "asr" && Core.State == "error") while (!Core.CanSelectAsr) await Task.Delay(25, ct);
        var command = Command(download ? "download" : "load"); command["role"] = role; command["runtime"] = BackendJson.Object(settings.RuntimeConfig());
        if (role == "asr") { command["config"] = BackendJson.Object(settings.RecognitionConfig()); command["api_key"] = settings.Mode == "api" ? SettingsStore.Reveal(settings.ApiSecret) : ""; }
        else command["translation"] = BackendJson.Object(settings.TranslationConfig() with { Provider = "local" });
        await requests.RunAsync(Channel, command, role == "asr" ? BackendRequests.Kind.Asr : BackendRequests.Kind.Translator, ct: ct);
    }
    public async Task EnsureAsync(AppSettings settings, CancellationToken ct)
    {
        if (Core.State != "ready" || Core.Config != settings.RecognitionConfig() || Core.Runtime != settings.RuntimeConfig()) await ApplyAsync(settings, ct: ct);
        bool waited = Core.TranslatorState is "loading" or "warming" or "downloading";
        await WaitTranslatorIdleAsync(ct);
        if (NeedsTranslatorLoad(settings))
        {
            try { if (waited && Core.TranslatorState == "error") throw new InvalidOperationException("翻译模型未能加载，请在设置中检查模型。"); await ApplyAsync(settings, role: "translator", ct: ct); }
            catch (Exception ex) when (!ct.IsCancellationRequested) { Publish(new JsonObject { ["type"] = "error", ["message"] = "翻译暂不可用，继续识别原文：" + ex.Message }); }
        }
        var command = Command("translation_settings"); var t = settings.TranslationConfig();
        command["enabled"] = t.Enabled; command["provider"] = t.Provider; command["api_profile"] = t.ApiProfile; command["target_language"] = t.TargetLanguage; await Channel.ControlAsync(command);
    }
    public async Task WaitTranslatorIdleAsync(CancellationToken ct) { while (Core.TranslatorState is "loading" or "warming" or "downloading") await Task.Delay(25, ct); }
    /// <summary>True only when local translation is wanted and the loaded translator differs from the selection.</summary>
    public bool NeedsTranslatorLoad(AppSettings settings)
    {
        if (!settings.Translation || settings.TranslationProvider != "local") return false;
        if (!Core.TranslationReady) return true;
        RuntimeConfig loaded = Core.Runtime, wanted = settings.RuntimeConfig(); var current = Core.Translation;
        return current.ModelId != settings.TranslatorModelId || settings.TranslatorRevision.Length > 0 && current.Revision != settings.TranslatorRevision ||
            loaded.TranslatorDevice != wanted.TranslatorDevice || loaded.TranslatorEngine != wanted.TranslatorEngine || loaded.TranslatorPath != wanted.TranslatorPath || loaded.TranslatorFilename != wanted.TranslatorFilename;
    }
    public async Task PreferencesAsync(AppSettings settings)
    {
        var command = Command("translation_settings"); var t = settings.TranslationConfig();
        command["enabled"] = t.Enabled; command["provider"] = t.Provider; command["api_profile"] = t.ApiProfile; command["target_language"] = t.TargetLanguage;
        await requests.RunAsync(Channel, command, BackendRequests.Kind.Preferences, TimeSpan.FromSeconds(10)); SettingsStore.Save(settings);
    }
    public void Register(string session, Action<JsonObject> handler) => sessions[session] = handler;
    public void ClearHistory() => sessions.Clear();
    public async Task SuspendAsync(CancellationToken ct)
    {
        await Channel.ControlAsync(Command("suspend"));
        while (Core.State == "loading") await Task.Delay(25, ct);
        if (Core.State != "idle") throw new InvalidOperationException("请等待识别停止后再进入 LiveTranslate。");
    }
    private async Task ReceiveAsync()
    {
        await foreach (var message in Core.Events.ReadAllAsync())
        {
            requests.Observe(message);
            if ((string?)message["session_id"] is string session && sessions.TryGetValue(session, out var handler))
            {
                try { handler(message); } catch (Exception ex) { DiagnosticLog.Write("session-event", ex); }
            }
            Publish(message);
        }
        requests.FailAll(new IOException("后端已关闭。"));
    }
    /// <summary>A failing subscriber must not stop event delivery: every later waiter would hang.</summary>
    private void Publish(JsonObject message)
    {
        if (Event is not { } subscribers) return;
        foreach (Action<JsonObject> subscriber in subscribers.GetInvocationList())
        {
            try { subscriber(message); } catch (Exception ex) { DiagnosticLog.Write("backend-event", ex); }
        }
    }
    public async ValueTask DisposeAsync() { await Channel.DisposeAsync(); await receiver; Models.Dispose(); Cuda.Dispose(); }
    private sealed class HttpEngine(AppSettings settings) : IAsrEngine
    {
        private readonly ApiRecognizer recognizer = new(settings);
        public bool IsLoaded { get; private set; } = true;
        public Task LoadAsync(EngineModel model, string language, CancellationToken ct) => Task.CompletedTask;
        public Task WarmupAsync(CancellationToken ct) => Task.CompletedTask;
        public Task<string> TranscribeAsync(ReadOnlyMemory<byte> pcm, CancellationToken ct) => recognizer.TranscribeAsync(pcm.ToArray(), ct);
        public Task UnloadAsync() { IsLoaded = false; return Task.CompletedTask; }
        public ValueTask DisposeAsync() { IsLoaded = false; recognizer.Dispose(); return ValueTask.CompletedTask; }
    }
}
