using System.Runtime.InteropServices;
using NAudio.Wave;

namespace Recorder.Windows;

internal sealed class MainForm : Form
{
    private AppSettings settings;
    private RecordingSession? session;
    private readonly List<TranscriptRow> rows = new();
    private readonly ComboBox source = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 135 };
    private readonly ComboBox device = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
    private readonly Button fileButton = Theme.Button("选择音频…");
    private readonly Button start = Theme.Button("开始转写", true);
    private readonly Button configure = Theme.Button("设置");
    private readonly Button clear = Theme.Button("清空");
    private readonly RichTextBox transcript = new() { Dock = DockStyle.Fill, ReadOnly = true, BorderStyle = BorderStyle.None,
        BackColor = Color.White, ForeColor = Theme.Ink, Font = Theme.Body(12), DetectUrls = false };
    private readonly Label empty = Theme.Label("让声音，留下文字。\n\n先在设置中下载模型，或配置 API 服务。\n选择音源后，点击「开始转写」。", 13, Theme.Muted);
    private readonly Label partial = new() { Dock = DockStyle.Fill, AutoEllipsis = true, ForeColor = Theme.Accent, TextAlign = ContentAlignment.MiddleLeft };
    private readonly Label status = new() { Dock = DockStyle.Fill, ForeColor = Theme.Muted, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft };
    private readonly Label count = Theme.Label("0 句", 9, Theme.Muted);
    private readonly Label mode = Theme.Label("", 9, Theme.Accent);
    private readonly AudioMeter meter = new() { Width = 140, Height = 30, Margin = new(12, 0, 0, 0) };
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer clock = new() { Interval = 250 };
    private readonly Label elapsed = Theme.Label("00:00", 12, Theme.Muted);
    private DateTime started;
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
        Text = "声笺 · Windows x86"; ClientSize = new(1060, 760); MinimumSize = new(830, 590); Theme.Style(this);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6, Padding = new(28, 22, 28, 16) };
        foreach (var h in new[] { 73, 58, 55 }) layout.RowStyles.Add(new(SizeType.Absolute, h));
        layout.RowStyles.Add(new(SizeType.Percent, 100)); layout.RowStyles.Add(new(SizeType.Absolute, 45)); layout.RowStyles.Add(new(SizeType.Absolute, 40));
        var heading = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
        heading.ColumnStyles.Add(new(SizeType.Percent, 100)); heading.ColumnStyles.Add(new(SizeType.AutoSize));
        var title = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Margin = new(0) };
        title.RowStyles.Add(new(SizeType.Percent, 65)); title.RowStyles.Add(new(SizeType.Percent, 35));
        var name = Theme.Label("声 笺", 24); name.Font = new("Microsoft YaHei UI", 24, FontStyle.Bold); name.Margin = new(0); name.AutoSize = false; name.Dock = DockStyle.Fill;
        var tagline = Theme.Label("把此刻的声音，记成可读的文字", 9, Theme.Muted); tagline.Margin = new(0); tagline.AutoSize = false; tagline.Dock = DockStyle.Fill;
        title.Controls.Add(name, 0, 0); title.Controls.Add(tagline, 0, 1);
        heading.Controls.Add(title, 0, 0); configure.Anchor = AnchorStyles.Top | AnchorStyles.Right; heading.Controls.Add(configure, 1, 0);
        layout.Controls.Add(heading, 0, 0);
        var inputs = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new(0, 10, 0, 0), WrapContents = false };
        source.Items.AddRange(["麦克风", "系统声音", "音频文件"]); source.SelectedIndex = 0;
        for (int i = 0; i < WaveIn.DeviceCount; i++) device.Items.Add(WaveIn.GetCapabilities(i).ProductName);
        if (device.Items.Count > 0) device.SelectedIndex = 0;
        inputs.Controls.Add(Theme.Label("音源", 10)); inputs.Controls.Add(source); inputs.Controls.Add(device); inputs.Controls.Add(fileButton);
        fileButton.Visible = false; fileButton.MaximumSize = new(400, 36);
        source.SelectedIndexChanged += (_, _) => { device.Visible = source.SelectedIndex == 0; fileButton.Visible = source.SelectedIndex == 2; UpdateHint(); };
        fileButton.Click += (_, _) =>
        {
            using var d = new OpenFileDialog { Filter = "音频文件|*.wav;*.aiff;*.aif;*.mp3;*.m4a;*.aac;*.wma;*.flac;*.mp4|所有文件|*.*" };
            if (d.ShowDialog(this) == DialogResult.OK) { selectedFile = d.FileName; fileButton.Text = Path.GetFileName(selectedFile); UpdateHint(); }
        };
        layout.Controls.Add(inputs, 0, 1);
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        toolbar.Controls.Add(start);
        var subtitleButton = Theme.Button("悬浮字幕"); toolbar.Controls.Add(subtitleButton);
        var copy = Theme.Button("复制"); toolbar.Controls.Add(copy);
        var export = Theme.Button("导出…"); toolbar.Controls.Add(export); toolbar.Controls.Add(clear); toolbar.Controls.Add(meter); toolbar.Controls.Add(elapsed);
        layout.Controls.Add(toolbar, 0, 2);
        var paper = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new(24, 18, 24, 18) };
        paper.Controls.Add(transcript); empty.Dock = DockStyle.Fill; empty.TextAlign = ContentAlignment.MiddleCenter; empty.AutoSize = false;
        paper.Controls.Add(empty); layout.Controls.Add(paper, 0, 3);
        empty.BringToFront(); transcript.Visible = false;
        layout.Controls.Add(partial, 0, 4);
        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3 };
        footer.ColumnStyles.Add(new(SizeType.Percent, 100)); footer.ColumnStyles.Add(new(SizeType.AutoSize)); footer.ColumnStyles.Add(new(SizeType.AutoSize));
        footer.Controls.Add(status, 0, 0); footer.Controls.Add(mode, 1, 0); footer.Controls.Add(count, 2, 0); layout.Controls.Add(footer, 0, 5);
        Controls.Add(layout);
        configure.Click += (_, _) => { using var f = new SettingsForm(this.settings); if (f.ShowDialog(this) == DialogResult.OK) { this.settings = SettingsStore.Load(); UpdateHint(); } };
        start.Click += async (_, _) => { if (session == null) await StartSessionAsync(); else await StopSessionAsync(); };
        clear.Click += (_, _) => { rows.Clear(); transcriptSeconds = 0; RenderRows(); partial.Text = ""; subtitles?.UpdateText("", ""); };
        copy.Click += (_, _) => { if (rows.Count > 0) { try { Clipboard.SetText(TranscriptExport.Text(rows)); status.Text = "已复制全部原文和译文。"; } catch { status.Text = "剪贴板暂不可用，请重试。"; } } };
        export.Click += (_, _) => Export(); subtitleButton.Click += (_, _) => ToggleSubtitles();
        tray = new NotifyIcon { Icon = Icon, Text = "声笺 · Windows x86", Visible = true };
        var menu = new ContextMenuStrip();
        menu.Items.Add("显示主窗口", null, (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("开始 / 停止转写", null, async (_, _) => { if (session == null) await StartSessionAsync(); else await StopSessionAsync(); });
        menu.Items.Add("悬浮字幕", null, (_, _) => ToggleSubtitles()); menu.Items.Add("退出", null, (_, _) => Close()); tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); };
        clock.Tick += (_, _) => { elapsed.Text = (DateTime.UtcNow - started).ToString(@"hh\:mm\:ss"); meter.Decay(); };
        FormClosing += async (_, e) =>
        {
            if (session != null && !closing) { e.Cancel = true; closing = true; session.Cancel(); if (settled != null) await settled.Task; BeginInvoke(Close); }
        };
        FormClosed += (_, _) => { clock.Dispose(); tray.Dispose(); subtitles?.Dispose(); UnregisterHotKey(Handle, 1); };
        Shown += (_, _) => { var registered = RegisterHotKey(Handle, 1, 0x4003, (uint)Keys.Space); UpdateHint(); if (registered) status.Text += "  Ctrl+Alt+空格 开始/停止"; };
        UpdateHint();
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
    private void UpdateHint()
    {
        mode.Text = settings.Mode switch { "local" => "Whisper · 离线", "api" => "API · 音频上传", "stream" => "千问 · 音频上传", _ => "LiveTranslate · 音频上传" };
        status.Text = settings.Mode == "local" && !File.Exists(settings.ModelPath) ? "请先打开设置，下载或选择 Whisper 模型。" : "准备就绪。文字仅保留在本次会话，请及时导出。";
        if (source.SelectedIndex == 1) status.Text = "将采集当前默认扬声器的所有声音。";
        if (source.SelectedIndex == 2 && selectedFile == null) status.Text = "请选择需要转写的音频文件。";
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
            if (session != current) return;
            var id = prefix + row.Id; int index = rows.FindIndex(r => r.Id == id);
            var item = row with { Id = id, Seconds = sessionOffset + row.Seconds };
            if (index < 0) rows.Add(item); else rows[index] = item;
            partial.Text = ""; RenderRows(); subtitles?.UpdateText(row.Text, row.Translation);
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
            started = DateTime.UtcNow; clock.Start();
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
    private void SetActive(bool value) { configure.Enabled = source.Enabled = device.Enabled = fileButton.Enabled = clear.Enabled = !value; }
    private void RenderRows()
    {
        transcript.SuspendLayout(); transcript.Clear();
        foreach (var row in rows)
        {
            transcript.SelectionFont = Theme.Body(9); transcript.SelectionColor = Theme.Muted;
            transcript.AppendText(TimeSpan.FromSeconds(row.Seconds).ToString(@"hh\:mm\:ss") + (row.Final ? "" : " · 识别中") + "\n");
            transcript.SelectionFont = Theme.Body(12); transcript.SelectionColor = Theme.Ink; transcript.AppendText(row.Text + "\n");
            if (!string.IsNullOrWhiteSpace(row.Translation)) { transcript.SelectionFont = Theme.Body(11); transcript.SelectionColor = Theme.Accent; transcript.AppendText(row.Translation + "\n"); }
            transcript.AppendText("\n");
        }
        transcript.SelectionStart = transcript.TextLength; transcript.ScrollToCaret(); transcript.ResumeLayout();
        empty.Visible = rows.Count == 0; transcript.Visible = rows.Count > 0;
        if (empty.Visible) empty.BringToFront();
        count.Text = $"{rows.Count} 句";
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
        if (subtitles == null || subtitles.IsDisposed) { subtitles = new(); if (rows.Count > 0) subtitles.UpdateText(rows[^1].Text, rows[^1].Translation); subtitles.Show(this); }
        else if (subtitles.Visible) subtitles.Hide(); else subtitles.Show(this);
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
        for (int i = 0; i < 22; i++) { int h = 5 + (i % 5) * 3; e.Graphics.FillRectangle(i < level * 22 ? active : idle, i * 6, (Height - h) / 2, 3, h); }
    }
}

