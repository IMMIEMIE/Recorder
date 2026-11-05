using System.Drawing.Drawing2D;

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Recorder.Windows;

// One palette for both Windows clients. Sizes are logical pixels.
internal static class Theme
{
    private sealed record Palette(Color Ink, Color Muted, Color Paper, Color Surface, Color Footer,
        Color Accent, Color Line, Color Tint, Color Primary);
    private static readonly Palette light = new(Color.FromArgb(35, 35, 37), Color.FromArgb(128, 128, 132),
        Color.FromArgb(246, 246, 246), Color.White, Color.FromArgb(250, 250, 250),
        Color.FromArgb(36, 110, 97), Color.FromArgb(226, 226, 226), Color.FromArgb(233, 242, 240), Color.FromArgb(36, 110, 97));
    private static readonly Palette dark = new(Color.FromArgb(232, 234, 236), Color.FromArgb(166, 173, 180),
        Color.FromArgb(32, 35, 38), Color.FromArgb(24, 27, 30), Color.FromArgb(29, 32, 35),
        Color.FromArgb(120, 207, 187), Color.FromArgb(64, 70, 74), Color.FromArgb(36, 62, 57), Color.FromArgb(40, 113, 99));
    private static readonly List<Form> forms = new();
    private static readonly ConditionalWeakTable<Control, object> prepared = new();
    private static readonly ConditionalWeakTable<ContextMenuStrip, object> menus = new();
    private static string appearance = "system";
    private static bool initialized, changing;
    private static Form? dispatcher;
    private static int refreshQueued;
    public static bool IsDark { get; private set; }
    private static Palette Current => IsDark ? dark : light;
    public static Color Ink => Current.Ink;
    public static Color Muted => Current.Muted;
    public static Color Paper => Current.Paper;
    public static Color Surface => Current.Surface;
    public static Color Footer => Current.Footer;
    public static Color Accent => Current.Accent;
    public static Color Line => Current.Line;
    public static Color Tint => Current.Tint;
    public static Color Primary => Current.Primary;
    public static Color OnPrimary => Color.White;
    public static event Action? Changed;

