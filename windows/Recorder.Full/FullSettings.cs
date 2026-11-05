using System.Text.Json;
using Recorder.Backend;
namespace Recorder.Windows;

public sealed partial record AppSettings
{
    public string AsrModelId { get; set; } = "ggml-org/Qwen3-ASR-1.7B-GGUF";
    public string AsrRevision { get; set; } = "";
    public string AsrEngine { get; set; } = "qwen";
    public string AsrProjector { get; set; } = "";
    public string AsrFilename { get; set; } = "";
    public string AsrProjectorFilename { get; set; } = "";
    public bool UseLocalFile { get; set; }
    public string Device { get; set; } = "auto";
    public string EndpointMode { get; set; } = "smart";
    public int PreviewMs { get; set; } = 1200;
    public int MaxSegmentSeconds { get; set; } = 18;
    public string TranslationProvider { get; set; } = "local";
    public string TranslatorModelId { get; set; } = "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF";
    public string TranslatorRevision { get; set; } = "";
    public string TranslatorPath { get; set; } = "";
    public string TranslatorEngine { get; set; } = "qwen3";
    public string TranslatorFilename { get; set; } = "";
    public string ApiProfileId { get; set; } = "";
    public string AiProfileId { get; set; } = "";
    public bool LiveAudioOutput { get; set; }
    public float LiveVolume { get; set; } = .8f;
    public string LiveTiming { get; set; } = "streaming";
    public int SubtitleFontSize { get; set; } = 20;
    public bool SubtitleTranslation { get; set; } = true;
    public double SubtitleOpacity { get; set; } = 1;
    public int InputSource { get; set; }
    public string MicrophoneName { get; set; } = "";
    public int MainWidth { get; set; } = 1040;
    public int MainHeight { get; set; } = 700;
    public bool MainTopMost { get; set; }
    public ModelConfig RecognitionConfig() => new() { ModelId = AsrModelId, Revision = AsrRevision, LocalModelPath = UseLocalFile ? ModelPath : "", Language = Languages.RecognitionName(Language),
        Provider = Mode == "local" ? "local" : "api", ApiProtocol = Mode == "stream" ? "qwen_realtime" : "openai", ApiBaseUrl = ApiBase, ApiModel = ApiModel,
        EndpointMode = EndpointMode, EndpointSilenceMs = SilenceMs, PreviewIntervalMs = PreviewMs, MaxSegmentSeconds = MaxSegmentSeconds };
    public TranslationConfig TranslationConfig() => new() { ModelId = TranslatorModelId, Revision = TranslatorRevision, Enabled = Translation, Provider = TranslationProvider, TargetLanguage = Languages.Target(TargetLanguage), ApiProfile = ApiProfileId };
    public RuntimeConfig RuntimeConfig() => new() { Device = Device, TranslatorDevice = Device, AsrEngine = AsrEngine, AsrProjectorPath = AsrProjector, AsrFilename = AsrFilename, AsrProjectorFilename = AsrProjectorFilename,
        TranslatorEngine = TranslatorEngine, TranslatorPath = TranslatorPath, TranslatorFilename = TranslatorFilename };
}
internal static class FullSettingsStore
{
    public static string Root => Environment.GetEnvironmentVariable("SHENGJIAN_DATA_ROOT") is string value ? Path.GetFullPath(value) : ConfigStore.DefaultRoot;
    public static string DefaultModelPath => Path.Combine(Root, "models/models--ggml-org--Qwen3-ASR-1.7B-GGUF/snapshots/36a678687ba7d07a74ca70ccb0e36902e005fb80/Qwen3-ASR-1.7B-bf16.gguf");
    public static string? StartupError;
    public static AppSettings Load()
    {
        var store = new ConfigStore(Root);
        if (Environment.GetEnvironmentVariable("SHENGJIAN_DATA_ROOT") == null) store.MigrateLegacy(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shengjian"));
        var ui = Path.Combine(Root, "settings.json"); var legacy = Path.Combine(Root, "legacy-ui.json");
        AppSettings settings = new();
        try { settings = File.Exists(ui) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(ui)) ?? new() : File.Exists(legacy) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(legacy)) ?? new() : new(); }
        catch (Exception ex) { StartupError = "界面设置未加载：" + ex.Message; }
        try
        {
            var config = store.Load("config.json", settings.RecognitionConfig()); var translation = store.Load("translation.json", settings.TranslationConfig()); var runtime = store.Load("runtime.json", settings.RuntimeConfig());
            settings.AsrModelId = config.ModelId; settings.AsrRevision = config.Revision; settings.UseLocalFile = config.LocalModelPath.Length > 0; settings.Language = config.Language;
            if (settings.Mode != "live") settings.Mode = config.Provider == "local" ? "local" : config.ApiProtocol == "qwen_realtime" ? "stream" : "api";
            settings.ApiBase = config.ApiBaseUrl.Length > 0 ? config.ApiBaseUrl : settings.ApiBase; settings.ApiModel = config.ApiModel.Length > 0 ? config.ApiModel : settings.ApiModel;
            settings.SilenceMs = config.EndpointSilenceMs; settings.EndpointMode = config.EndpointMode; settings.PreviewMs = config.PreviewIntervalMs; settings.MaxSegmentSeconds = config.MaxSegmentSeconds;
            settings.Device = runtime.Device; settings.AsrEngine = runtime.AsrEngine; settings.AsrProjector = runtime.AsrProjectorPath;
            settings.AsrFilename = runtime.AsrFilename; settings.AsrProjectorFilename = runtime.AsrProjectorFilename; settings.TranslatorFilename = runtime.TranslatorFilename;
            settings.TranslatorPath = runtime.TranslatorPath; settings.TranslatorEngine = runtime.TranslatorEngine;
            settings.Translation = translation.Enabled; settings.TranslationProvider = translation.Provider; settings.TargetLanguage = TargetCode(translation.TargetLanguage);
            if (settings.Mode == "live" && settings.TargetLanguage == "zh-TW") settings.TargetLanguage = "zh";
            settings.TranslatorModelId = translation.ModelId; settings.TranslatorRevision = translation.Revision; settings.ApiProfileId = translation.ApiProfile;
            string profileMigration = Path.Combine(Root, "profiles/.legacy-migrated");
            if (translation.Provider == "api" && settings.TranslationSecret.Length > 0 && !File.Exists(profileMigration))
            {
                var profiles = new ProfileStore(Root); var legacyProfile = new ServiceProfile(ServiceProfile.Normalize(settings.TranslationBase), settings.TranslationModel);
                if (!profiles.Load().Any(p => p.Id == legacyProfile.Id)) profiles.Save(legacyProfile, SettingsStore.Reveal(settings.TranslationSecret));
                File.WriteAllText(profileMigration, "1");
            }
            if (settings.UseLocalFile) settings.ModelPath = config.LocalModelPath;
            else
            {
                using var manager = new ModelManager(Root); var preset = manager.Presets.FirstOrDefault(p => p.Repo == config.ModelId && p.Role == "asr" && (runtime.AsrFilename.Length == 0 || p.Files[0].Name == runtime.AsrFilename));
                if (preset != null) { settings.AsrEngine = preset.Engine; settings.ModelPath = manager.ExpectedPath(preset with { Revision = config.Revision.Length > 0 ? config.Revision : preset.Revision }); }
                else if (config.Revision.Length > 0 && runtime.AsrFilename.Length > 0) settings.ModelPath = Path.Combine(Root, "models/models--" + config.ModelId.Replace("/", "--"), "snapshots", config.Revision, runtime.AsrFilename);
            }
        }
        catch (Exception ex) { StartupError = "配置未完整加载：" + ex.Message; }
        return settings;
    }
    public static string TargetCode(string target) => target switch { "简体中文" => "zh", "繁體中文" => "zh-TW", "English" => "en", "日本語" => "ja", "한국어" => "ko", "Français" => "fr", "Deutsch" => "de", "Español" => "es", "Русский" => "ru", _ => target };
    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Root); var path = Path.Combine(Root, "settings.json");
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true })); File.Move(path + ".tmp", path, true);
    }
}
