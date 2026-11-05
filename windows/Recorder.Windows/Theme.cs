using System.Drawing.Drawing2D;

namespace Recorder.Windows;

// Values follow MainView in RecorderApp.swift (SwiftUI sizes are logical pixels).
internal static class Theme
{
    public static readonly Color Ink = Color.FromArgb(35, 35, 37);
    public static readonly Color Muted = Color.FromArgb(128, 128, 132);
    public static readonly Color Paper = Color.FromArgb(246, 246, 246);
    public static readonly Color Accent = Color.FromArgb(36, 110, 97);
    public static readonly Color Line = Color.FromArgb(226, 226, 226);
    public static readonly Color Tint = Color.FromArgb(233, 242, 240);
    public static Font Body(float size = 10) => new("Microsoft YaHei UI", size);
    public static Label Label(string text, float size = 10, Color? color = null) => new()
    { Text = text, AutoSize = true, Font = Body(size), ForeColor = color ?? Ink, Margin = new(0, 6, 12, 6) };
    public static Button Button(string text, bool primary = false) => new MacButton
    {
        Text = text, AutoSize = true, MinimumSize = new(58, 28), Padding = new(9, 2, 9, 2),
        FlatStyle = FlatStyle.Flat, BackColor = primary ? Accent : Color.White,
        ForeColor = primary ? Color.White : Ink, Font = Body(9), Margin = new(0, 0, 6, 0),
        Cursor = Cursors.Hand, UseVisualStyleBackColor = false
    };
    public static void Style(Form form)
    {
        form.BackColor = Paper; form.ForeColor = Ink; form.Font = Body();
        form.StartPosition = FormStartPosition.CenterScreen; form.AutoScaleMode = AutoScaleMode.Dpi;
        form.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
    }
}

internal sealed class MacButton : Button
{
    public MacButton() { FlatAppearance.BorderSize = 0; DoubleBuffered = true; }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(Parent?.BackColor ?? Theme.Paper);
        var rect = new RectangleF(0.5f, 0.5f, Width - 1, Height - 1);
        float radius = 6 * DeviceDpi / 96f;
        using var path = new GraphicsPath();
        path.AddArc(rect.Left, rect.Top, radius * 2, radius * 2, 180, 90);
        path.AddArc(rect.Right - radius * 2, rect.Top, radius * 2, radius * 2, 270, 90);
        path.AddArc(rect.Right - radius * 2, rect.Bottom - radius * 2, radius * 2, radius * 2, 0, 90);
        path.AddArc(rect.Left, rect.Bottom - radius * 2, radius * 2, radius * 2, 90, 90); path.CloseFigure();
        bool hover = Enabled && ClientRectangle.Contains(PointToClient(Cursor.Position));
        using var fill = new SolidBrush(!Enabled ? Theme.Paper : hover ? ControlPaint.Light(BackColor, .12f) : BackColor);
        using var border = new Pen(Focused ? Theme.Accent : Theme.Line);
        e.Graphics.FillPath(fill, path); e.Graphics.DrawPath(border, path);
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Enabled ? ForeColor : Theme.Muted,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(ClientRectangle, -4, -4));
    }
    protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); Invalidate(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); Invalidate(); }
}

internal sealed class ListeningView : Control
{
    public bool Listening { get; set; }
    public ListeningView() { DoubleBuffered = true; BackColor = Color.White; }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float scale = DeviceDpi / 96f, cx = Width / 2f, cy = 114 * scale;
        using var pen = new Pen(Color.FromArgb(135, 175, 167), 1.5f * scale);
        e.Graphics.DrawEllipse(pen, cx - 30 * scale, cy - 30 * scale, 60 * scale, 60 * scale);
        for (int i = -3; i <= 3; i++) {
            float h = new[] { 6, 12, 19, 11, 19, 12, 6 }[i + 3] * scale;
            e.Graphics.DrawLine(pen, cx + i * 6 * scale, cy - h / 2, cx + i * 6 * scale, cy + h / 2);
        }
        using var font = Theme.Body(11.25f);
        TextRenderer.DrawText(e.Graphics, Listening ? "正在聆听…" : "点击开始转写", font,
            new Rectangle(0, (int)(cy + 48 * scale), Width, (int)(30 * scale)), Theme.Muted, TextFormatFlags.HorizontalCenter);
    }
}

internal sealed class BrandView : Control
{
    public BrandView() { DoubleBuffered = true; AccessibleName = "声笺"; }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float scale = DeviceDpi / 96f;
        using var pen = new Pen(Theme.Accent, 2 * scale) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        for (int i = 0; i < 7; i++) {
            float h = new[] { 7, 16, 27, 13, 22, 14, 6 }[i] * scale;
            e.Graphics.DrawLine(pen, (2 + i * 4) * scale, (Height - h) / 2, (2 + i * 4) * scale, (Height + h) / 2);
        }
        using var font = new Font("Microsoft YaHei UI", 16.5f, FontStyle.Bold);
        TextRenderer.DrawText(e.Graphics, "声笺", font, new Rectangle((int)(40 * scale), 0, Width - (int)(40 * scale), Height), Theme.Ink, TextFormatFlags.VerticalCenter);
    }
}
