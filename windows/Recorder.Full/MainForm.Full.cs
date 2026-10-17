namespace Recorder.Windows;
internal sealed partial class MainForm
{
    private void InitializeFullBackend(Button ai, FlowLayoutPanel toolbar)
    {
        clear.Click += (_, _) => DesktopBackend.Shared.ClearHistory();
        DesktopBackend.Shared.Event += FullBackendEvent;
        FormClosed += (_, _) => DesktopBackend.Shared.Event -= FullBackendEvent;
        if (FullSettingsStore.StartupError != null) status.Text = FullSettingsStore.StartupError;
    }
    private void FullBackendEvent(System.Text.Json.Nodes.JsonObject message)
    {
        if ((string?)message["type"] == "error") UI(() => status.Text = (string?)message["message"] ?? "后端发生错误。");
    }
    private void UpdateFullHint()
    {
        if (settings.Mode == "local") mode.Text = (settings.AsrEngine == "qwen" ? "Qwen3-ASR" : "Whisper") + " · " + settings.Device;
        if (settings.Mode != "live" && settings.Translation) translationSummary.Text = (settings.TranslationProvider == "local" ? "本地模型" : "API") + " → " + Recorder.Backend.Languages.Target(settings.TargetLanguage);
    }
}