    public static void Initialize(string value)
    {
        if (!initialized)
        {
            initialized = true;
            SystemEvents.UserPreferenceChanged += SystemPreferenceChanged;
            Application.ApplicationExit += (_, _) => Shutdown();
        }
        SetAppearance(value);
    }
    public static void Shutdown()
    {
        SystemEvents.UserPreferenceChanged -= SystemPreferenceChanged;
        dispatcher = null; initialized = false;
    }
    public static void SetAppearance(string value)
    {
        appearance = value is "light" or "dark" ? value : "system";
        Refresh();
    }
    private static bool SystemIsDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException) { return false; }
    }
    private static void SystemPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        // SystemEvents may run on a worker thread. Coalesce broadcasts and touch controls only on the UI thread.
        var target = dispatcher;
        if (target == null || target.IsDisposed || !target.IsHandleCreated || Interlocked.Exchange(ref refreshQueued, 1) != 0) return;
        try { target.BeginInvoke(() => { Interlocked.Exchange(ref refreshQueued, 0); if (!target.IsDisposed) Refresh(); }); }
        catch (InvalidOperationException) { Interlocked.Exchange(ref refreshQueued, 0); }
    }
    private static void Refresh()
    {
        if (changing) return;
        bool next = !SystemInformation.HighContrast && (appearance == "dark" || appearance == "system" && SystemIsDark());
        changing = true;
        try
        {
            bool changed = IsDark != next; IsDark = next;
#if NET10_0_OR_GREATER
            // Resolve System ourselves so broadcasts update an already running app as well as new windows.
            Application.SetColorMode(next ? SystemColorMode.Dark : SystemColorMode.Classic);
#endif
            if (!changed) return;
            foreach (var form in forms.ToArray())
            {
                if (form.IsDisposed) continue;
                form.SuspendLayout();
                try { Apply(form); ApplyTitleBar(form); }
                finally { form.ResumeLayout(true); form.Invalidate(true); }
            }
            Changed?.Invoke();
        }
        finally { changing = false; }
    }
    public static Font Body(float size = 10) => new("Microsoft YaHei UI", size);
    public static Label Label(string text, float size = 10, Color? color = null) => new()
    { Text = text, AutoSize = true, Font = Body(size), ForeColor = color ?? Ink, Margin = new(0, 6, 12, 6) };
    public static Button Button(string text, bool primary = false) => new MacButton
    {
        Primary = primary, Text = text, AutoSize = true, MinimumSize = new(58, 28), Padding = new(9, 2, 9, 2),
        FlatStyle = FlatStyle.Flat, BackColor = primary ? Primary : Surface,
        ForeColor = primary ? OnPrimary : Ink, Font = Body(9), Margin = new(0, 0, 6, 0),
        Cursor = Cursors.Hand, UseVisualStyleBackColor = false
    };
    public static void Style(Form form)
    {
        if (forms.Contains(form)) return;
        if (!initialized) Initialize(appearance);
        form.BackColor = Paper; form.ForeColor = Ink; form.Font = Body();
        form.StartPosition = FormStartPosition.CenterScreen; form.AutoScaleMode = AutoScaleMode.Dpi;
        form.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        forms.Add(form);
        form.HandleCreated += (_, _) => { dispatcher ??= form; ApplyTitleBar(form); };
        form.Load += (_, _) => Apply(form);
        form.Disposed += (_, _) => { forms.Remove(form); if (dispatcher == form) dispatcher = forms.FirstOrDefault(f => f.IsHandleCreated && !f.IsDisposed); };
        Apply(form);
    }
    private static Color PaletteColor(Color color, bool foreground)
    {
        // Named White and explicit RGB white are equivalent.
        int rgb = color.ToArgb();
        foreach (var p in new[] { light, dark })
        {
            if (rgb == p.Ink.ToArgb()) return Ink;
            if (rgb == p.Muted.ToArgb()) return Muted;
            if (rgb == p.Accent.ToArgb()) return Accent;
            if (rgb == p.Tint.ToArgb()) return Tint;
            if (rgb == p.Line.ToArgb()) return Line;
            if (rgb == p.Paper.ToArgb()) return Paper;
            if (rgb == p.Footer.ToArgb()) return Footer;
            if (!foreground && rgb == p.Surface.ToArgb()) return Surface;
        }
        if (color.IsSystemColor) return foreground ? Ink : Paper;
        return color;
    }
    private static void Apply(Control control)
    {
        if (control.IsDisposed) return;
        if (!prepared.TryGetValue(control, out _))
        {
            prepared.Add(control, new());
            control.ControlAdded += (_, e) => { if (e.Control != null) Apply(e.Control); };
        }
        // Rich transcript runs own their colors and preserve selection/scroll when reformatting.
        if (control is not TranscriptView)
        {
            var foreground = control is MacButton { Primary: true } ? OnPrimary : PaletteColor(control.ForeColor, true);
            if (control is RichTextBox rich && rich.ForeColor != foreground)
            {
                bool readOnly = rich.ReadOnly;
                try { rich.ReadOnly = false; rich.ForeColor = foreground; }
                finally { rich.ReadOnly = readOnly; }
            }
            else control.ForeColor = foreground;
        }
        if (control is MacButton { Primary: true } button)
        {
            // Keep the recording stop button red; change only the normal primary fill.
            if (button.BackColor.ToArgb() == light.Primary.ToArgb() || button.BackColor.ToArgb() == dark.Primary.ToArgb()) button.BackColor = Primary;
        }
        else if (control is TextBoxBase or ListBox or ComboBox or UpDownBase) control.BackColor = Surface;
        else control.BackColor = PaletteColor(control.BackColor, false);
        if (control is TabPage page) page.UseVisualStyleBackColor = false;
        if (control is ComboBox combo) combo.FlatStyle = FlatStyle.Flat;
        if (control is ButtonBase flat)
        {
            flat.FlatAppearance.BorderColor = flat is RadioButton { Checked: true, Appearance: Appearance.Button } ? Accent : Line;
            flat.FlatAppearance.MouseOverBackColor = Tint;
            flat.FlatAppearance.CheckedBackColor = Tint;
        }
        if (control.ContextMenuStrip is { } menu) StyleMenu(menu);
        foreach (Control child in control.Controls) Apply(child);
        control.Invalidate();
    }
    private static void ApplyTitleBar(Form form)
    {
        if (!form.IsHandleCreated || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 17763)) return;
        int enabled = IsDark ? 1 : 0;
        if (DwmSetWindowAttribute(form.Handle, 20, ref enabled, sizeof(int)) != 0)
            DwmSetWindowAttribute(form.Handle, 19, ref enabled, sizeof(int));
    }
    public static void StyleMenu(ContextMenuStrip menu)
    {
        if (!menus.TryGetValue(menu, out _))
        {
            menus.Add(menu, new());
            menu.Renderer = new ThemeMenuRenderer();
            menu.Opening += (_, _) => ApplyMenu(menu);
            Action changed = () => { if (!menu.IsDisposed) ApplyMenu(menu); };
            Changed += changed;
            menu.Disposed += (_, _) => Changed -= changed;
        }
        ApplyMenu(menu);
    }
    private static void ApplyMenu(ToolStrip menu)
    {
        menu.BackColor = Surface; menu.ForeColor = Ink;
        foreach (ToolStripItem item in menu.Items)
        {
            item.BackColor = Surface; item.ForeColor = Ink;
            if (item is ToolStripDropDownItem dropdown && dropdown.HasDropDownItems)
            {
                dropdown.DropDown.Renderer = menu.Renderer;
                ApplyMenu(dropdown.DropDown);
            }
        }
        menu.Invalidate();
    }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}

