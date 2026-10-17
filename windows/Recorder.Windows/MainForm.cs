using System.Runtime.InteropServices;
using NAudio.Wave;

namespace Recorder.Windows;

internal sealed partial class MainForm : Form
{
    private AppSettings settings;
    private RecordingSession? session;
    private readonly List<TranscriptRow> rows = new();
    private readonly ComboBox source = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 135 };
    private readonly ComboBox device = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
    private readonly Button fileButton = Theme.Button("选择音频文件…");
    private readonly Button start = Theme.Button("开始转写", true);
    private readonly Button configure = Theme.Button("设置");
    private readonly Button clear = Theme.Button("删除");
    private readonly RichTextBox transcript = new() { Dock = DockStyle.Fill, ReadOnly = true, BorderStyle = BorderStyle.None,
        BackColor = Color.White, ForeColor = Theme.Ink, Font = Theme.Body(12), DetectUrls = false };
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
    private bool starting, stopping, closing;
    private double transcriptSeconds;
    private TaskCompletionSource? settled;
    private SubtitleForm? subtitles;
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public MainForm(AppSettings settings)
    {
        this.settings = settings;
        Text = "声笺 · 实时转写"; ClientSize = new(1040, 700); MinimumSize = new(816, 609); Theme.Style(this);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Margin = new(0) };
        layout.ColumnStyles.Add(new(SizeType.Absolute, 255)); layout.ColumnStyles.Add(new(SizeType.Absolute, 1)); layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        var sidebar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false,
            AutoScroll = true, Padding = new(24), Margin = new(0), BackColor = Theme.Paper };
        void Side(Control control, int bottom = 12) { control.Margin = new(0, 0, 0, bottom); sidebar.Controls.Add(control); }
        var brand = new BrandView { Size = new(207, 38) };
        Side(brand, 30);
        var selected = Theme.Label("▤   实时转写", 10.5f, Theme.Accent);
        selected.AutoSize = false; selected.Size = new(207, 44); selected.TextAlign = ContentAlignment.MiddleLeft;
        selected.Padding = new(13, 0, 0, 0); selected.BackColor = Theme.Tint; Side(selected, 25);
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
        var main = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, BackColor = Color.White, Margin = new(0) };
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
        var paper = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new(30), Margin = new(0) };
        paper.Paint += (_, e) => { using var pen = new Pen(Theme.Line); e.Graphics.DrawLine(pen, 30, 0, paper.Width - 30, 0); };
        paper.Controls.Add(transcript); paper.Controls.Add(empty); main.Controls.Add(paper, 0, 1);
        empty.BringToFront(); transcript.Visible = false;
        partial.AutoSize = true; partial.MaximumSize = new(680, 0); partial.Padding = new(18); partial.Margin = new(30, 0, 30, 18);
        partial.BackColor = Theme.Tint; partial.Font = Theme.Body(12.75f); partial.Visible = false; main.Controls.Add(partial, 0, 2);
        partial.TextChanged += (_, _) => { partial.Visible = partial.Text.Length > 0; UpdateEmpty(); };
        main.SizeChanged += (_, _) => partial.MaximumSize = new(Math.Max(100, main.Width - 60), 0);
        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(250, 250, 250), Padding = new(24, 18, 24, 12), ColumnCount = 3, RowCount = 2, Margin = new(0) };
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
        pin.Click += (_, _) => { TopMost = !TopMost; pin.BackColor = TopMost ? Theme.Tint : Color.White; pin.AccessibleDescription = TopMost ? "已置顶" : "未置顶"; };
        translation.Click += (_, _) => ShowTranslationMenu();
        copy.Enabled = export.Enabled = clear.Enabled = false;
        configure.Click += (_, _) => { using var f = new SettingsForm(this.settings); if (f.ShowDialog(this) == DialogResult.OK) { this.settings = SettingsStore.Load(); UpdateHint(); } };
        start.Click += async (_, _) => { if (session == null) await StartSessionAsync(); else await StopSessionAsync(); };
        clear.Click += (_, _) => { rows.Clear(); transcriptSeconds = 0; RenderRows(); partial.Text = ""; subtitles?.UpdateText("", ""); };
        copy.Click += (_, _) => { if (rows.Count > 0) { try { Clipboard.SetText(TranscriptExport.Text(rows)); status.Text = "已复制全部原文和译文。"; } catch { status.Text = "剪贴板暂不可用，请重试。"; } } };
        export.Click += (_, _) => Export(); subtitleButton.Click += (_, _) => ToggleSubtitles();
