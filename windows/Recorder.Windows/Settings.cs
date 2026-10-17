using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Recorder.Windows;

public sealed partial record AppSettings
{
    public string Mode { get; set; } = "local";
    public string Language { get; set; } = "auto";
    public int SilenceMs { get; set; } = 1000;
#if FULL_BACKEND
    public string ModelPath { get; set; } = FullSettingsStore.DefaultModelPath;
#else
    public string ModelPath { get; set; } = Path.Combine(SettingsStore.Root, "models", "ggml-tiny.bin");
#endif
    public string ApiBase { get; set; } = "https://api.openai.com/v1";
    public string ApiModel { get; set; } = "whisper-1";
    public string ApiSecret { get; set; } = "";
    public string StreamingSecret { get; set; } = "";
    public bool Translation { get; set; }
    public string TranslationBase { get; set; } = "https://api.openai.com/v1";
    public string TranslationModel { get; set; } = "gpt-4o-mini";
    public string TranslationSecret { get; set; } = "";
    public string TargetLanguage { get; set; } = "zh";
    public string LiveEndpoint { get; set; } = "wss://maas.qianwenaiapi.com/api-ws/v1/realtime";
    public string LiveSecret { get; set; } = "";
}

public static class SettingsStore
{
#if FULL_BACKEND
    public static string Root => FullSettingsStore.Root;
    public static AppSettings Load() => FullSettingsStore.Load();
    public static void Save(AppSettings settings) => FullSettingsStore.Save(settings);
#else
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Shengjian");
    public static AppSettings Load()
    {
        var path = Path.Combine(Root, "settings.json");
        if (!File.Exists(path)) return new();
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new(); }
        catch (Exception ex) { throw new InvalidDataException("设置文件损坏，请重命名后重试：" + path, ex); }
    }
    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Root);
        var path = Path.Combine(Root, "settings.json");
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(path + ".tmp", path, true);
    }
#endif
    public static string Protect(string value) => string.IsNullOrEmpty(value) ? "" : Convert.ToBase64String(
        ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
    public static string Reveal(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser)); }
        catch { throw new InvalidOperationException("无法解密 API Key，请在设置中重新填写并保存。"); }
    }
}

public sealed record TranscriptRow(string Id, double Seconds, string Text, string Translation = "", bool Final = true, string AudioId = "");

public static class TranscriptExport
{
    public static string Text(IEnumerable<TranscriptRow> rows) => string.Join(Environment.NewLine + Environment.NewLine,
        rows.Select(r => $"[{TimeSpan.FromSeconds(r.Seconds):hh\\:mm\\:ss}] {r.Text}" +
            (string.IsNullOrWhiteSpace(r.Translation) ? "" : Environment.NewLine + r.Translation)));
    public static string Srt(IReadOnlyList<TranscriptRow> rows) => string.Join(Environment.NewLine + Environment.NewLine,
        rows.Select((r, i) => $"{i + 1}\r\n{Stamp(r.Seconds)} --> {Stamp(i + 1 < rows.Count ? Math.Max(r.Seconds + .1, rows[i + 1].Seconds) : r.Seconds + 5)}\r\n{r.Text}" +
            (string.IsNullOrWhiteSpace(r.Translation) ? "" : "\r\n" + r.Translation)));
    private static string Stamp(double s) => TimeSpan.FromSeconds(s).ToString(@"hh\:mm\:ss\,fff");
}