internal sealed class ThemeMenuRenderer : ToolStripProfessionalRenderer
{
    public ThemeMenuRenderer() : base(new ThemeMenuColors()) { RoundedEdges = false; }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    { e.TextColor = e.Item.Enabled ? Theme.Ink : Theme.Muted; base.OnRenderItemText(e); }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    { e.ArrowColor = e.Item?.Enabled == false ? Theme.Muted : Theme.Ink; base.OnRenderArrow(e); }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        if (e.Item is not ToolStripMenuItem { Checked: true }) { base.OnRenderItemCheck(e); return; }
        var r = e.ImageRectangle;
        using var pen = new Pen(e.Item.Enabled ? Theme.Accent : Theme.Muted, Math.Max(1.5f, r.Width / 8f));
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.DrawLines(pen, new PointF[] { new(r.Left + r.Width * .2f, r.Top + r.Height * .5f),
            new(r.Left + r.Width * .43f, r.Top + r.Height * .73f), new(r.Left + r.Width * .82f, r.Top + r.Height * .25f) });
    }
}
internal sealed class ThemeMenuColors : ProfessionalColorTable
{
    public ThemeMenuColors() { UseSystemColors = false; }
    public override Color ToolStripDropDownBackground => Theme.Surface;
    public override Color MenuBorder => Theme.Line;
    public override Color MenuItemBorder => Theme.Accent;
    public override Color MenuItemSelected => Theme.Tint;
    public override Color MenuItemSelectedGradientBegin => Theme.Tint;
    public override Color MenuItemSelectedGradientEnd => Theme.Tint;
    public override Color MenuItemPressedGradientBegin => Theme.Tint;
    public override Color MenuItemPressedGradientMiddle => Theme.Tint;
    public override Color MenuItemPressedGradientEnd => Theme.Tint;
    public override Color ImageMarginGradientBegin => Theme.Surface;
    public override Color ImageMarginGradientMiddle => Theme.Surface;
    public override Color ImageMarginGradientEnd => Theme.Surface;
    public override Color CheckBackground => Theme.Tint;
    public override Color CheckSelectedBackground => Theme.Tint;
    public override Color CheckPressedBackground => Theme.Tint;
    public override Color SeparatorDark => Theme.Line;
    public override Color SeparatorLight => Theme.Surface;
}

internal sealed class MacButton : Button
{
    public bool Primary { get; set; }
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
    public ListeningView() { DoubleBuffered = true; BackColor = Theme.Surface; }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        float scale = DeviceDpi / 96f, cx = Width / 2f, cy = 114 * scale;
        using var pen = new Pen(Theme.IsDark ? Theme.Accent : Color.FromArgb(135, 175, 167), 1.5f * scale);
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
