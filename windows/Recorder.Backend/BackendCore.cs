using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace Recorder.Backend;

public sealed record ModelResolution(EngineModel Model, string Revision);
public interface IModelResolver
{
    ModelResolution Resolve(ModelConfig config, RuntimeConfig runtime);
    ModelResolution Resolve(TranslationConfig config, RuntimeConfig runtime);
}
public interface IModelDownloader
{
    Task<ModelResolution> DownloadAsync(string role, string modelId, string revision, RuntimeConfig runtime, IProgress<(string Detail, long Completed, long Total)> progress, CancellationToken ct);
}
public sealed record SegmentJob(string SessionId, int SegmentId, int Revision, long StartSample, long EndSample,
    bool Final, byte[] Pcm, long? LastVoicedSample = null, bool ForcedCut = false);

/// <summary>Control is serialized under a short lock; all engine/network work runs outside it.</summary>
public sealed partial class BackendCore : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly ConfigStore store;
    private readonly IAsrEngine asr;
    private readonly ITranslatorEngine translator;
    private IAsrEngine? api;
    private readonly Func<ModelConfig, string, IAsrEngine>? apiFactory;
    private readonly IModelResolver resolver;
    private readonly IModelDownloader? downloader;
    private readonly Queue<Func<Task>> jobs = new();
    private readonly SemaphoreSlim signal = new(0, 1);
    private readonly Channel<JsonObject> events = Channel.CreateUnbounded<JsonObject>(new() { SingleReader = false, SingleWriter = false });
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task pump;
    private CancellationTokenSource? download;
    private readonly List<Task> downloadTasks = new();
    private CancellationTokenSource? asrSelectionCancellation, translatorSelectionCancellation;
    private bool cancelAsrSelection, cancelTranslatorSelection;
    private string downloadRole = "asr", request = "";
    private bool active, disposed;
    private string state = "idle", translatorState = "idle", session = "";
    private readonly HashSet<int> streamFinals = new();
    private SegmentJob? preview;
    private readonly HashSet<int> finalSegments = new();
    private ModelConfig config;
    private TranslationConfig translation;
    private RuntimeConfig runtime;
    private EngineModel? activeModel;
    public ModelConfig Config { get { lock (gate) return config; } }
    public TranslationConfig Translation { get { lock (gate) return translation; } }
    public RuntimeConfig Runtime { get { lock (gate) return runtime; } }
    public string State { get { lock (gate) return state; } }
    public bool CanSelectAsr { get { lock (gate) return state is "idle" or "ready" or "error" && !active && jobs.Count == 0; } }
    public bool TranslationReady { get { lock (gate) return translator.IsLoaded && translatorState == "ready"; } }
    public string TranslatorState { get { lock (gate) return translatorState; } }
    public string ActiveAsrDevice { get { lock (gate) return asr.IsLoaded ? (asr as NativeEngine)?.ActiveDevice ?? "" : ""; } }
    public ChannelReader<JsonObject> Events => events.Reader;

    public BackendCore(ConfigStore store, IAsrEngine asr, ITranslatorEngine translator, IModelResolver resolver,
        IModelDownloader? downloader = null, Func<ModelConfig, string, IAsrEngine>? apiFactory = null)
    {
        this.store = store; this.asr = asr; this.translator = translator; this.resolver = resolver; this.downloader = downloader; this.apiFactory = apiFactory;
        config = Load("config.json", new ModelConfig()); translation = Load("translation.json", new TranslationConfig()); runtime = Load("runtime.json", new RuntimeConfig());
        pump = Task.Run(PumpAsync);
        if (asr is NativeEngine nativeAsr) nativeAsr.Failed += message => { lock (gate) if (!disposed) { asrFailed = true; preview = null; segmenter = null; pendingAudio.Clear(); vad?.Dispose(); vad = null; if (active) Queue(() => { ClearRecognition(); return Task.CompletedTask; }); else ClearRecognition(); Status("error", message); Error(message); } };
        if (translator is NativeEngine nativeTranslator) nativeTranslator.Failed += message => { lock (gate) if (!disposed) { DropTranslations(); TranslatorStatus("error", message); Error("翻译" + message); } };
    }
    private T Load<T>(string file, T defaults) where T : IValidated
    { try { return store.Load(file, defaults); } catch (Exception ex) { Error("配置未加载：" + ex.Message); return defaults; } }
    private void Emit(string type, JsonObject? fields = null)
    {
        var value = fields ?? new(); value["type"] = type; value["protocol_version"] = 1; value["request_id"] = request;
        if (!value.ContainsKey("session_id") && session.Length > 0) value["session_id"] = session;
        events.Writer.TryWrite(value);
    }
    private void Error(string message) => Emit("error", new() { ["message"] = message });
    private void Status(string value, string detail = "") { state = value; if (value == "ready") active = false; Emit("status", new() { ["state"] = value, ["detail"] = detail, ["device"] = config.Provider == "local" ? (asr as NativeEngine)?.ActiveDevice ?? "" : "" }); }
    private void TranslatorStatus(string value, string detail = "") { translatorState = value; Emit("translator", new() { ["state"] = value, ["detail"] = detail, ["config"] = BackendJson.Object(translation) }); }
    private void Wake() { if (signal.CurrentCount == 0) { try { signal.Release(); } catch (SemaphoreFullException) { } } }
    private void Queue(Func<Task> work) { jobs.Enqueue(work); Wake(); }
    private bool IsStreaming => config.Provider == "api" && config.ApiProtocol == "qwen_realtime";
    public void Control(JsonObject message)
    {
        lock (gate)
        {
            if (disposed) return;
            try
            {
                if ((int?)message["protocol_version"] != 1) throw new InvalidDataException("协议版本不兼容。");
                request = (string?)message["request_id"] ?? "";
                switch ((string?)message["command"])
                {
                    case "hello": Emit("config", new() { ["config"] = BackendJson.Object(config) }); TranslatorStatus(translatorState); Status(state); break;
                    case "load": case "download": HandleLoad(message); break;
                    case "cancel_download": CancelDownload(); break;
                    case "cancel_operation":
                        if (state is "loading" or "warming") { cancelAsrSelection = true; asrSelectionCancellation?.Cancel(); }
                        if (translatorState is "loading" or "warming") { cancelTranslatorSelection = true; translatorSelectionCancellation?.Cancel(); }
                        CancelDownload(); break;
                    case "start": Start(message); break;
                    case "stop": if ((string?)message["session_id"] == session) Finish(); break;
                    case "cancel_session": if ((string?)message["session_id"] == session) CancelSession(); break;
                    case "asr_stream_final": StreamFinal(message); break;
                    case "translation_settings": SetTranslation(message); break;
                    case "suspend":
                        if (state is not ("idle" or "ready" or "error") || active) throw new InvalidOperationException("请先停止当前识别。");
                        Status("loading");
                        Queue(async () => { await CancelTranslationAsync(); await asr.UnloadAsync(); await translator.UnloadAsync(); if (api != null) { await api.DisposeAsync(); api = null; } lock (gate) { activeModel = activeTranslator = null; TranslatorStatus("idle"); Status("idle"); } });
                        break;
                    case "shutdown": lifetime.Cancel(); download?.Cancel(); Wake(); break;
                    default: throw new InvalidDataException("未知控制指令。");
                }
            }
            catch (Exception ex) { Error(ex.Message); }
        }
    }
    private void HandleLoad(JsonObject message)
    {
        string role = (string?)message["role"] ?? "asr";
        if (role is not ("asr" or "translator")) throw new InvalidDataException("未知模型角色。");
        var nextRuntime = message["runtime"] is JsonObject r ? BackendJson.Parse<RuntimeConfig>(r) : runtime;
        if (role == "asr")
        {
            if (state is not ("idle" or "ready" or "error") || active || jobs.Count != 0) throw new InvalidOperationException("请等待当前操作结束再切换识别模型。");
            var next = message["config"] is JsonObject c ? BackendJson.Parse<ModelConfig>(c) : config;
            if ((string?)message["command"] == "download")
            {
                if (next.Provider != "local" || next.LocalModelPath.Length > 0) throw new InvalidOperationException("API 或本地目录无需下载，请使用加载。");
                Download(role, next.ModelId, next.Revision, nextRuntime, resolution => Queue(() => LoadAsrAsync(next with { Revision = resolution.Revision }, nextRuntime, resolution.Model, ""))); return;
            }
            var key = (string?)message["api_key"] ?? "";
            Status("loading"); Queue(() => LoadAsrAsync(next, nextRuntime, null, key));
        }
        else
        {
            if (translatorState is "loading" or "warming" or "downloading") throw new InvalidOperationException("请等待翻译模型操作结束。");
            var next = message["translation"] is JsonObject c ? BackendJson.Parse<TranslationConfig>(c) : translation;
            if (next.Provider != "local") throw new InvalidOperationException("请先选择本地翻译。");
            if ((string?)message["command"] == "download") Download(role, next.ModelId, next.Revision, nextRuntime, resolution => Queue(() => LoadTranslatorAsync(next with { Revision = resolution.Revision }, nextRuntime, resolution.Model)));
            else { TranslatorStatus("loading"); Queue(() => LoadTranslatorAsync(next, nextRuntime)); }
        }
    }
    private void Download(string role, string modelId, string revision, RuntimeConfig options, Action<ModelResolution> complete)
    {
        if (download != null) throw new InvalidOperationException("请等待当前下载结束。");
        if (downloader == null) throw new InvalidOperationException("模型下载组件尚未接入。");
        var token = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); download = token; downloadRole = role;
        if (role == "asr") Status("downloading"); else TranslatorStatus("downloading");
        downloadTasks.RemoveAll(t => t.IsCompleted);
        downloadTasks.Add(Task.Run(async () =>
        {
            try
            {
                var progress = new Progress<(string Detail, long Completed, long Total)>(p => { lock (gate) if (download == token && !token.IsCancellationRequested) Emit("progress", new() { ["role"] = role, ["detail"] = p.Detail, ["completed"] = p.Completed, ["total"] = p.Total }); });
                var result = await downloader.DownloadAsync(role, modelId, revision, options, progress, token.Token);
                lock (gate) { if (download != token || token.IsCancellationRequested) return; download = null; complete(result); }
            }
            catch (Exception ex)
            {
                lock (gate) if (download == token) { download = null; if (role == "asr") Status(activeModel == null ? "idle" : "ready", token.IsCancellationRequested ? "下载已取消。" : "下载失败。"); else TranslatorStatus(translator.IsLoaded ? "ready" : "idle"); if (!token.IsCancellationRequested) Error(ex.Message); }
            }
            finally { token.Dispose(); }
        }));
    }
    private void CancelDownload()
    {
        var current = download; if (current == null) return; download = null; current.Cancel();
        if (downloadRole == "asr") Status(asr.IsLoaded || api != null ? "ready" : "idle", "下载已取消。");
        else TranslatorStatus(translator.IsLoaded ? "ready" : "idle", "下载已取消。");
    }
    private async Task LoadAsrAsync(ModelConfig next, RuntimeConfig nextRuntime, EngineModel? resolved, string key)
    {
        var previousConfig = config; var previousModel = activeModel; var previousRuntime = runtime;
        nextRuntime = previousRuntime with { Device = nextRuntime.Device, AsrEngine = nextRuntime.AsrEngine, AsrProjectorPath = nextRuntime.AsrProjectorPath, AsrFilename = nextRuntime.AsrFilename, AsrProjectorFilename = nextRuntime.AsrProjectorFilename };
        var previousApi = api; IAsrEngine? candidateApi = null;
        CancellationToken ct;
        lock (gate) { asrSelectionCancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); if (cancelAsrSelection) asrSelectionCancellation.Cancel(); ct = asrSelectionCancellation.Token; Status("loading", "正在加载识别服务…"); }
        try
        {
            ct.ThrowIfCancellationRequested();
            if (next.Provider == "api")
            {
                if (next.ApiProtocol == "openai") candidateApi = apiFactory?.Invoke(next, key) ?? throw new InvalidOperationException("HTTP 识别组件尚未接入。");
                await asr.UnloadAsync();
            }
            else
            {
                if (resolved == null) { var result = resolver.Resolve(next, nextRuntime); resolved = result.Model; next = next with { Revision = result.Revision }; }
                await asr.LoadAsync(resolved, next.Language, ct);
                lock (gate) Status("warming", "正在预热识别模型…");
                await asr.WarmupAsync(ct);
            }
            ct.ThrowIfCancellationRequested(); store.SaveSelection(next, nextRuntime);
            if (previousApi != null) { try { await previousApi.DisposeAsync(); } catch { /* Committed selection remains authoritative after cleanup failure. */ } }
            lock (gate) { api = candidateApi; config = next; runtime = nextRuntime; activeModel = next.Provider == "local" ? resolved : null; ClearRecognition(); Emit("config", new() { ["config"] = BackendJson.Object(config) }); Status("ready", "识别服务已就绪。"); MaybeLoadTranslator(); }
        }
        catch (Exception ex)
        {
            if (candidateApi != null) await candidateApi.DisposeAsync();
            await asr.UnloadAsync();
            if (previousConfig.Provider == "local" && previousModel != null && !lifetime.IsCancellationRequested)
            {
                try { await asr.LoadAsync(previousModel, previousConfig.Language, lifetime.Token); await asr.WarmupAsync(lifetime.Token); }
                catch { previousModel = null; }
            }
            lock (gate) { api = previousApi; config = previousConfig; runtime = previousRuntime; activeModel = previousModel; ClearRecognition(); Status(asr.IsLoaded || api != null || previousConfig.Provider == "api" && previousConfig.ApiProtocol == "qwen_realtime" ? "ready" : "error", "切换失败，已保留上一有效配置。"); Error(ex.Message); }
        }
        finally { lock (gate) { asrSelectionCancellation?.Dispose(); asrSelectionCancellation = null; cancelAsrSelection = false; } }
    }
    private void Start(JsonObject message)
    {
        if (state != "ready") throw new InvalidOperationException("识别服务尚未就绪。");
        var id = (string?)message["session_id"] ?? ""; if (id.Length == 0) throw new InvalidDataException("缺少会话标识。");
        var values = BackendJson.Object(config);
        foreach (var name in new[] { "endpoint_mode", "endpoint_silence_ms" }) if (message[name] is JsonNode value) values[name] = value.DeepClone();
        var next = BackendJson.Parse<ModelConfig>(values); store.Save("config.json", next); config = next;
        session = id; streamFinals.Clear(); finalSegments.Clear(); preview = null; ClearRecognition(); StartAudio(); Status("recording");
    }
    private void Finish()
    {
        if (state != "recording") return;
        Status("finalizing", "正在处理最后一段语音…"); FinishAudio(); preview = null;
        var id = session;
        Queue(() => { lock (gate) if (session == id) { FlushTranslation(id); Status(asrFailed ? "error" : "ready"); } return Task.CompletedTask; });
    }
    private void StreamFinal(JsonObject message)
    {
        if (!IsStreaming || state is not ("recording" or "finalizing") || (string?)message["session_id"] != session || session == cancelledSession) return;
        int id = checked((int)BackendJson.Integer(message["segment_id"]));
        long start = BackendJson.Integer(message["start_sample"]);
        if (id < 1 || start < 0) throw new InvalidDataException("流式句子标识或采样位置无效。");
        var text = ((string?)message["text"] ?? "").Trim(); if (text.Length == 0) return;
        if (System.Text.Encoding.UTF8.GetByteCount(text) > 200000) throw new InvalidDataException("流式句子文本过长。");
        if (!streamFinals.Add(id)) return;
        var current = session; int rev = 1;
        Queue(() => { lock (gate) { Emit("final", new() { ["session_id"] = current, ["segment_id"] = id, ["revision"] = rev, ["start_sample"] = start, ["text"] = text, ["forced_cut"] = false }); PlanTranslation(current, id, text, false); } return Task.CompletedTask; });
    }
    private async Task PumpAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                Func<Task>? work = null;
                lock (gate)
                {
                    if (jobs.Count > 0) { work = jobs.Dequeue(); active = true; }
                    else if (HasTranslation) { work = TranslationStepAsync; active = false; }
                    else if (preview is SegmentJob item) { preview = null; work = () => InferAsync(item); active = true; }
                }
                if (work == null) { await signal.WaitAsync(lifetime.Token); continue; }
                try { await work(); } catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { break; }
                catch (Exception ex) { lock (gate) { Error(ex.Message); if (state == "recording") Finish(); } }
                finally { lock (gate) active = false; }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        finally { events.Writer.TryComplete(); }
    }
    // These hooks are completed by the audio/cache and translation stages.
    partial void StartAudio(); partial void FinishAudio(); partial void ClearRecognition();
    partial void PlanTranslation(string sessionId, int segmentId, string text, bool forcedCut);
    partial void FlushTranslation(string sessionId);
    private partial Task InferAsync(SegmentJob item);
    private partial Task LoadTranslatorAsync(TranslationConfig next, RuntimeConfig nextRuntime, EngineModel? resolved = null);
    private partial void SetTranslation(JsonObject message);
    private partial void MaybeLoadTranslator();
    private partial bool HasTranslation { get; }
    private partial Task TranslationStepAsync();
    public async ValueTask DisposeAsync()
    {
        lock (gate) { if (disposed) return; disposed = true; download?.Cancel(); lifetime.Cancel(); Wake(); }
        await pump;
        Task[] downloads; lock (gate) downloads = downloadTasks.ToArray();
        await Task.WhenAll(downloads);
        await CancelTranslationAsync();
        vad?.Dispose();
        recognitionCancellation?.Dispose();
        if (api != null) await api.DisposeAsync(); await asr.DisposeAsync(); await translator.DisposeAsync(); lifetime.Dispose();
    }
}
