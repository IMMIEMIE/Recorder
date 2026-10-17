namespace Recorder.Windows;

internal static class Theme
{
    public static readonly Color Ink = Color.FromArgb(29, 48, 65);
    public static readonly Color Muted = Color.FromArgb(94, 113, 127);
    public static readonly Color Paper = Color.FromArgb(241, 246, 249);
    public static readonly Color Accent = Color.FromArgb(25, 100, 151);
    public static readonly Color Line = Color.FromArgb(213, 226, 234);
    public static Font Body(float size = 10) => new("Microsoft YaHei UI", size);
    public static Label Label(string text, float size = 10, Color? color = null) => new()
    { Text = text, AutoSize = true, Font = Body(size), ForeColor = color ?? Ink, Margin = new(0, 6, 12, 6) };
    public static Button Button(string text, bool primary = false) => new()
    {
        Text = text, AutoSize = true, MinimumSize = new(90, 36), Padding = new(10, 3, 10, 3),
        FlatStyle = FlatStyle.Flat, BackColor = primary ? Accent : Color.White,
        ForeColor = primary ? Color.White : Ink, Font = Body(), Margin = new(0, 0, 10, 0),
        Cursor = Cursors.Hand
    };
    public static void Style(Form form)
    {
        form.BackColor = Paper; form.ForeColor = Ink; form.Font = Body();
        form.StartPosition = FormStartPosition.CenterScreen; form.AutoScaleMode = AutoScaleMode.Dpi;
        form.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
    }
}
