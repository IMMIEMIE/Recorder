using System.Runtime.InteropServices;
using NAudio.Wave;

namespace Recorder.Windows;

internal sealed partial class MainForm : Form
{
    private AppSettings settings;
    private readonly System.ComponentModel.IContainer menuComponents = new System.ComponentModel.Container();
    private readonly ContextMenuStrip translationMenu;
    private RecordingSession? session;
    private readonly List<TranscriptRow> rows = new();
    private readonly ComboBox source = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 135 };
    private readonly ComboBox device = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
    private readonly Button fileButton = Theme.Button("选择音频文件…");
    private readonly Button start = Theme.Button("开始转写", true);
    private readonly Button configure = Theme.Button("设置");
    private readonly Button clear = Theme.Button("删除");
    private readonly TranscriptView transcript = new();
    private readonly Button latest = Theme.Button("回到最新 ↓", true);
    private readonly ListeningView empty = new() { Dock = DockStyle.Fill };
    private readonly Label inputHint = Theme.Label("", 8, Theme.Muted);
    private readonly Label translationSummary = Theme.Label("", 9.75f);
    private readonly Button refresh = Theme.Button("刷新设备");
    private readonly Button copy = Theme.Button("复制");
    private readonly Button export = Theme.Button("另存为…");
    private readonly Button translation = Theme.Button("翻译 ▾");
    private readonly Button subtitleButton = Theme.Button("字幕");
    private readonly Button pin = Theme.Button("置顶");
    private readonly ToolTip tips = new();
    private readonly Label partial = new() { Dock = DockStyle.Fill, AutoEllipsis = true, ForeColor = Theme.Accent, TextAlign = ContentAlignment.MiddleLeft };
    private readonly Label status = new() { Dock = DockStyle.Fill, ForeColor = Theme.Muted, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
    private readonly Label mode = Theme.Label("", 9, Theme.Accent);
    private readonly AudioMeter meter = new() { Width = 140, Height = 30, Margin = new(12, 0, 0, 0) };
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer clock = new() { Interval = 250 };
    private string? selectedFile;
    private string partialSource = "", partialTranslation = "";
    private bool starting, stopping, closing;
    private double transcriptSeconds;
    private TaskCompletionSource? settled;
    private SubtitleForm? subtitles;
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public MainForm(AppSettings settings)
    {
        translationMenu = new ContextMenuStrip(menuComponents);
        Theme.StyleMenu(translationMenu);
        this.settings = settings;
        Text = "声笺 · 实时转写"; ClientSize = new(1040, 700); MinimumSize = new(816, 609); Theme.Style(this);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = new(0) };
        layout.ColumnStyles.Add(new(SizeType.Absolute, 255)); layout.ColumnStyles.Add(new(SizeType.Absolute, 1)); layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        var sidebar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false,
            AutoScroll = true, Padding = new(24), Margin = new(0), BackColor = Theme.Paper };
        void Side(Control control, int bottom = 12) { control.Margin = new(0, 0, 0, bottom); sidebar.Controls.Add(control); }
#if FULL_BACKEND
        Side(Theme.Label("工作模式", 9, Theme.Muted), 6);
        Side(CreateWorkflowSelector(), 6);
        Side(workflowHint, 18);
