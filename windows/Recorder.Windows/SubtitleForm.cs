using System.ComponentModel;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Recorder.Windows;

/// <summary>A per-pixel transparent caption window, anchored at the bottom centre of its text.</summary>
internal sealed class SubtitleForm : Form
{
    private SubtitlePreferences preferences = SubtitlePreferences.Load();
    private readonly ContextMenuStrip style = new();
    private readonly System.Windows.Forms.Timer hintTimer = new() { Interval = 2500 };
    private readonly System.Windows.Forms.Timer saveTimer = new() { Interval = 400 };
    private readonly SubtitleLayout layout = new();
    private Point anchor, dragOrigin, dragAnchor;
    private string original = "", translation = "";
    private bool recording, hint, placing, dragging, ready;
    public event Action<string>? Notice;
    private float DpiScale => DeviceDpi / 96f;
    public SubtitleForm()
    {
        AutoScaleMode = AutoScaleMode.None; StartPosition = FormStartPosition.Manual;
        Text = "声笺字幕"; AccessibleName = "声笺字幕，方向键移动，右键调整样式";
        TopMost = true; ShowInTaskbar = false; FormBorderStyle = FormBorderStyle.None;
        ClientSize = new(360, 60); KeyPreview = true;
        anchor = preferences.AnchorX is int x && preferences.AnchorY is int y && Screen.AllScreens.Any(s => s.WorkingArea.Contains(x, y - 1))
            ? new(x, y) : DefaultAnchor();
        ContextMenuStrip = style; BuildMenu(); Theme.StyleMenu(style);
        hintTimer.Tick += (_, _) => { hintTimer.Stop(); hint = false; DrawCaption(); };
        saveTimer.Tick += (_, _) => SavePreferences();
        Shown += (_, _) => { ready = true; ShowHint(); };
        VisibleChanged += (_, _) => { if (Visible && ready) ShowHint(); else if (!Visible) { hintTimer.Stop(); SavePreferences(); } };
        Activated += (_, _) => { if (ready) ShowHint(); };
        Deactivate += (_, _) => { hintTimer.Stop(); hint = false; DrawCaption(); };
        DpiChanged += (_, _) => { layout.Clear(); DrawCaption(); };
        Microsoft.Win32.SystemEvents.DisplaySettingsChanged += DisplaysChanged;
    }
    protected override CreateParams CreateParams
    { get { var value = base.CreateParams; value.ExStyle |= 0x80000 | 0x80; return value; } } // WS_EX_LAYERED | WS_EX_TOOLWINDOW
    private static Point DefaultAnchor()
    {
        var area = (Screen.PrimaryScreen ?? Screen.AllScreens[0]).WorkingArea;
        return new(area.Left + area.Width / 2, area.Bottom - 70);
    }
    private void DisplaysChanged(object? sender, EventArgs e)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(() => { if (!IsDisposed) { if (!Screen.AllScreens.Any(s => s.WorkingArea.Contains(anchor.X, anchor.Y - 1))) anchor = DefaultAnchor(); layout.Clear(); DrawCaption(); } }); } catch (InvalidOperationException) { }
    }
    private void ShowHint() { hint = true; hintTimer.Stop(); hintTimer.Start(); DrawCaption(); }
    private void SavePreferences()
    {
        saveTimer.Stop();
        if (!ready) return;
        preferences = preferences with { AnchorX = anchor.X, AnchorY = anchor.Y };
        try { preferences.Save(); } catch (Exception ex) { Notice?.Invoke("字幕样式保存失败：" + ex.Message); }
    }
    private void Changed(SubtitlePreferences next)
    { preferences = next; layout.Clear(); DrawCaption(); saveTimer.Stop(); saveTimer.Start(); }
    private void BuildMenu()
    {
        void Options<T>(string label, IEnumerable<T> values, Func<T, string> title, Func<T, bool> selected, Action<T> select)
        {
            var group = new ToolStripMenuItem(label);
            foreach (var value in values)
            {
                var item = new ToolStripMenuItem(title(value));
                item.Click += (_, _) => select(value);
                style.Opening += (_, _) => item.Checked = selected(value);
                group.DropDownItems.Add(item);
            }
            style.Items.Add(group);
        }
        Options("字号", new[] { 18, 20, 24, 28, 32, 36, 40 }, n => n.ToString(), n => preferences.FontSize == n, n => Changed(preferences with { FontSize = n }));
        Options("最多显示行数", new[] { 1, 2, 3 }, n => n + " 行", n => preferences.MaxLines == n, n => Changed(preferences with { MaxLines = n }));
        Options("背景", new[] { true, false }, b => b ? "每行半透明底色" : "仅文字（带阴影）", b => preferences.Bars == b, b => Changed(preferences with { Bars = b }));
        Options("底色不透明度", new[] { 30, 50, 70, 90 }, n => n + "%", n => Math.Abs(preferences.Opacity - n / 100.0) < .01, n => Changed(preferences with { Opacity = n / 100.0 }));
        var opacity = style.Items[style.Items.Count - 1]; style.Opening += (_, _) => opacity.Enabled = preferences.Bars;
        var translated = new ToolStripMenuItem("显示译文");
        style.Opening += (_, _) => translated.Checked = preferences.ShowTranslation;
        translated.Click += (_, _) => Changed(preferences with { ShowTranslation = !preferences.ShowTranslation });
        style.Items.Add(translated); style.Items.Add(new ToolStripSeparator());
        style.Items.Add("回到默认位置", null, (_, _) => { anchor = DefaultAnchor(); ShowHint(); SavePreferences(); });
        style.Items.Add("关闭字幕", null, (_, _) => Hide());
    }
    public void UpdateText(string source, string target, bool listening = false)
    {
        if (original == source && translation == target && recording == listening) return;
        original = source; translation = target; recording = listening; DrawCaption();
    }
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        Keys key = keyData & Keys.KeyCode;
        if ((keyData & Keys.Control) == 0 && key is Keys.Left or Keys.Right or Keys.Up or Keys.Down)
        {
            int step = Math.Max(1, (int)Math.Round(((keyData & Keys.Shift) != 0 ? 40 : (keyData & Keys.Alt) != 0 ? 1 : 10) * DpiScale));
            anchor.Offset(key == Keys.Left ? -step : key == Keys.Right ? step : 0, key == Keys.Up ? -step : key == Keys.Down ? step : 0);
            ShowHint(); saveTimer.Stop(); saveTimer.Start(); return true;
        }
        if (keyData == Keys.Escape) { Hide(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }
    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left) return;
        Activate(); dragging = true; dragOrigin = Cursor.Position; dragAnchor = anchor; Capture = true; ShowHint();
    }
    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (!dragging) return;
        var cursor = Cursor.Position; anchor = new(dragAnchor.X + cursor.X - dragOrigin.X, dragAnchor.Y + cursor.Y - dragOrigin.Y);
        DrawCaption();
    }
    protected override void OnMouseUp(MouseEventArgs e)
    { base.OnMouseUp(e); if (e.Button == MouseButtons.Left && dragging) { dragging = false; Capture = false; ShowHint(); SavePreferences(); } }
    protected override void OnMouseCaptureChanged(EventArgs e)
    { base.OnMouseCaptureChanged(e); if (!Capture && dragging) { dragging = false; SavePreferences(); } }
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { }
    private void DrawCaption()
    {
        if (!ready || !Visible || IsDisposed || placing) return;
        placing = true;
        try
        {
            var area = Screen.FromPoint(new(anchor.X, anchor.Y - 1)).WorkingArea;
            float scale = DpiScale, size = preferences.FontSize * scale;
            int lineWidth = Math.Max(80, (int)Math.Min(area.Width - 48 * scale, size * 34));
            using var measure = new Bitmap(1, 1); using var graphics = Graphics.FromImage(measure);
            using var sourceFont = new Font("Microsoft YaHei UI", size, FontStyle.Regular, GraphicsUnit.Pixel);
            using var targetFont = new Font(sourceFont.FontFamily, size * .86f, FontStyle.Regular, GraphicsUnit.Pixel);
            using var hintFont = new Font(sourceFont.FontFamily, 11 * scale, FontStyle.Regular, GraphicsUnit.Pixel);
            var lines = new List<(string Text, Font Font, Color Color, bool Hint)>();
            if (hint) lines.Add(("方向键移动 · Shift 加速 · Alt 微调 · 右键调整样式", hintFont, Color.White, true));
            foreach (var line in layout.Tail(graphics, original, sourceFont, lineWidth, preferences.MaxLines)) lines.Add((line, sourceFont, Color.White, false));
            if (preferences.ShowTranslation)
                foreach (var line in layout.Tail(graphics, translation, targetFont, lineWidth, preferences.MaxLines)) lines.Add((line, targetFont, Color.FromArgb(166, 224, 255), false));
            if (!lines.Any(l => !l.Hint)) lines.Add((recording ? "正在聆听…" : "开始转写后，字幕将显示在这里", targetFont, Color.Silver, false));
            using var format = (StringFormat)StringFormat.GenericTypographic.Clone();
            format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
            var sizes = lines.Select(l => graphics.MeasureString(l.Text, l.Font, int.MaxValue, format)).ToArray();
            int padding = (int)Math.Ceiling(8 * scale), gap = (int)Math.Ceiling(4 * scale);
            int width = Math.Min(area.Width, (int)Math.Ceiling(sizes.Select((s, i) => s.Width + lines[i].Font.Size * .7f).Max()) + 2 * padding);
            int height = Math.Min(area.Height, (int)Math.Ceiling(sizes.Select((s, i) => Math.Max(s.Height, lines[i].Font.GetHeight(graphics)) + lines[i].Font.Size * .12f).Sum()) + gap * (lines.Count - 1) + 2 * padding);
            using var bitmap = new Bitmap(Math.Max(1, width), Math.Max(1, height), PixelFormat.Format32bppPArgb);
            using (var canvas = Graphics.FromImage(bitmap))
            {
                canvas.Clear(Color.FromArgb(1, 0, 0, 0)); // Keep gaps draggable without an opaque panel.
                canvas.SmoothingMode = SmoothingMode.AntiAlias; canvas.CompositingQuality = CompositingQuality.HighQuality;
                float y = padding;
                for (int i = 0; i < lines.Count; i++)
                {
                    var line = lines[i]; float px = line.Font.Size * .35f, py = line.Font.Size * .06f;
                    float h = Math.Max(sizes[i].Height, line.Font.GetHeight(canvas)), w = sizes[i].Width;
                    float x = (width - w) / 2;
                    if (preferences.Bars || line.Hint)
                    {
                        using var bar = Rounded(new(x - px, y, w + 2 * px, h + 2 * py), 4 * scale);
                        using var brush = new SolidBrush(Color.FromArgb((int)(255 * (line.Hint ? .6 : preferences.Opacity)), Color.Black));
                        canvas.FillPath(brush, bar);
                    }
                    using var glyphs = new GraphicsPath(); glyphs.AddString(line.Text, line.Font.FontFamily, (int)line.Font.Style, line.Font.Size, new PointF(x, y + py), format);
                    if (!preferences.Bars && !line.Hint)
                    {
                        using var soft = new Pen(Color.FromArgb(100, 0, 0, 0), 5 * scale) { LineJoin = LineJoin.Round };
                        using var shadow = new Pen(Color.FromArgb(235, 0, 0, 0), 2.5f * scale) { LineJoin = LineJoin.Round };
                        canvas.DrawPath(soft, glyphs); canvas.DrawPath(shadow, glyphs);
                    }
                    using var ink = new SolidBrush(line.Color); canvas.FillPath(ink, glyphs); y += h + 2 * py + gap;
                }
                if (hint)
                {
                    using var border = Rounded(new(.5f, .5f, width - 1f, height - 1f), 8 * scale);
                    using var pen = new Pen(Color.FromArgb(130, Color.White), scale) { DashStyle = DashStyle.Dash };
                    canvas.DrawPath(pen, border);
                }
            }
            var location = new Point(Math.Clamp(anchor.X - width / 2, area.Left, area.Right - width), Math.Clamp(anchor.Y - height, area.Top, area.Bottom - height));
            anchor = new(location.X + width / 2, location.Y + height);
            SetLayer(bitmap, location);
        }
        catch (Exception ex) { Notice?.Invoke("字幕显示失败：" + ex.Message); }
        finally { placing = false; }
    }
    private static GraphicsPath Rounded(RectangleF r, float radius)
    {
        var path = new GraphicsPath(); float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        path.AddArc(r.Left, r.Top, d, d, 180, 90); path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90); path.CloseFigure(); return path;
    }
    private void SetLayer(Bitmap bitmap, Point location)
    {
        IntPtr screen = GetDC(IntPtr.Zero), memory = IntPtr.Zero, image = IntPtr.Zero, old = IntPtr.Zero;
        try
        {
            memory = CreateCompatibleDC(screen); image = bitmap.GetHbitmap(Color.FromArgb(0)); old = SelectObject(memory, image);
            var size = bitmap.Size; var source = Point.Empty; var blend = new Blend { Alpha = 255, Format = 1 };
            if (!UpdateLayeredWindow(Handle, screen, ref location, ref size, memory, ref source, 0, ref blend, 2)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { if (old != IntPtr.Zero) SelectObject(memory, old); if (image != IntPtr.Zero) DeleteObject(image); if (memory != IntPtr.Zero) DeleteDC(memory); if (screen != IntPtr.Zero) ReleaseDC(IntPtr.Zero, screen); }
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { Microsoft.Win32.SystemEvents.DisplaySettingsChanged -= DisplaysChanged; SavePreferences(); hintTimer.Dispose(); saveTimer.Dispose(); style.Dispose(); }
        base.Dispose(disposing);
    }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct Blend { public byte Operation, Flags, Alpha, Format; }
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UpdateLayeredWindow(IntPtr window, IntPtr screen, ref Point destination, ref Size size, IntPtr source, ref Point origin, uint key, ref Blend blend, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr value);
}

internal sealed record SubtitlePreferences
{
    public int FontSize { get; init; } = 24;
    public int MaxLines { get; init; } = 2;
    public bool Bars { get; init; } = true;
    public double Opacity { get; init; } = .7;
    public bool ShowTranslation { get; init; } = true;
    public int? AnchorX { get; init; }
    public int? AnchorY { get; init; }
    private static string FilePath => Path.Combine(SettingsStore.Root, "subtitle-style.json");
    public static SubtitlePreferences Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var p = JsonSerializer.Deserialize<SubtitlePreferences>(File.ReadAllText(FilePath)) ?? new();
                return p with { FontSize = Math.Clamp(p.FontSize, 18, 40), MaxLines = Math.Clamp(p.MaxLines, 1, 3), Opacity = double.IsFinite(p.Opacity) ? Math.Clamp(p.Opacity, .3, 1) : .7 };
            }
#if FULL_BACKEND
            if (File.Exists(Path.Combine(SettingsStore.Root, "settings.json")))
            {
                var old = SettingsStore.Load();
                return new() { FontSize = Math.Clamp(old.SubtitleFontSize, 18, 40), ShowTranslation = old.SubtitleTranslation, Opacity = old.SubtitleOpacity < 1 ? Math.Clamp(old.SubtitleOpacity, .3, 1) : .7 };
            }
#endif
        }
        catch (Exception) { /* Invalid style preferences do not prevent opening subtitles. */ }
        return new();
    }
    public void Save()
    {
        Directory.CreateDirectory(SettingsStore.Root);
        File.WriteAllText(FilePath + ".tmp", JsonSerializer.Serialize(this)); File.Move(FilePath + ".tmp", FilePath, true);
    }
}

