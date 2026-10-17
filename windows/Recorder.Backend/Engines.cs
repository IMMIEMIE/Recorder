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

public sealed class NativeEngine(string runtimeRoot) : IAsrEngine, ITranslatorEngine
{
    private NativeClient? client;
    private string language = "auto";
    private EngineModel? model;
    public bool IsLoaded => client != null;
    public string ActiveDevice { get; private set; } = "";
    public event Action<string>? Notice;
    public async Task LoadAsync(EngineModel next, string language, CancellationToken ct) { this.language = language; await LoadAsync(next, ct); }
    public async Task LoadAsync(EngineModel next, CancellationToken ct)
    {
        await UnloadAsync();
        var devices = next.Device == "auto" ? new[] { "cuda", "cpu" } : new[] { next.Device };
        foreach (var device in devices)
        {
            NativeClient? candidate = null;
            try
            {
                candidate = await NativeClient.StartAsync(Path.Combine(runtimeRoot, device, "recorder-native.exe"), ct);
                await candidate.CallAsync("load", new JsonObject { ["path"] = next.Path, ["projector"] = next.Projector, ["engine"] = next.Engine, ["device"] = device }, ct: ct);
                client = candidate; model = next; ActiveDevice = device; return;
            }
            catch (Exception ex) when (device == "cuda" && next.Device == "auto" && !ct.IsCancellationRequested)
            { if (candidate != null) await candidate.DisposeAsync(); Notice?.Invoke("CUDA 无法使用，已释放资源并尝试 CPU：" + ex.Message); }
            catch { if (candidate != null) await candidate.DisposeAsync(); throw; }
        }
        throw new InvalidOperationException("没有可用的本地推理设备。");
    }
    public async Task WarmupAsync(CancellationToken ct)
    {
        if (model == null || client == null) throw new InvalidOperationException("模型尚未加载。");
        if (model.Engine is "qwen" or "whisper") await TranscribeAsync(new byte[16000], ct);
        else
        {
            await client.CallAsync("begin", new JsonObject { ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "Translate to English: 你好" }), ["max_tokens"] = 1 }, ct: ct);
            try { await client.CallAsync("next", ct: ct); } finally { await client.CallAsync("end"); }
        }
    }
    public async Task<string> TranscribeAsync(ReadOnlyMemory<byte> pcm, CancellationToken ct)
    {
        if (client == null) throw new InvalidOperationException("识别模型尚未加载。");
        var hint = model?.Engine == "whisper" ? language switch { "Chinese" => "zh", "English" => "en", "Cantonese" => "zh", "Japanese" => "ja", "Korean" => "ko", _ => "auto" } : language;
        return ((string?)(await client.CallAsync("asr", new JsonObject { ["language"] = hint }, pcm, ct))["text"] ?? "").Trim();
    }
    public async IAsyncEnumerable<string> StreamAsync(IReadOnlyList<ChatMessage> messages, int maxTokens, [EnumeratorCancellation] CancellationToken ct)
    {
        if (client == null) throw new InvalidOperationException("翻译模型尚未加载。");
        var current = client;
        var array = new JsonArray(messages.Select(m => (JsonNode)new JsonObject { ["role"] = m.Role, ["content"] = m.Content }).ToArray());
        var decoder = new UTF8Encoding(false, true).GetDecoder();
        try
        {
            await current.CallAsync("begin", new JsonObject { ["messages"] = array, ["max_tokens"] = maxTokens }, ct: ct);
            for (;;)
            {
                var result = await current.CallAsync("next", ct: ct); var done = (bool)result["done"]!;
                var bytes = result["token_bytes"]!.AsArray().Select(n => (byte)n!.GetValue<int>()).ToArray();
                var chars = new char[bytes.Length + 4]; int n = decoder.GetChars(bytes, chars, done);
                if (n > 0) yield return new string(chars, 0, n);
                if (done) break;
            }
        }
        finally { try { await current.CallAsync("end"); } catch when (ct.IsCancellationRequested || client != current) { } }
    }
    public async Task UnloadAsync() { var current = client; client = null; model = null; ActiveDevice = ""; if (current != null) await current.DisposeAsync(); }
    public async ValueTask DisposeAsync() => await UnloadAsync();
}