#endif
        Side(Theme.Label("音频输入", 9, Theme.Muted));
        source.Width = device.Width = 207; source.Font = device.Font = Theme.Body(9);
        source.Items.AddRange(["麦克风", "系统声音", "音频文件"]); source.SelectedIndex = 0;
        Side(source); Side(device);
        fileButton.MaximumSize = new(207, 32); fileButton.Width = 207; Side(fileButton);
        inputHint.MaximumSize = new(207, 0); Side(inputHint, 6);
        meter.Width = 207; meter.Height = 22; Side(meter, 6);
        refresh.ForeColor = Theme.Accent; refresh.BackColor = Theme.Paper; Side(refresh, 24);
        Side(new Panel { Width = 207, Height = 1, BackColor = Theme.Line }, 24);
        Side(Theme.Label("识别模型", 9, Theme.Muted), 6); mode.MaximumSize = new(207, 0); mode.ForeColor = Theme.Ink; mode.Font = Theme.Body(9.75f); Side(mode, 18);
        Side(Theme.Label("实时翻译", 9, Theme.Muted), 6); translationSummary.MaximumSize = new(207, 0); Side(translationSummary);
        configure.ForeColor = Theme.Accent; configure.BackColor = Theme.Paper; Side(configure);
        layout.Controls.Add(sidebar, 0, 0); layout.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Theme.Line, Margin = new(0) }, 1, 0);
        var main = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, BackColor = Theme.Surface, Margin = new(0) };
        main.RowStyles.Add(new(SizeType.Absolute, 58)); main.RowStyles.Add(new(SizeType.Percent, 100));
        main.RowStyles.Add(new(SizeType.AutoSize)); main.RowStyles.Add(new(SizeType.Absolute, 112));
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new(12, 14, 18, 0), Margin = new(0) };
        var ai = Theme.Button("AI 提问"); ai.Enabled = false;
#if FULL_BACKEND
        ai.AccessibleDescription = "AI 服务将在设置中配置";
#else
        ai.AccessibleDescription = "Windows 版尚未接入 AI 提问服务";
        tips.SetToolTip(ai, "Windows 版尚未接入 AI 提问服务"); tips.SetToolTip(clear, "清空会话");
