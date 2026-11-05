using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Recorder.Backend;

public static class BackendJson
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, RespectNullableAnnotations = true, WriteIndented = true };
    public static JsonObject Object<T>(T value) => JsonSerializer.SerializeToNode(value, Options)!.AsObject();
    public static T Parse<T>(JsonObject value) where T : IValidated => Validate(value.Deserialize<T>(Options) ?? throw new InvalidDataException("配置为空。"));
    public static T Validate<T>(T value) where T : IValidated { value.Validate(); return value; }
    public static long Integer(JsonNode? value) => value?.GetValueKind() == JsonValueKind.Number &&
        long.TryParse(value.ToJsonString(), System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out var number)
        ? number : throw new InvalidDataException("字段必须为整数。");
}
public interface IValidated { void Validate(); }
public static class Languages
{
    public static readonly string[] Targets = ["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский"];
    public static readonly string[] Recognition = ["auto", "Chinese", "English", "Cantonese", "Japanese", "Korean"];
    public static string Target(string value) => value switch { "zh" => Targets[0], "zh-TW" => Targets[1], "en" => Targets[2], "ja" => Targets[3], "ko" => Targets[4], "fr" => Targets[5], "de" => Targets[6], "es" => Targets[7], "ru" => Targets[8], _ => value };
    public static string RecognitionName(string value) => value switch { "zh" => "Chinese", "en" => "English", "yue" => "Cantonese", "ja" => "Japanese", "ko" => "Korean", _ => value };
}
public sealed record ModelConfig : IValidated
{
    public int SchemaVersion { get; init; } = 1;
    public string ModelId { get; init; } = "ggml-org/Qwen3-ASR-1.7B-GGUF";
    public string LocalModelPath { get; init; } = "";
    public string Revision { get; init; } = "";
    public string Language { get; init; } = "auto";
    public int PreviewIntervalMs { get; init; } = 1200;
    public string EndpointMode { get; init; } = "smart";
    public int EndpointSilenceMs { get; init; } = 1000;
    public int MaxSegmentSeconds { get; init; } = 18;
    public string Provider { get; init; } = "local";
    public string ApiBaseUrl { get; init; } = "";
    public string ApiModel { get; init; } = "";
    public string ApiProtocol { get; init; } = "openai";
    public void Validate()
    {
        if (SchemaVersion != 1) throw new InvalidDataException("不支持的识别配置版本。");
        if (!Languages.Recognition.Contains(Language)) throw new InvalidDataException("不支持的识别语言。");
        if (PreviewIntervalMs is < 800 or > 10000 || EndpointSilenceMs is < 300 or > 2000 || MaxSegmentSeconds is < 5 or > 25) throw new InvalidDataException("识别参数超出允许范围。");
        if (EndpointMode is not ("smart" or "fixed") || Provider is not ("local" or "api") || ApiProtocol is not ("openai" or "qwen_realtime")) throw new InvalidDataException("不支持的识别模式。");
        if (Provider == "local" && LocalModelPath.Length == 0) ModelAddress.ValidateId(ModelId);
        if (Provider == "api" && ApiProtocol == "openai") { ServiceAddress.Endpoint(ApiBaseUrl, "/audio/transcriptions"); if (string.IsNullOrWhiteSpace(ApiModel) || ApiModel.Any(char.IsControl)) throw new InvalidDataException("请填写有效的音频转写模型名称。"); }
    }
}
public sealed record TranslationConfig : IValidated
{
    public int SchemaVersion { get; init; } = 1;
    public bool Enabled { get; init; }
    public string Provider { get; init; } = "local";
    public string ApiProfile { get; init; } = "";
    public string TargetLanguage { get; init; } = "简体中文";
    public string ModelId { get; init; } = "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF";
    public string Revision { get; init; } = "";
    public void Validate()
    {
        if (SchemaVersion != 1 || Provider is not ("local" or "api") || !Languages.Targets.Contains(TargetLanguage)) throw new InvalidDataException("翻译配置版本、服务或目标语言无效。");
        ModelAddress.ValidateId(ModelId);
    }
}
public sealed record RuntimeConfig : IValidated
{
    public string Device { get; init; } = "auto";
    public string TranslatorDevice { get; init; } = "auto";
    public string AsrEngine { get; init; } = "qwen";
    public string AsrProjectorPath { get; init; } = "";
    public string TranslatorEngine { get; init; } = "qwen3";
    public string TranslatorPath { get; init; } = "";
    public string AsrFilename { get; init; } = "";
    public string AsrProjectorFilename { get; init; } = "";
    public string TranslatorFilename { get; init; } = "";
    public void Validate()
    {
        if (Device is not ("auto" or "cpu" or "cuda") || TranslatorDevice is not ("auto" or "cpu" or "cuda") || AsrEngine is not ("qwen" or "whisper") || TranslatorEngine is not ("qwen2" or "qwen3" or "hunyuan" or "llama" or "mistral")) throw new InvalidDataException("不支持的运行设备或模型架构。");
    }
}
public static class ModelAddress
{
    public static void ValidateId(string id) { if (!System.Text.RegularExpressions.Regex.IsMatch(id, @"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$") || id.Split('/').Any(p => p is "." or "..")) throw new InvalidDataException("请输入 owner/model 格式的模型 ID。"); }
}
public static class ServiceAddress
{
    public static Uri Endpoint(string baseUrl, string suffix)
    {
        if (!Uri.TryCreate(baseUrl.TrimEnd('/') + suffix, UriKind.Absolute, out var uri) ||
            !(uri.Scheme == "https" || uri.Scheme == "http" && uri.IsLoopback) || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            throw new InvalidDataException("服务地址须使用 HTTPS；本机服务可使用 HTTP，地址不能附带密钥、参数或片段。");
        return uri;
    }
}
public sealed class ConfigStore(string root)
{
    public string Root { get; } = Path.GetFullPath(root);
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shengjian-x64");
    public T Load<T>(string name, T defaults) where T : IValidated
    {
        var path = Path.Combine(Root, name);
        return File.Exists(path) ? BackendJson.Parse<T>(JsonNode.Parse(File.ReadAllText(path))?.AsObject() ?? throw new InvalidDataException("配置文件为空。")) : defaults;
    }
    public void Save<T>(string name, T value) where T : IValidated
    {
        SaveBundle((name, value));
    }
    public void SaveSelection(ModelConfig value, RuntimeConfig runtime) => SaveBundle(("runtime.json", runtime), ("config.json", value));
    public void SaveSelection(TranslationConfig value, RuntimeConfig runtime) => SaveBundle(("runtime.json", runtime), ("translation.json", value));
    private void SaveBundle(params (string Name, IValidated Value)[] values)
    {
        foreach (var value in values) { value.Value.Validate(); if (Path.GetFileName(value.Name) != value.Name) throw new InvalidDataException("配置文件名无效。"); }
        Directory.CreateDirectory(Root);
        var files = values.Select(value => (Path: Path.Combine(Root, value.Name), Temp: Path.Combine(Root, value.Name + "." + Guid.NewGuid().ToString("N") + ".tmp"), value.Value)).ToArray();
        var previous = files.Select(file => File.Exists(file.Path) ? File.ReadAllBytes(file.Path) : null).ToArray();
        int committed = 0;
        try
        {
            foreach (var file in files)
            {
                using var stream = new FileStream(file.Temp, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                JsonSerializer.Serialize(stream, file.Value, file.Value.GetType(), BackendJson.Options); stream.Flush(true);
            }
            foreach (var file in files) { File.Move(file.Temp, file.Path, true); committed++; }
        }
        catch
        {
            for (int i = committed - 1; i >= 0; --i)
            {
                if (previous[i] is byte[] data) { File.WriteAllBytes(files[i].Temp, data); File.Move(files[i].Temp, files[i].Path, true); }
                else File.Delete(files[i].Path);
            }
            throw;
        }
        finally { foreach (var file in files) if (File.Exists(file.Temp)) File.Delete(file.Temp); }
    }
    public void MigrateLegacy(string legacyRoot)
    {
        if (Directory.Exists(Root) && Directory.EnumerateFileSystemEntries(Root).Any()) return;
        var path = Path.Combine(legacyRoot, "settings.json"); if (!File.Exists(path)) return;
        var old = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        string S(string key, string fallback = "") => (string?)old[key] ?? fallback;
        string mode = S("Mode", "local");
        var config = new ModelConfig { Provider = mode == "local" ? "local" : "api", ModelId = "ggerganov/whisper.cpp",
            LocalModelPath = S("ModelPath"), Language = Languages.RecognitionName(S("Language", "auto")), EndpointMode = "fixed",
            EndpointSilenceMs = Math.Clamp((int?)old["SilenceMs"] ?? 1000, 300, 2000), ApiBaseUrl = S("ApiBase", "https://api.openai.com/v1"),
            ApiModel = S("ApiModel", "whisper-1"), ApiProtocol = mode == "stream" ? "qwen_realtime" : "openai" };
        var translation = new TranslationConfig { Enabled = (bool?)old["Translation"] ?? false, Provider = "api", ApiProfile = S("TranslationBase"), TargetLanguage = Languages.Target(S("TargetLanguage", "zh")) };
        config.Validate(); translation.Validate();
        // Stage all files in a sibling directory, then atomically publish the migrated directory.
        var staging = Root + ".migrate-" + Guid.NewGuid().ToString("N"); var staged = new ConfigStore(staging);
        try
        {
            staged.Save("config.json", config); staged.Save("translation.json", translation); staged.Save("runtime.json", new RuntimeConfig { AsrEngine = "whisper" });
            var secrets = new JsonObject(); foreach (var key in new[] { "ApiSecret", "StreamingSecret", "TranslationSecret", "LiveSecret" }) if (old[key] is JsonNode value) secrets[key] = value.DeepClone();
            File.WriteAllText(Path.Combine(staging, "legacy-secrets.json"), secrets.ToJsonString());
            File.WriteAllText(Path.Combine(staging, "legacy-ui.json"), old.ToJsonString());
            if (Directory.Exists(Root)) Directory.Delete(Root); Directory.Move(staging, Root);
        }
        finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
    }
}
public static class SecretStore
{
    public static string Protect(string value) => string.IsNullOrEmpty(value) ? "" : Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
    public static string Reveal(string value) => string.IsNullOrEmpty(value) ? "" : Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser));
}
