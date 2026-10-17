namespace Recorder.Windows;
internal sealed partial class MainForm
{
    private Button? fullAi;
    private LivePlayer? replayPlayer;
    private void InitializeFullBackend(Button ai, FlowLayoutPanel toolbar)
    {
        fullAi = ai; ai.Enabled = settings.Mode != "live"; ai.AccessibleDescription = "总结、文本翻译和自定义问题";
        ai.Click += (_, _) => { var text = transcript.SelectionLength > 0 ? transcript.SelectedText : TranscriptExport.Text(rows); using var form = new AIForm(text); form.ShowDialog(this); };
        clear.Click += (_, _) => { DesktopBackend.Shared.ClearHistory(); LiveHistory.Cache.Clear(); replayPlayer?.Stop(); };
        var replay = Theme.Button("重播译音 ▾"); toolbar.Controls.Add(replay);
        replay.Click += (_, _) =>
        {
            if (session != null) { status.Text = "请停止当前会话后重播译音。"; return; }
            var menu = new ContextMenuStrip();
            foreach (var row in rows.Where(r => r.AudioId.Length > 0 && LiveHistory.Cache.Get(r.AudioId) != null))
            {
                var item = menu.Items.Add(TimeSpan.FromSeconds(row.Seconds).ToString(@"mm\:ss") + "  " + (row.Text.Length > 30 ? row.Text[..30] + "…" : row.Text));
                item.Click += async (_, _) => { try { var pcm = LiveHistory.Cache.Get(row.AudioId); if (pcm == null) return; replayPlayer?.Dispose(); replayPlayer = new(); replayPlayer.Failure += text => UI(() => status.Text = text); replayPlayer.Start(settings.LiveVolume); replayPlayer.Append(pcm); await replayPlayer.FinishAsync(CancellationToken.None); } catch (Exception ex) { status.Text = ex.Message; } };
            }
            if (menu.Items.Count == 0) menu.Items.Add("暂无可重播的译音").Enabled = false;
            menu.Closed += (_, _) => menu.Dispose(); menu.Show(replay, new Point(0, replay.Height));
        };
        DesktopBackend.Shared.Event += FullBackendEvent;
        FormClosed += (_, _) => { DesktopBackend.Shared.Event -= FullBackendEvent; replayPlayer?.Dispose(); LiveHistory.Cache.Clear(); };
        if (FullSettingsStore.StartupError != null) status.Text = FullSettingsStore.StartupError;
    }
    private void FullBackendEvent(System.Text.Json.Nodes.JsonObject message)
    {
        if ((string?)message["type"] == "error") UI(() => status.Text = (string?)message["message"] ?? "后端发生错误。");
    }
    private void UpdateFullHint()
    {
        if (fullAi != null) fullAi.Enabled = settings.Mode != "live";
        if (settings.Mode == "local") mode.Text = (settings.AsrEngine == "qwen" ? "Qwen3-ASR" : "Whisper") + " · " + settings.Device;
        if (settings.Mode != "live" && settings.Translation) translationSummary.Text = (settings.TranslationProvider == "local" ? "本地模型" : "API") + " → " + Recorder.Backend.Languages.Target(settings.TargetLanguage);
    }
}