#endif
        tips.SetToolTip(pin, "窗口置顶"); tips.SetToolTip(subtitleButton, "打开 / 关闭字幕模式");
        foreach (var button in new[] { clear, copy, export, ai, translation, pin, subtitleButton }) toolbar.Controls.Add(button);
        main.Controls.Add(toolbar, 0, 0);
        var paper = new Panel { Dock = DockStyle.Fill, BackColor = Theme.Surface, Padding = new(30), Margin = new(0) };
        paper.Paint += (_, e) => { using var pen = new Pen(Theme.Line); e.Graphics.DrawLine(pen, 30, 0, paper.Width - 30, 0); };
        paper.Controls.Add(transcript); paper.Controls.Add(empty); main.Controls.Add(paper, 0, 1);
        latest.Visible = false; latest.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        paper.Controls.Add(latest);
        void PlaceLatest() => latest.Location = new(Math.Max(0, paper.ClientSize.Width - latest.Width - 30), Math.Max(0, paper.ClientSize.Height - latest.Height - 16));
        paper.SizeChanged += (_, _) => PlaceLatest(); latest.SizeChanged += (_, _) => PlaceLatest();
        latest.Click += (_, _) => transcript.JumpToLatest();
        transcript.FollowChanged += () => { latest.Visible = !transcript.Following; latest.Text = transcript.NewBelow ? "有新内容 · 回到最新 ↓" : "回到最新 ↓"; if (latest.Visible) latest.BringToFront(); };
        tips.SetToolTip(latest, "锁定最新文字并持续跟随；向上滚动解除跟随（Ctrl + ↓）");
        empty.BringToFront(); transcript.Visible = false;
        partial.AutoSize = true; partial.MaximumSize = new(680, 0); partial.Padding = new(18); partial.Margin = new(30, 0, 30, 18);
        partial.BackColor = Theme.Tint; partial.Font = Theme.Body(12.75f); partial.Visible = false; main.Controls.Add(partial, 0, 2);
        partial.TextChanged += (_, _) => { partial.Visible = partial.Text.Length > 0; UpdateEmpty(); UpdateSubtitleText(); if (partial.Visible) transcript.NotifyNewContent(); };
        main.SizeChanged += (_, _) => partial.MaximumSize = new(Math.Max(100, main.Width - 60), 0);
        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Theme.Footer, Padding = new(24, 18, 24, 12), ColumnCount = 3, RowCount = 2, Margin = new(0) };
        footer.ColumnStyles.Add(new(SizeType.Absolute, 20)); footer.ColumnStyles.Add(new(SizeType.Percent, 100)); footer.ColumnStyles.Add(new(SizeType.AutoSize));
        footer.RowStyles.Add(new(SizeType.Percent, 100)); footer.RowStyles.Add(new(SizeType.Absolute, 24));
        var dot = Theme.Label("●", 10, Theme.Accent); dot.Name = "statusDot"; dot.AutoSize = false; dot.Dock = DockStyle.Fill; dot.Margin = new(0); dot.TextAlign = ContentAlignment.MiddleLeft;
        footer.Controls.Add(dot, 0, 0); status.Font = Theme.Body(9.75f); status.ForeColor = Theme.Ink; footer.Controls.Add(status, 1, 0);
        start.MinimumSize = new(128, 36); start.Anchor = AnchorStyles.Right; footer.Controls.Add(start, 2, 0);
        var shortcut = Theme.Label("Ctrl + Alt + Space  ·  开始 / 停止", 7.5f, Theme.Muted);
        shortcut.AutoSize = false; shortcut.Margin = new(0); shortcut.Dock = DockStyle.Fill; shortcut.TextAlign = ContentAlignment.MiddleCenter; footer.Controls.Add(shortcut, 0, 1); footer.SetColumnSpan(shortcut, 3);
        main.Controls.Add(footer, 0, 3); layout.Controls.Add(main, 2, 0); Controls.Add(layout);
        source.SelectedIndexChanged += (_, _) => UpdateHint();
        refresh.Click += (_, _) => RefreshDevices(); RefreshDevices();
        fileButton.Click += (_, _) =>
        {
            using var d = new OpenFileDialog { Filter = "音频文件|*.wav;*.aiff;*.aif;*.mp3;*.m4a;*.aac;*.wma;*.flac;*.mp4|所有文件|*.*" };
            if (d.ShowDialog(this) == DialogResult.OK) { selectedFile = d.FileName; UpdateHint(); }
        };
        pin.Click += (_, _) => { TopMost = !TopMost; pin.BackColor = TopMost ? Theme.Tint : Theme.Surface; pin.AccessibleDescription = TopMost ? "已置顶" : "未置顶"; };
        translation.Click += (_, _) => ShowTranslationMenu();
        copy.Enabled = export.Enabled = clear.Enabled = false;
        configure.Click += (_, _) =>
        {
            using var f = new SettingsForm(this.settings);
            var result = f.ShowDialog(this); var saved = SettingsStore.Load();
            // Appearance can be applied independently while the settings dialog stays open.
            this.settings.Appearance = saved.Appearance;
            if (result == DialogResult.OK) { this.settings = saved; UpdateHint(); }
        };
        start.Click += async (_, _) => { if (session == null) await StartSessionAsync(); else await StopSessionAsync(); };
        clear.Click += (_, _) => { rows.Clear(); transcriptSeconds = 0; RenderRows(); SetPartial(""); subtitles?.UpdateText("", ""); };
        copy.Click += (_, _) => { if (rows.Count > 0) { try { Clipboard.SetText(TranscriptExport.Text(rows)); status.Text = "已复制全部原文和译文。"; } catch { status.Text = "剪贴板暂不可用，请重试。"; } } };
        export.Click += (_, _) => Export(); subtitleButton.Click += (_, _) => ToggleSubtitles();
#if FULL_BACKEND
        tray = new NotifyIcon { Icon = Icon, Text = "声笺 · Windows x64", Visible = true };
#else
        tray = new NotifyIcon { Icon = Icon, Text = "声笺 · Windows x86", Visible = true };
#endif
        var menu = new ContextMenuStrip(menuComponents);
        Theme.StyleMenu(menu);
        menu.Items.Add("显示主窗口", null, (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("开始 / 停止转写", null, async (_, _) => { if (session == null) await StartSessionAsync(); else await StopSessionAsync(); });
        menu.Items.Add("悬浮字幕", null, (_, _) => ToggleSubtitles()); menu.Items.Add("退出", null, (_, _) => Close()); tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); };
        clock.Tick += (_, _) => meter.Decay();
        FormClosing += async (_, e) =>
        {
            if (session != null && !closing) { e.Cancel = true; closing = true; session.Cancel(); if (settled != null) await settled.Task; BeginInvoke(Close); }
        };
        FormClosed += (_, _) => { clock.Dispose(); tips.Dispose(); tray.Dispose(); subtitles?.Dispose(); UnregisterHotKey(Handle, 1); };
        Shown += (_, _) => { var registered = RegisterHotKey(Handle, 1, 0x4003, (uint)Keys.Space); UpdateHint(); if (!registered) status.Text = "快捷键已被占用，请使用开始按钮。"; };
        UpdateHint();
