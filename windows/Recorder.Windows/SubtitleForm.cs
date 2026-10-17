namespace Recorder.Windows;

internal sealed class SubtitleForm : Form
{
    private readonly Label source = new() { AutoSize = true, ForeColor = Color.White, Margin = new(0, 0, 0, 14) };
    private readonly Label target = new() { AutoSize = true, ForeColor = Color.FromArgb(166, 224, 255), Margin = new(0) };
    private readonly FlowLayoutPanel text = new() { Dock = DockStyle.Fill, AutoScroll = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new(20) };
    private readonly Label state = Theme.Label("准备就绪", 9, Color.Silver);
    private readonly ContextMenuStrip style = new();
    private bool showTranslation = true;
    public SubtitleForm()
    {
        AutoScaleDimensions = new SizeF(96, 96); AutoScaleMode = AutoScaleMode.Dpi;
        Font = Theme.Body(9); DoubleBuffered = true;
        Text = "声笺字幕"; ClientSize = new(760, 240); MinimumSize = new(420, 160);
        TopMost = true; ShowInTaskbar = false; FormBorderStyle = FormBorderStyle.None;
        BackColor = Color.FromArgb(28, 30, 33); ForeColor = Color.White; Padding = new(1);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Margin = new(0) };
        layout.RowStyles.Add(new(SizeType.Absolute, 52)); layout.RowStyles.Add(new(SizeType.Absolute, 1)); layout.RowStyles.Add(new(SizeType.Percent, 100));
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 1, Padding = new(18, 8, 12, 8), Margin = new(0) };
        header.RowStyles.Add(new(SizeType.Percent, 100));
        header.ColumnStyles.Add(new(SizeType.Absolute, 100)); header.ColumnStyles.Add(new(SizeType.Percent, 100));
        header.ColumnStyles.Add(new(SizeType.Absolute, 68)); header.ColumnStyles.Add(new(SizeType.Absolute, 36));
        var title = Theme.Label("声笺字幕", 9, Color.White); title.AutoSize = false; title.AutoEllipsis = true; title.Dock = DockStyle.Fill; title.TextAlign = ContentAlignment.MiddleLeft; title.Margin = new(0);
        state.AutoSize = false; state.AutoEllipsis = true; state.Dock = DockStyle.Fill; state.TextAlign = ContentAlignment.MiddleLeft; state.Margin = new(0);
        void Drag(object? sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)2, IntPtr.Zero); } }
        title.MouseDown += Drag; state.MouseDown += Drag; header.MouseDown += Drag;
        var settings = HeaderButton("样式"); var close = HeaderButton("×");
        foreach (var button in new[] { settings, close }) { button.BackColor = BackColor; button.ForeColor = Color.White; button.AutoSize = false; button.MinimumSize = Size.Empty; button.Padding = new(0); button.Dock = DockStyle.Fill; button.Margin = new(3, 0, 3, 0); }
        close.AccessibleName = "关闭字幕窗口，继续转写"; close.Click += (_, _) => Hide();
        header.Controls.Add(title, 0, 0); header.Controls.Add(state, 1, 0); header.Controls.Add(settings, 2, 0); header.Controls.Add(close, 3, 0);
        layout.Controls.Add(header, 0, 0); layout.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(54, 57, 61), Margin = new(0) }, 0, 1);
        source.Font = Theme.Body(18); target.Font = Theme.Body(16); text.Controls.Add(source); text.Controls.Add(target); layout.Controls.Add(text, 0, 2); Controls.Add(layout);
        var sizes = new ToolStripMenuItem("字号");
        foreach (int size in new[] { 16, 20, 24, 28, 32, 40 }) sizes.DropDownItems.Add(size.ToString(), null, (_, _) => {
            var oldSource = source.Font; var oldTarget = target.Font; source.Font = Theme.Body(size * .75f); target.Font = Theme.Body(size * .75f); oldSource.Dispose(); oldTarget.Dispose();
        });
        style.Items.Add(sizes);
        var translated = new ToolStripMenuItem("显示译文") { Checked = true, CheckOnClick = true };
        translated.CheckedChanged += (_, _) => { showTranslation = translated.Checked; target.Visible = showTranslation && target.Text.Length > 0; }; style.Items.Add(translated);
        settings.Click += (_, _) => style.Show(settings, new Point(0, settings.Height));
        void FitText() {
            int gutter = text.Padding.Horizontal + SystemInformation.VerticalScrollBarWidth + 6 * DeviceDpi / 96;
            source.MaximumSize = target.MaximumSize = new(Math.Max(80, text.ClientSize.Width - gutter), 0);
        }
        text.SizeChanged += (_, _) => FitText(); Shown += (_, _) => FitText();
        StartPosition = FormStartPosition.Manual;
        var screen = Screen.PrimaryScreen!.WorkingArea; Location = new(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - 70);
        source.Text = "开始转写后，字幕将显示在这里";

    }
    private static Button HeaderButton(string caption)
    {
        var button = new Button { Text = caption, FlatStyle = FlatStyle.Flat, Font = Theme.Body(9),
            Cursor = Cursors.Hand, UseVisualStyleBackColor = false, AccessibleName = caption };
        button.FlatAppearance.BorderSize = 0;
        button.FlatAppearance.MouseOverBackColor = Color.FromArgb(58, 62, 67);
        button.FlatAppearance.MouseDownBackColor = Color.FromArgb(72, 77, 83);
        return button;
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) style.Dispose();
        base.Dispose(disposing);
    }
    public void UpdateText(string original, string translation)
    {
        source.Text = original.Length == 0 ? "开始转写后，字幕将显示在这里" : original; target.Text = translation; target.Visible = showTranslation && translation.Length > 0;
        state.Text = original.Length > 0 ? "实时转写" : "准备就绪";
        // Each update replaces the current subtitle, so start at the original text.
        // Scrolling to the translation can otherwise leave a clipped fragment at the top.
        text.AutoScrollPosition = Point.Empty;
    }
    protected override void WndProc(ref Message m)
    {
        base.WndProc(ref m);
        if (m.Msg != 0x84) return;
        var position = PointToClient(new Point(unchecked((short)(long)m.LParam), unchecked((short)((long)m.LParam >> 16))));
        int edge = 7 * DeviceDpi / 96;
        bool left = position.X < edge, right = position.X >= Width - edge, top = position.Y < edge, bottom = position.Y >= Height - edge;
        if (left || right || top || bottom) m.Result = (IntPtr)(top ? left ? 13 : right ? 14 : 12 : bottom ? left ? 16 : right ? 17 : 15 : left ? 10 : 11);
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
}