internal sealed class SubtitleForm : Form
{
    private readonly Label source = new() { Dock = DockStyle.Fill, ForeColor = Color.White, TextAlign = ContentAlignment.MiddleCenter, AutoEllipsis = true };
    private readonly Label target = new() { Dock = DockStyle.Fill, ForeColor = Color.FromArgb(150, 209, 245), TextAlign = ContentAlignment.MiddleCenter, AutoEllipsis = true };
    public SubtitleForm()
    {
        Text = "声笺 · 悬浮字幕"; ClientSize = new(820, 180); MinimumSize = new(400, 130); TopMost = true; ShowInTaskbar = false;
        BackColor = Theme.Ink; Padding = new(20, 10, 20, 10); source.Font = Theme.Body(18); target.Font = Theme.Body(15);
        var grid = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1 };
        grid.RowStyles.Add(new(SizeType.Percent, 55)); grid.RowStyles.Add(new(SizeType.Percent, 45)); grid.Controls.Add(source, 0, 0); grid.Controls.Add(target, 0, 1); Controls.Add(grid);
        StartPosition = FormStartPosition.Manual;
        var screen = Screen.PrimaryScreen!.WorkingArea; Location = new(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - 60);
        source.Text = "开始转写后，字幕将在这里显示";
    }
    public void UpdateText(string original, string translation) { source.Text = original; target.Text = translation; }
}
