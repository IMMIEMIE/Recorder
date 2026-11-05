namespace Recorder.Windows;
internal sealed partial class MainForm
{
    private Button? fullAi;
    private LivePlayer? replayPlayer;
    private readonly WorkflowSelector workflow = new(true);
    private readonly Label workflowHint = new() { AutoSize = true, MaximumSize = new(207, 0), Font = Theme.Body(8), ForeColor = Theme.Muted };
    private Control CreateWorkflowSelector()
    {
        workflow.LiveMode = settings.Mode == "live";
        workflow.ModeChanged += live =>
        {
            if (session != null || starting || stopping || closing) { workflow.LiveMode = settings.Mode == "live"; return; }
            try
            {
                var next = settings with { Mode = live ? "live" : settings.RegularMode,
                    RegularMode = settings.Mode == "live" ? settings.RegularMode : settings.Mode };
                SettingsStore.Save(next); settings = next; UpdateHint();
            }
            catch (Exception ex) { workflow.LiveMode = settings.Mode == "live"; status.Text = "模式未切换：" + ex.Message; }
        };
        return workflow;
    }
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
        var replayMenu = new ContextMenuStrip(menuComponents);
        Theme.StyleMenu(replayMenu);
        replay.Click += (_, _) =>
        {
            if (session != null) { status.Text = "请停止当前会话后重播译音。"; return; }
            var menu = replayMenu; ResetMenu(menu);
            foreach (var row in rows.Where(r => r.AudioId.Length > 0 && LiveHistory.Cache.Contains(r.AudioId)))
            {
                var item = menu.Items.Add(TimeSpan.FromSeconds(row.Seconds).ToString(@"mm\:ss") + "  " + (row.Text.Length > 30 ? row.Text[..30] + "…" : row.Text));
                item.Click += async (_, _) => { try { var pcm = LiveHistory.Cache.Get(row.AudioId); if (pcm == null) return; replayPlayer?.Dispose(); replayPlayer = new(); replayPlayer.Failure += text => UI(() => status.Text = text); replayPlayer.Start(settings.LiveVolume); replayPlayer.Append(pcm); await replayPlayer.FinishAsync(CancellationToken.None); } catch (Exception ex) { status.Text = ex.Message; } };
            }
            if (menu.Items.Count == 0) menu.Items.Add("暂无可重播的译音").Enabled = false;
            menu.Show(replay, new Point(0, replay.Height));
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
        var menu = translationMenu; ResetMenu(menu);
        async Task Change(AppSettings next)
        {
            try { if (next.Mode == "live") SettingsStore.Save(next); else await DesktopBackend.Shared.PreferencesAsync(next); settings = next; UpdateHint(); }
            catch (Exception ex) { status.Text = ex.Message; }
        }
        var enabled = new ToolStripMenuItem("实时翻译") { Checked = settings.Translation, Enabled = session == null && settings.Mode != "live" };
        enabled.Click += async (_, _) => await Change(settings with { Translation = !settings.Translation }); menu.Items.Add(enabled);
        foreach (string language in Recorder.Backend.Languages.Targets)
        {
            var item = new ToolStripMenuItem(language) { Checked = Recorder.Backend.Languages.Target(settings.Mode == "live" ? settings.EffectiveLiveTarget : settings.TargetLanguage) == language, Enabled = session == null && !(settings.Mode == "live" && language == "繁體中文") };
            item.Click += async (_, _) => await Change(settings.Mode == "live" ? settings with { LiveTargetLanguage = FullSettingsStore.TargetCode(language) } : settings with { TargetLanguage = FullSettingsStore.TargetCode(language) }); menu.Items.Add(item);
        }
        menu.Items.Add("翻译设置…", null, (_, _) => configure.PerformClick()); menu.Show(translation, new Point(0, translation.Height));
    }
    private void FullBackendEvent(System.Text.Json.Nodes.JsonObject message)
    {
        if ((string?)message["type"] == "error") UI(() => status.Text = (string?)message["message"] ?? "后端发生错误。");
        if ((string?)message["type"] == "status" && (string?)message["state"] == "ready" && (string?)message["device"] is string device && device.Length > 0) UI(() => { if (settings.Mode == "local") mode.Text = (DesktopBackend.Shared.Core.Runtime.AsrEngine == "qwen" ? "Qwen3-ASR" : "Whisper") + " · " + device.ToUpperInvariant(); });
    }
    private void UpdateFullHint()
    {
        bool live = settings.Mode == "live";
        workflow.LiveMode = live;
        workflowHint.Text = live ? "云端实时翻译，可同步播放译音。" : settings.Translation && settings.TranslationProvider == "local" ? "本地译文随转录预览更新，定稿后校正。" : "先转录原文，可选本地或 API 翻译。";
        configure.Text = live ? "LiveTranslate 设置" : "常规模式设置";
        Text = live ? "声笺 · LiveTranslate x64" : "声笺 · 实时转写 x64";
        if (live)
        {
            var target = Recorder.Backend.Languages.Target(settings.EffectiveLiveTarget);
            translationSummary.Text = "LiveTranslate → " + target + (settings.LiveAudioOutput ? " · 译音已开启" : " · 仅文字");
            translation.Text = "译为 " + target + " ▾";
            if (settings.LiveSecret.Length == 0 && session == null) status.Text = "请打开 LiveTranslate 设置，填写专用 Key 后开始。";
        }
        if (fullAi != null) fullAi.Enabled = settings.Mode != "live";
        if (settings.Mode == "local") { var activeDevice = DesktopBackend.Shared.Core.ActiveAsrDevice; mode.Text = (settings.AsrEngine == "qwen" ? "Qwen3-ASR" : "Whisper") + " · " + (activeDevice.Length > 0 ? activeDevice.ToUpperInvariant() : settings.Device == "auto" ? "自动" : settings.Device.ToUpperInvariant()); }
        if (settings.Mode != "live" && settings.Translation) translationSummary.Text = (settings.TranslationProvider == "local" ? "本地模型" : "API") + " → " + Recorder.Backend.Languages.Target(settings.TargetLanguage);
    }
}
