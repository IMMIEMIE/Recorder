using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Recorder.Backend;

namespace Recorder.Windows;

internal sealed class DesktopBackend : IAsyncDisposable
{
    private static readonly Lazy<DesktopBackend> shared = new(() => new());
    public static DesktopBackend Shared => shared.Value;
    public ModelManager Models { get; }
    public BackendCore Core { get; }
    public BackendChannel Channel { get; }
    private readonly Task receiver;
    private sealed class Pending(string role, TaskCompletionSource completion) { public string Role = role; public TaskCompletionSource Completion = completion; public bool Configured; }
    private readonly ConcurrentDictionary<string, Pending> pending = new();
    private readonly ConcurrentDictionary<string, Action<JsonObject>> sessions = new();
    public event Action<JsonObject>? Event;
    private DesktopBackend()
    {
        Models = new ModelManager(SettingsStore.Root); var runtime = Path.Combine(AppContext.BaseDirectory, "runtime");
        var asr = new NativeEngine(runtime); var translator = new NativeEngine(runtime);
        Core = new BackendCore(new ConfigStore(SettingsStore.Root), asr, translator, Models, Models,
            (config, key) => new HttpEngine(new AppSettings { ApiBase = config.ApiBaseUrl, ApiModel = config.ApiModel, Language = config.Language switch { "Chinese" => "zh", "English" => "en", "Cantonese" => "yue", "Japanese" => "ja", "Korean" => "ko", _ => "auto" }, ApiSecret = SettingsStore.Protect(key) }));
        Core.SetVoiceDetectorFactory(() => new WebRtcVad(Path.Combine(runtime, "cpu/recorder-vad.dll")));
        Core.SetApiTranslationFactory(t =>
        {
            var profiles = new ProfileStore(SettingsStore.Root);
            if (t.ApiProfile.Length > 0) { var p = profiles.Get(t.ApiProfile); return new ChatClient(p, profiles.Key(p)); }
            var s = SettingsStore.Load(); return new ChatClient(new ServiceProfile(ServiceProfile.Normalize(s.TranslationBase), s.TranslationModel), SettingsStore.Reveal(s.TranslationSecret));
        });
        asr.Notice += message => Event?.Invoke(new JsonObject { ["type"] = "error", ["message"] = message });
        translator.Notice += message => Event?.Invoke(new JsonObject { ["type"] = "translator", ["state"] = "loading", ["detail"] = message });
        Channel = new(Core); receiver = Task.Run(ReceiveAsync);
    }
    public static JsonObject Command(string command, string? session = null) => new() { ["protocol_version"] = 1, ["request_id"] = Guid.NewGuid().ToString("N"), ["command"] = command, ["session_id"] = session ?? "" };
    public async Task ApplyAsync(AppSettings settings, bool download = false, string role = "asr", CancellationToken ct = default)
    {
        if (settings.Mode == "live" && role == "asr") return;
        var command = Command(download ? "download" : "load"); command["role"] = role; command["runtime"] = BackendJson.Object(settings.RuntimeConfig());
        if (role == "asr") { command["config"] = BackendJson.Object(settings.RecognitionConfig()); command["api_key"] = settings.Mode == "api" ? SettingsStore.Reveal(settings.ApiSecret) : ""; }
        else command["translation"] = BackendJson.Object(settings.TranslationConfig() with { Provider = "local" });
        var id = (string)command["request_id"]!; var complete = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); pending[id] = new(role, complete);
        try { await Channel.ControlAsync(command); await complete.Task.WaitAsync(ct); }
        finally { pending.TryRemove(id, out _); }
    }
    public async Task EnsureAsync(AppSettings settings, CancellationToken ct)
    {
        if (Core.State != "ready" || Core.Config != settings.RecognitionConfig() || Core.Runtime != settings.RuntimeConfig()) await ApplyAsync(settings, ct: ct);
        if (settings.Translation && settings.TranslationProvider == "local" && (!Core.TranslationReady || Core.Translation.ModelId != settings.TranslatorModelId)) await ApplyAsync(settings, role: "translator", ct: ct);
        var command = Command("translation_settings"); var t = settings.TranslationConfig();
        command["enabled"] = t.Enabled; command["provider"] = t.Provider; command["api_profile"] = t.ApiProfile; command["target_language"] = t.TargetLanguage; await Channel.ControlAsync(command);
    }
    public void Register(string session, Action<JsonObject> handler) => sessions[session] = handler;
    public void ClearHistory() => sessions.Clear();
    private async Task ReceiveAsync()
    {
        await foreach (var message in Core.Events.ReadAllAsync())
        {
            string type = (string)message["type"]!, id = (string?)message["request_id"] ?? "";
            if (pending.TryGetValue(id, out var waiter))
            {
                if (type == "config") waiter.Configured = true;
                if (type == "error" || type == "translator" && (string?)message["state"] == "error") waiter.Completion.TrySetException(new InvalidOperationException((string?)message["message"] ?? (string?)message["detail"] ?? "模型操作失败。"));
                else if (type == (waiter.Role == "asr" ? "status" : "translator") && (string?)message["state"] == "ready" && (waiter.Role != "asr" || waiter.Configured)) waiter.Completion.TrySetResult();
            }
            if ((string?)message["session_id"] is string session && sessions.TryGetValue(session, out var handler)) handler(message);
            Event?.Invoke(message);
        }
        foreach (var waiter in pending.Values) waiter.Completion.TrySetException(new IOException("后端已关闭。"));
    }
    public async ValueTask DisposeAsync() { await Channel.DisposeAsync(); await receiver; Models.Dispose(); }
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
