namespace Recorder.Windows;
internal sealed partial class MainForm
{
    private Button? fullAi;
    private LivePlayer? replayPlayer;
    private void InitializeFullBackend(Button ai, FlowLayoutPanel toolbar)
    {
        Text = "声笺 · 实时转写 x64"; source.AccessibleName = "音频输入"; device.AccessibleName = "麦克风设备";
        ClientSize = new(Math.Clamp(settings.MainWidth, 816, 2400), Math.Clamp(settings.MainHeight, 609, 1800)); TopMost = settings.MainTopMost;
        source.SelectedIndex = Math.Clamp(settings.InputSource, 0, 2);
        if (device.Items.Contains(settings.MicrophoneName)) device.SelectedItem = settings.MicrophoneName;
        fullAi = ai; ai.Enabled = settings.Mode != "live"; ai.AccessibleDescription = "总结、文本翻译和自定义问题";
        ai.Click += (_, _) => { var text = transcript.SelectionLength > 0 ? transcript.SelectedText : TranscriptExport.Text(rows); using var form = new AIForm(text); form.ShowDialog(this); };
        configure.Click += (_, _) => { settings = SettingsStore.Load(); UpdateHint(); };
        clear.Click += (_, _) => { DesktopBackend.Shared.ClearHistory(); LiveHistory.Cache.Clear(); replayPlayer?.Stop(); };
        var replay = Theme.Button("重播译音 ▾"); toolbar.Controls.Add(replay);
        replay.Click += (_, _) =>
        {
            if (session != null) { status.Text = "请停止当前会话后重播译音。"; return; }
            var menu = new ContextMenuStrip();
            foreach (var row in rows.Where(r => r.AudioId.Length > 0 && LiveHistory.Cache.Contains(r.AudioId)))
            {
                var item = menu.Items.Add(TimeSpan.FromSeconds(row.Seconds).ToString(@"mm\:ss") + "  " + (row.Text.Length > 30 ? row.Text[..30] + "…" : row.Text));
                item.Click += async (_, _) => { try { var pcm = LiveHistory.Cache.Get(row.AudioId); if (pcm == null) return; replayPlayer?.Dispose(); replayPlayer = new(); replayPlayer.Failure += text => UI(() => status.Text = text); replayPlayer.Start(settings.LiveVolume); replayPlayer.Append(pcm); await replayPlayer.FinishAsync(CancellationToken.None); } catch (Exception ex) { status.Text = ex.Message; } };
            }
            if (menu.Items.Count == 0) menu.Items.Add("暂无可重播的译音").Enabled = false;
            menu.Closed += (_, _) => menu.Dispose(); menu.Show(replay, new Point(0, replay.Height));
        };
        DesktopBackend.Shared.Event += FullBackendEvent;
        FormClosed += (_, _) =>
        {
            DesktopBackend.Shared.Event -= FullBackendEvent; replayPlayer?.Dispose(); LiveHistory.Cache.Clear();
            try { SettingsStore.Save(SettingsStore.Load() with { MainWidth = ClientSize.Width, MainHeight = ClientSize.Height, MainTopMost = TopMost, InputSource = source.SelectedIndex, MicrophoneName = device.Text }); } catch { }
        };
        if (FullSettingsStore.StartupError != null) status.Text = FullSettingsStore.StartupError;
    }
    private void ShowFullTranslationMenu()
    {
        var menu = new ContextMenuStrip();
        async Task Change(AppSettings next)
        {
            try { if (next.Mode == "live") SettingsStore.Save(next); else await DesktopBackend.Shared.PreferencesAsync(next); settings = next; UpdateHint(); }
            catch (Exception ex) { status.Text = ex.Message; }
        }
        var enabled = new ToolStripMenuItem("实时翻译") { Checked = settings.Translation, Enabled = session == null && settings.Mode != "live" };
        enabled.Click += async (_, _) => await Change(settings with { Translation = !settings.Translation }); menu.Items.Add(enabled);
        foreach (string language in Recorder.Backend.Languages.Targets)
        {
            var item = new ToolStripMenuItem(language) { Checked = Recorder.Backend.Languages.Target(settings.TargetLanguage) == language, Enabled = session == null && !(settings.Mode == "live" && language == "繁體中文") };
            item.Click += async (_, _) => await Change(settings with { TargetLanguage = FullSettingsStore.TargetCode(language) }); menu.Items.Add(item);
        }
        menu.Items.Add("翻译设置…", null, (_, _) => configure.PerformClick()); menu.Closed += (_, _) => menu.Dispose(); menu.Show(translation, new Point(0, translation.Height));
    }
    private void FullBackendEvent(System.Text.Json.Nodes.JsonObject message)
    {
        if ((string?)message["type"] == "error") UI(() => status.Text = (string?)message["message"] ?? "后端发生错误。");
        if ((string?)message["type"] == "status" && (string?)message["state"] == "ready" && (string?)message["device"] is string device && device.Length > 0) UI(() => { if (settings.Mode == "local") mode.Text = (DesktopBackend.Shared.Core.Runtime.AsrEngine == "qwen" ? "Qwen3-ASR" : "Whisper") + " · " + device.ToUpperInvariant(); });
    }
    private void UpdateFullHint()
    {
        if (fullAi != null) fullAi.Enabled = settings.Mode != "live";
        if (settings.Mode == "local") { var activeDevice = DesktopBackend.Shared.Core.ActiveAsrDevice; mode.Text = (settings.AsrEngine == "qwen" ? "Qwen3-ASR" : "Whisper") + " · " + (activeDevice.Length > 0 ? activeDevice.ToUpperInvariant() : settings.Device == "auto" ? "自动" : settings.Device.ToUpperInvariant()); }
        if (settings.Mode != "live" && settings.Translation) translationSummary.Text = (settings.TranslationProvider == "local" ? "本地模型" : "API") + " → " + Recorder.Backend.Languages.Target(settings.TargetLanguage);
    }
}
