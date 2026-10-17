using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using Recorder.Native;

namespace Recorder.Backend;

public sealed record EngineModel(string Engine, string Path, string Projector = "", string Device = "auto");
public interface IAsrEngine : IAsyncDisposable
{
    bool IsLoaded { get; }
    Task LoadAsync(EngineModel model, string language, CancellationToken ct);
    Task WarmupAsync(CancellationToken ct);
    Task<string> TranscribeAsync(ReadOnlyMemory<byte> pcm, CancellationToken ct);
    Task UnloadAsync();
    /// <summary>Changes the recognition language hint of the loaded model without reloading it.</summary>
    void SetLanguage(string language) { }
}
public interface ITranslatorEngine : IAsyncDisposable
{
    bool IsLoaded { get; }
    Task LoadAsync(EngineModel model, CancellationToken ct);
    Task WarmupAsync(CancellationToken ct);
    IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatMessage> messages, int maxTokens, CancellationToken ct);
    Task UnloadAsync();
}
public sealed record ChatMessage(string Role, string Content);

/// <param name="dllDirectories">Extra DLL directories per device; returning null means the device's libraries are not installed.</param>
public sealed class NativeEngine(string runtimeRoot, Func<string, IReadOnlyList<string>?>? dllDirectories = null) : IAsrEngine, ITranslatorEngine
{
    private NativeClient? client;
    private volatile string language = "auto";
    private EngineModel? model;
    public bool IsLoaded => client?.IsAlive == true;
    public string ActiveDevice { get; private set; } = "";
    public long PrivateBytes => client?.PrivateBytes ?? 0;
    public event Action<string>? Notice;
    public event Action<string>? Failed;
    public int? ProcessId => client?.ProcessId;
    public async Task LoadAsync(EngineModel next, string language, CancellationToken ct) { this.language = language; await LoadAsync(next, ct); }
    public void SetLanguage(string language) => this.language = language;
    public async Task LoadAsync(EngineModel next, CancellationToken ct)
    {
        await UnloadAsync();
        var devices = next.Device == "auto" ? new[] { "cuda", "cpu" } : new[] { next.Device };
        foreach (var device in devices)
        {
            NativeClient? candidate = null;
            var directories = dllDirectories == null ? [] : dllDirectories(device);
            if (directories == null)
            {
                if (next.Device == "auto") continue;
                throw new InvalidOperationException("尚未安装 GPU 加速组件。请在 设置 → 识别 → 运行设备 中下载，或改用 CPU / 自动。");
            }
            try
            {
                candidate = await NativeClient.StartAsync(Path.Combine(runtimeRoot, device, "recorder-native.exe"), ct, directories);
                var current = candidate; current.UnexpectedExit += () =>
                {
                    LogExit(current, next.Engine + " on " + device);
                    if (ReferenceEquals(client, current)) Failed?.Invoke($"本地推理进程异常退出（{current.ExitDescription}），请重新加载模型；已有文字已保留。");
                };
                await candidate.CallAsync("load", new JsonObject { ["path"] = next.Path, ["projector"] = next.Projector, ["engine"] = next.Engine, ["device"] = device }, ct: ct);
                client = candidate; model = next; ActiveDevice = device; return;
            }
            catch (Exception ex) when (device == "cuda" && next.Device == "auto" && !ct.IsCancellationRequested)
            { if (candidate != null) await candidate.DisposeAsync(); Notice?.Invoke("CUDA 无法使用，已释放资源并尝试 CPU：" + ex.Message); }
            catch { if (candidate != null) await candidate.DisposeAsync(); throw; }
        }
        throw new InvalidOperationException("没有可用的本地推理设备。");
    }
    private readonly System.Runtime.CompilerServices.ConditionalWeakTable<NativeClient, object> exitsLogged = new();
    private void LogExit(NativeClient current, string what)
    {
        if (exitsLogged.TryAdd(current, new())) DiagnosticLog.Write("native-exit", $"{what}: {current.ExitDescription}\n{current.ErrorTail}");
    }
    /// <summary>Every worker call goes through here so a dead worker is logged once with its exit code and stderr tail.</summary>
    private async Task<JsonObject> CallAsync(NativeClient current, string command, JsonObject? parameters = null, ReadOnlyMemory<byte> pcm = default, CancellationToken ct = default)
    {
        try { return await current.CallAsync(command, parameters, pcm, ct); }
        catch (IOException) when (!current.IsAlive) { LogExit(current, (model?.Engine ?? "worker") + " " + command); throw; }
    }
    public async Task WarmupAsync(CancellationToken ct)
    {
        var selected = model;
        try { await WarmupCurrentAsync(ct); }
        catch (Exception ex) when (selected?.Device == "auto" && ActiveDevice == "cuda" && !ct.IsCancellationRequested)
        {
            await UnloadAsync(); Notice?.Invoke("CUDA 预热或内存分配失败，已释放资源并尝试 CPU：" + ex.Message);
            await LoadAsync(selected with { Device = "cpu" }, ct); await WarmupCurrentAsync(ct);
        }
    }
    private async Task WarmupCurrentAsync(CancellationToken ct)
    {
        if (model == null || client == null) throw new InvalidOperationException("模型尚未加载。");
        if (model.Engine is "qwen" or "whisper") await TranscribeAsync(new byte[16000], ct);
        else
        {
            await CallAsync(client, "begin", new JsonObject { ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "Translate to English: 你好" }), ["max_tokens"] = 1 }, ct: ct);
            try { await CallAsync(client, "next", ct: ct); } finally { await CallAsync(client, "end"); }
        }
    }
    public async Task<string> TranscribeAsync(ReadOnlyMemory<byte> pcm, CancellationToken ct)
    {
        if (client == null) throw new InvalidOperationException("识别模型尚未加载。");
        var hint = model?.Engine == "whisper" ? language switch { "Chinese" => "zh", "English" => "en", "Cantonese" => "zh", "Japanese" => "ja", "Korean" => "ko", _ => "auto" } : language;
        return ((string?)(await CallAsync(client, "asr", new JsonObject { ["language"] = hint }, pcm, ct))["text"] ?? "").Trim();
    }
    public async IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatMessage> messages, int maxTokens, [EnumeratorCancellation] CancellationToken ct)
    {
        if (client == null) throw new InvalidOperationException("翻译模型尚未加载。");
        var current = client;
        var array = new JsonArray(messages.Select(m => (JsonNode)new JsonObject { ["role"] = m.Role, ["content"] = m.Content }).ToArray());
        // Byte-level tokens can split characters or stop mid-sequence at max_tokens; replace instead of throwing.
        var decoder = new UTF8Encoding(false, false).GetDecoder();
        try
        {
            await CallAsync(current, "begin", new JsonObject { ["messages"] = array, ["max_tokens"] = maxTokens }, ct: ct);
            for (;;)
            {
                var result = await CallAsync(current, "next", ct: ct); var done = (bool)result["done"]!;
                var bytes = result["token_bytes"]!.AsArray().Select(n => (byte)n!.GetValue<int>()).ToArray();
                var chars = new char[bytes.Length + 4]; int n = decoder.GetChars(bytes, chars, done);
                if (n > 0) yield return new string(chars, 0, n);
                if (done) break;
            }
        }
        finally { try { await current.CallAsync("end"); } catch when (ct.IsCancellationRequested || client != current || !current.IsAlive) { } }
    }
    public async Task UnloadAsync() { var current = client; client = null; model = null; ActiveDevice = ""; if (current != null) await current.DisposeAsync(); }
    public async ValueTask DisposeAsync() => await UnloadAsync();
}