#if FULL_BACKEND
        tray = new NotifyIcon { Icon = Icon, Text = "声笺 · Windows x64", Visible = true };
#else
        tray = new NotifyIcon { Icon = Icon, Text = "声笺 · Windows x86", Visible = true };
#endif
        var menu = new ContextMenuStrip();
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
        catch (InvalidOperationException) { }
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
        var menu = new ContextMenuStrip();
        var enabled = new ToolStripMenuItem("实时翻译") { Checked = settings.Translation, Enabled = session == null && settings.Mode != "live" };
        enabled.Click += (_, _) => { settings = settings with { Translation = !settings.Translation }; SettingsStore.Save(settings); UpdateHint(); };
        menu.Items.Add(enabled);
        var languages = new[] { ("zh", "简体中文"), ("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский") };
        foreach (var (code, name) in languages) {
            var item = new ToolStripMenuItem(name) { Checked = settings.TargetLanguage == code, Enabled = session == null };
            item.Click += (_, _) => { settings = settings with { TargetLanguage = code }; SettingsStore.Save(settings); UpdateHint(); }; menu.Items.Add(item);
        }
        menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("翻译设置…", null, (_, _) => configure.PerformClick());
        menu.Closed += (_, _) => menu.Dispose(); menu.Show(translation, new Point(0, translation.Height));
#endif
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
            if (index < 0) rows.Add(item); else rows[index] = item;
            RenderRows();
            if (session == current) { partial.Text = ""; subtitles?.UpdateText(row.Text, row.Translation); }
        }, wait: true);
        current.Partial += text => UI(() => { if (session == current) { partial.Text = text; if (text.Length > 0 && text != "正在识别此句…") subtitles?.UpdateText(text, ""); } });
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
            if (session == current) { session = null; starting = stopping = false; clock.Stop(); meter.SetLevel(0); partial.Text = ""; start.Text = "开始转写"; SetActive(false); }
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
        configure.Enabled = source.Enabled = device.Enabled = fileButton.Enabled = refresh.Enabled = !value;
        clear.Enabled = !value && rows.Count > 0;
        start.BackColor = value ? Color.FromArgb(204, 65, 65) : Theme.Accent;
        var dot = Controls.Find("statusDot", true).FirstOrDefault(); if (dot != null) dot.ForeColor = value ? Color.FromArgb(204, 65, 65) : Theme.Accent;
        UpdateEmpty();
    }
    private void RenderRows()
    {
        transcript.SuspendLayout(); transcript.Clear();
        foreach (var row in rows)
        {
            transcript.SelectionIndent = 56; transcript.SelectionHangingIndent = -56; transcript.SelectionTabs = [56];
            transcript.SelectionFont = Theme.Body(7.5f); transcript.SelectionColor = Theme.Muted;
            transcript.AppendText( $"{(int)row.Seconds / 60:00}:{(int)row.Seconds % 60:00}\t");
            transcript.SelectionFont = Theme.Body(12.75f); transcript.SelectionColor = Theme.Ink; transcript.AppendText(row.Text + "\n");
            if (!string.IsNullOrWhiteSpace(row.Translation)) { transcript.SelectionIndent = 56; transcript.SelectionHangingIndent = 0;
                transcript.SelectionFont = Theme.Body(11.25f); transcript.SelectionColor = Theme.Muted; transcript.AppendText(row.Translation + "\n"); }
            transcript.AppendText("\n");
        }
        transcript.SelectionStart = transcript.TextLength; transcript.ScrollToCaret(); transcript.ResumeLayout();
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
        if (subtitles == null || subtitles.IsDisposed) { subtitles = new(); subtitles.VisibleChanged += (_, _) => subtitleButton.BackColor = subtitles.Visible ? Theme.Tint : Color.White; if (rows.Count > 0) subtitles.UpdateText(rows[^1].Text, rows[^1].Translation); subtitles.Show(this); }
        else if (subtitles.Visible) subtitles.Hide(); else subtitles.Show(this);
        subtitleButton.BackColor = subtitles.Visible ? Theme.Tint : Color.White;
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