internal sealed class SubtitleLayout
{
    private readonly Dictionary<(string, float, int, int), string[]> cache = new();
    public void Clear() => cache.Clear();
    public string[] Tail(Graphics graphics, string raw, Font font, int width, int count)
    {
        string text = raw.Trim(); if (text.Length == 0) return [];
        var key = (text, font.Size, width, count); if (cache.TryGetValue(key, out var cached)) return cached;
        var lines = new Queue<string>();
        using var format = (StringFormat)StringFormat.GenericTypographic.Clone();
        format.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces | StringFormatFlags.NoWrap;
        foreach (var paragraph in text.Replace("\r", "").Split('\n'))
        {
            var elements = StringInfo.ParseCombiningCharacters(paragraph); int start = 0;
            while (start < elements.Length)
            {
                int low = start + 1, high = elements.Length;
                int End(int i) => i == elements.Length ? paragraph.Length : elements[i];
                // Binary-search grapheme boundaries, retaining CJK and emoji without splitting surrogate pairs.
                while (low < high)
                {
                    int mid = (low + high + 1) / 2;
                    if (graphics.MeasureString(paragraph[elements[start]..End(mid)], font, int.MaxValue, format).Width <= width) low = mid; else high = mid - 1;
                }
                int end = low;
                if (end < elements.Length)
                    for (int i = end - 1; i > start; i--) if (char.IsWhiteSpace(paragraph[elements[i]])) { end = i + 1; break; }
                string line = paragraph[elements[start]..End(end)].Trim();
                if (line.Length > 0) { lines.Enqueue(line); while (lines.Count > count) lines.Dequeue(); }
                start = end;
            }
        }
        var result = lines.ToArray(); if (cache.Count >= 16) cache.Clear(); cache[key] = result; return result;
    }
    public static string Join(string finished, string partial)
    {
        if (finished.Length == 0 || partial.Length == 0) return finished + partial;
        bool ascii(char c) => c <= 127 && !char.IsWhiteSpace(c);
        return finished + (ascii(finished[^1]) && ascii(partial[0]) ? " " : "") + partial;
    }
}
