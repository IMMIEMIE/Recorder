namespace Recorder.Windows;

internal sealed class WorkflowSelector : UserControl
{
    private readonly RadioButton regular = CreateOption("常规转录 + 翻译");
    private readonly RadioButton live = CreateOption("LiveTranslate");
    private bool updating;
    public event Action<bool>? ModeChanged;
    public bool LiveMode
    {
        get => live.Checked;
        set
        {
            updating = true;
            regular.Checked = !value; live.Checked = value;
            UpdateColors(); updating = false;
        }
    }
    public WorkflowSelector(bool vertical = false)
    {
        AutoScaleMode = AutoScaleMode.Dpi;
        Size = vertical ? new(207, 78) : new(540, 40);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Margin = new(0), Padding = new(0), ColumnCount = vertical ? 1 : 2, RowCount = vertical ? 2 : 1 };
        for (int i = 0; i < layout.ColumnCount; i++) layout.ColumnStyles.Add(new(SizeType.Percent, 100f / layout.ColumnCount));
        for (int i = 0; i < layout.RowCount; i++) layout.RowStyles.Add(new(SizeType.Percent, 100f / layout.RowCount));
        layout.Controls.Add(regular, 0, 0); layout.Controls.Add(live, vertical ? 0 : 1, vertical ? 1 : 0); Controls.Add(layout);
        regular.CheckedChanged += (_, _) => Changed(regular);
        live.CheckedChanged += (_, _) => Changed(live);
        Theme.Changed += UpdateColors;
        LiveMode = false;
    }
    private static RadioButton CreateOption(string text)
    {
        var option = new RadioButton { Text = text, AccessibleName = text, Appearance = Appearance.Button, FlatStyle = FlatStyle.Flat,
            TextAlign = ContentAlignment.MiddleCenter, Dock = DockStyle.Fill, Margin = new(0, 0, 4, 4), Font = Theme.Body(9), Cursor = Cursors.Hand, UseVisualStyleBackColor = false };
        option.FlatAppearance.BorderColor = Theme.Line;
        option.FlatAppearance.CheckedBackColor = Theme.Tint;
        return option;
    }
    private void Changed(RadioButton option)
    {
        UpdateColors();
        if (!updating && option.Checked) ModeChanged?.Invoke(live.Checked);
    }
    private void UpdateColors()
    {
        foreach (var option in new[] { regular, live })
        {
            option.BackColor = option.Checked ? Theme.Tint : Theme.Surface;
            option.ForeColor = option.Checked ? Theme.Accent : Theme.Ink;
            option.FlatAppearance.BorderColor = option.Checked ? Theme.Accent : Theme.Line;
            option.FlatAppearance.CheckedBackColor = Theme.Tint;
        }
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) Theme.Changed -= UpdateColors;
        base.Dispose(disposing);
    }
}