#if FULL_BACKEND
        InitializeFullBackend(ai, toolbar);
#endif
    }
    private void UI(Action action, bool wait = false)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try
        {
            if (!InvokeRequired) action();
            else if (wait) Invoke(action);
            else BeginInvoke(action);
        }
        catch (InvalidOperationException) { /* Includes ObjectDisposedException while the window closes. */ }
    }
    private void RefreshDevices()
    {
        var previous = device.SelectedItem?.ToString(); device.Items.Clear();
        for (int i = 0; i < WaveIn.DeviceCount; i++) device.Items.Add(WaveIn.GetCapabilities(i).ProductName);
        if (device.Items.Count > 0) device.SelectedIndex = Math.Max(0, device.Items.IndexOf(previous ?? ""));
        UpdateHint();
    }
    private void UpdateHint()
    {
        device.Visible = refresh.Visible = source.SelectedIndex == 0; fileButton.Visible = source.SelectedIndex == 2;
        inputHint.Text = source.SelectedIndex switch { 0 => device.Items.Count > 0 ? "● 麦克风已就绪" : "未检测到麦克风", 1 => "采集其他应用播放的声音，不使用麦克风。", _ => (selectedFile == null ? "尚未选择文件" : Path.GetFileName(selectedFile)) + "\n按原始语速转写，不播放声音；文件结束后自动处理尾句。" };
        mode.Text = settings.Mode switch { "local" => "Whisper · " + Path.GetFileNameWithoutExtension(settings.ModelPath), "api" => settings.ApiModel, "stream" => "千问 · 流式识别", _ => "LiveTranslate" };
        translationSummary.Text = settings.Mode == "live" ? "LiveTranslate → " + settings.TargetLanguage : settings.Translation ? "API → " + settings.TargetLanguage : "未开启";
        translation.Text = settings.Translation || settings.Mode == "live" ? "译为 " + settings.TargetLanguage + " ▾" : "翻译 ▾";
        status.Text = settings.Mode == "local" && !File.Exists(settings.ModelPath) ? "请在设置中下载或选择模型" : "准备就绪";
        if (source.SelectedIndex == 2 && selectedFile == null) status.Text = "请选择需要转写的音频文件";
#if FULL_BACKEND
        UpdateFullHint();
#endif
    }
    private void ShowTranslationMenu()
    {
#if FULL_BACKEND
        ShowFullTranslationMenu();
        return;
#else
        var menu = translationMenu; ResetMenu(menu);
        var enabled = new ToolStripMenuItem("实时翻译") { Checked = settings.Translation, Enabled = session == null && settings.Mode != "live" };
        enabled.Click += (_, _) => { settings = settings with { Translation = !settings.Translation }; SettingsStore.Save(settings); UpdateHint(); };
        menu.Items.Add(enabled);
        var languages = new[] { ("zh", "简体中文"), ("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский") };
        foreach (var (code, name) in languages) {
            var item = new ToolStripMenuItem(name) { Checked = settings.TargetLanguage == code, Enabled = session == null };
            item.Click += (_, _) => { settings = settings with { TargetLanguage = code }; SettingsStore.Save(settings); UpdateHint(); }; menu.Items.Add(item);
        }
        menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("翻译设置…", null, (_, _) => configure.PerformClick());
        menu.Show(translation, new Point(0, translation.Height));
#endif
    }
    private static void ResetMenu(ContextMenuStrip menu)
    {
        // Closed runs inside WinForms' close sequence. Keep the menu alive until its owning form is disposed.
        // Rebuild only after Close returns, disposing old items and their captured row/settings references.
        menu.Close();
        while (menu.Items.Count > 0)
        {
            var item = menu.Items[0]; menu.Items.RemoveAt(0); item.Dispose();
        }
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) menuComponents.Dispose();
        base.Dispose(disposing);
    }
    private void UpdateEmpty()
    {
        empty.Listening = session != null || starting; empty.Visible = rows.Count == 0 && partial.Text.Length == 0;
        transcript.Visible = rows.Count > 0; empty.Invalidate(); if (empty.Visible) empty.BringToFront();
    }
    private async Task StartSessionAsync()
    {
        if (session != null || starting || closing) return;
        if (source.SelectedIndex == 2 && selectedFile == null) { fileButton.PerformClick(); if (selectedFile == null) return; }
        if (source.SelectedIndex == 0 && device.SelectedIndex < 0) { status.Text = "没有可用麦克风，请连接设备，或选择系统声音 / 音频文件。"; return; }
        if (settings.Mode == "local" && !File.Exists(settings.ModelPath)) { configure.PerformClick(); return; }
        starting = true; stopping = false; SetActive(true); status.Text = "正在加载模型或连接服务…"; start.Text = "取消启动";
        settled = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var current = new RecordingSession(settings.Mode == "live" && settings.TargetLanguage == "zh-TW" ? settings with { TargetLanguage = "zh" } : settings with { });
        session = current;
        var prefix = Guid.NewGuid().ToString("N") + ":";
        var sessionOffset = transcriptSeconds;
        current.Row += row => UI(() =>
        {
#if !FULL_BACKEND
            if (session != current) return;
#endif
            var id = prefix + row.Id; int index = rows.FindIndex(r => r.Id == id);
            var item = row with { Id = id, Seconds = sessionOffset + row.Seconds };
#if !FULL_BACKEND
            bool sourceChanged = index < 0 || rows[index].Text != item.Text;
#endif
            if (index < 0) rows.Add(item); else rows[index] = item;
            RenderRows();
#if !FULL_BACKEND
            if (session == current && sourceChanged && rows[^1].Id == id) SetPartial("");
#endif
            UpdateSubtitleText();
        });
        current.Partial += text => UI(() => { if (session == current) SetPartial(text); });
#if FULL_BACKEND
        current.PartialTranslation += text => UI(() => { if (session == current) { partialTranslation = text; RenderPartial(); } });
#endif
        current.Notice += text => UI(() => { if (session == current) status.Text = text; });
        current.Level += peak => UI(() => { if (session == current) meter.SetLevel(peak); });
        current.FileEnded += () => UI(async () => { if (session == current && !starting && !stopping) await StopSessionAsync(); });
        string? failure = null;
        try
        {
            await current.StartAsync(source.SelectedIndex, device.SelectedIndex, selectedFile);
            starting = false;
            if (!stopping) { start.Text = "停止转写"; status.Text = "正在转写 · 停止后会处理尾句。"; }
            clock.Start();
            await current.Completion;
            status.Text = "转写已结束，可复制或导出文字。";
        }
        catch (OperationCanceledException) { status.Text = "已取消，已有文字已保留。"; }
        catch (Exception ex) { failure = ex.Message; }
        finally
        {
            await current.DisposeAsync();
            transcriptSeconds = sessionOffset + current.AudioSeconds;
            for (int i = 0; i < rows.Count; i++)
                if (rows[i].Id.StartsWith(prefix) && !rows[i].Final) rows[i] = rows[i] with { Text = rows[i].Text + " [未完成]", Final = true };
            RenderRows();
            if (session == current) { session = null; starting = stopping = false; clock.Stop(); meter.SetLevel(0); SetPartial(""); start.Text = "开始转写"; SetActive(false); }
            if (failure != null) { status.Text = "转写失败：" + failure; if (!closing) MessageBox.Show(this, failure, "声笺", MessageBoxButtons.OK, MessageBoxIcon.Information); }
            settled.TrySetResult();
        }
    }
    private async Task StopSessionAsync()
    {
        var current = session; if (current == null) return;
        if (starting || stopping) { current.Cancel(); status.Text = "正在取消，已有文字已保留…"; return; }
        stopping = true; start.Text = "取消等待"; status.Text = "正在处理尾句及剩余翻译…";
        try { await current.StopAsync(); } catch { /* StartSessionAsync owns completion and error reporting. */ }
    }
    private void SetActive(bool value) {
#if FULL_BACKEND
        workflow.Enabled = !value;
#endif
        configure.Enabled = source.Enabled = device.Enabled = fileButton.Enabled = refresh.Enabled = !value;
        clear.Enabled = !value && rows.Count > 0;
        start.BackColor = value ? Color.FromArgb(204, 65, 65) : Theme.Primary;
        start.ForeColor = Theme.OnPrimary;
        var dot = Controls.Find("statusDot", true).FirstOrDefault(); if (dot != null) dot.ForeColor = value ? Color.FromArgb(204, 65, 65) : Theme.Accent;
        UpdateEmpty();
    }
    private void RenderRows()
    {
        transcript.Render(rows);
        UpdateEmpty(); copy.Enabled = export.Enabled = rows.Count > 0; clear.Enabled = session == null && rows.Count > 0;
    }
    private void Export()
    {
        if (rows.Count == 0) { status.Text = "尚无可导出的文字。"; return; }
        using var dialog = new SaveFileDialog { Filter = "纯文本 (*.txt)|*.txt|字幕 (*.srt)|*.srt", FileName = "声笺-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"), AddExtension = true };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try { File.WriteAllText(dialog.FileName, dialog.FilterIndex == 2 ? TranscriptExport.Srt(rows) : TranscriptExport.Text(rows), new System.Text.UTF8Encoding(true)); status.Text = "已导出：" + dialog.FileName; }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "导出失败"); }
    }
    private void ToggleSubtitles()
    {
        if (subtitles == null || subtitles.IsDisposed)
        {
            subtitles = new(); subtitles.VisibleChanged += (_, _) => subtitleButton.BackColor = subtitles.Visible ? Theme.Tint : Theme.Surface;
            subtitles.Notice += message => status.Text = message; UpdateSubtitleText(); subtitles.Show(this); subtitles.Activate();
        }
        else if (subtitles.Visible) subtitles.Hide(); else { UpdateSubtitleText(); subtitles.Show(this); subtitles.Activate(); }
        subtitleButton.BackColor = subtitles.Visible ? Theme.Tint : Theme.Surface;
    }
    private void UpdateSubtitleText()
    {
        if (subtitles == null || subtitles.IsDisposed) return;
        string source = rows.Count > 0 ? rows[^1].Text : "", target = rows.Count > 0 ? rows[^1].Translation : "";
        if (partialSource.Length > 0 && partialSource != "正在识别此句…")
        {
            source = SubtitleLayout.Join(source, partialSource);
            if (partialTranslation.Length > 0) target = SubtitleLayout.Join(target, partialTranslation);
        }
        subtitles.UpdateText(source, target, session != null || starting);
    }
    private void SetPartial(string source)
    {
        partialSource = source;
        if (source.Length == 0) partialTranslation = "";
        // RecordingSession explicitly clears the translation when the sentence changes.
        // Growing ASR previews keep the last useful translation until the next snapshot arrives.
        RenderPartial();
    }
    private void RenderPartial()
    {
        partial.Text = partialSource.Length == 0 ? "" : partialSource + (partialTranslation.Length > 0 ? "\n\n译文预览：" + partialTranslation : "");
    }
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == (Keys.Control | Keys.Down)) { transcript.JumpToLatest(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x312 && m.WParam == (IntPtr)1) { start.PerformClick(); }
        base.WndProc(ref m);
    }
}

internal sealed class AudioMeter : Control
{
    private float level;
    public AudioMeter() { DoubleBuffered = true; }
    public void SetLevel(float value) { level = Math.Clamp(value, 0, 1); Invalidate(); }
    public void Decay() { level *= .78f; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e)
    {
        using var idle = new SolidBrush(Theme.Line); using var active = new SolidBrush(Theme.Accent);
        for (int i = 0; i < 24; i++) { int h = (5 + (i % 4) * 3) * DeviceDpi / 96; e.Graphics.FillRectangle(i < level * 24 ? active : idle, i * Width / 24f, (Height - h) / 2, Math.Max(3, Width / 24f - 3), h); }
    }
}
