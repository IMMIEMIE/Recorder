using System.Runtime.InteropServices;

namespace Recorder.Windows;

/// <summary>Replace only changed rows; keep the reader's selection and viewport across streaming updates.</summary>
internal sealed class TranscriptView : RichTextBox
{
    private readonly Font sourceFont = Theme.Body(12.75f), translationFont = Theme.Body(11.25f);
    private int textColumn, timestampDigits, columnDpi;
    private readonly List<(TranscriptRow Row, int Start, int Length)> rendered = new();
    private bool updating, followQueued;
    private (Point Scroll, int SelectionStart, int SelectionLength)? recreatedView;
    public bool Following { get; private set; } = true;
    public bool NewBelow { get; private set; }
    internal int LastRenderedRows { get; private set; }
    public event Action? FollowChanged;
    public TranscriptView()
    {
        Dock = DockStyle.Fill; ReadOnly = true; BorderStyle = BorderStyle.None;
        BackColor = Theme.Surface; ForeColor = Theme.Ink; Font = sourceFont; DetectUrls = false; HideSelection = false;
        Theme.Changed += ApplyTheme;
    }
    private void ApplyTheme()
    {
        if (IsDisposed) return;
        BackColor = Theme.Surface;
        if (rendered.Count == 0) { ForeColor = Theme.Ink; return; }
        // RichEdit stores foreground colors in each text run. Reapply those runs without
        // treating an appearance change as new transcript content or moving the reader.
        RenderCore(rendered.Select(item => item.Row).ToArray(), recolorOnly: true);
    }
    protected override void OnHandleCreated(EventArgs e)
    {
        bool wasUpdating = updating; updating = true;
        try
        {
            base.OnHandleCreated(e);
            // RichEdit is a transcript viewer: never emit editing/limit warning sounds.
            // EM_SETEDITSTYLE, SES_ALLOWBEEPS | SES_BEEPONMAXTEXT (Windows SDK Richedit.h).
            SendMessage(Handle, 0x400 + 204, IntPtr.Zero, (IntPtr)(256 | 2));
            if (recreatedView is { } view)
            {
                recreatedView = null;
                int start = Math.Min(view.SelectionStart, TextLength);
                Select(start, Math.Min(view.SelectionLength, TextLength - start));
                if (!Following) ScrollPosition = view.Scroll;
            }
        }
        finally { updating = wasUpdating; }
        QueueFollowLatest();
    }
    internal Point ScrollPosition
    {
        get { var point = Point.Empty; if (IsHandleCreated) SendMessage(Handle, 0x4DD, IntPtr.Zero, ref point); return point; }
        set { if (IsHandleCreated) SendMessage(Handle, 0x4DE, IntPtr.Zero, ref value); }
    }
    private int VerticalPosition()
    {
        var info = new ScrollInfo { Size = (uint)Marshal.SizeOf<ScrollInfo>(), Mask = 4 };
        return IsHandleCreated && GetScrollInfo(Handle, 1, ref info) ? info.Position : 0;
    }
    private void PauseFollowing()
    {
        if (!Following) return;
        Following = false; FollowChanged?.Invoke();
    }
    protected override void WndProc(ref Message m)
    {
        // Follow is an explicit mode, never inferred from being near the bottom.
        // Downward scrolling in browse mode must not silently turn it back on.
        bool userScroll = !updating && Following && m.Msg is 0x115 or 0x20A or 0x100;
        int before = userScroll ? VerticalPosition() : 0;
        if (userScroll)
        {
            int request = (int)((long)m.WParam & 0xffff);
            bool wheelUp = m.Msg == 0x20A && (short)((long)m.WParam >> 16) > 0;
            bool scrollUp = m.Msg == 0x115 && request is 0 or 2 or 6; // line/page/top
            bool keyUp = m.Msg == 0x100 && (Keys)request is Keys.Up or Keys.PageUp or Keys.Home;
            if (wheelUp || scrollUp || keyUp) PauseFollowing();
        }
        base.WndProc(ref m);
        // Also covers dragging the scroll thumb upward; use the full 32-bit position.
        if (userScroll && Following && VerticalPosition() < before) PauseFollowing();
    }
    public void JumpToLatest()
    {
        Following = true; NewBelow = false;
        ScrollToLatest(); QueueFollowLatest(); FollowChanged?.Invoke();
    }
    private void ScrollToLatest()
    {
        if (!Following || !IsHandleCreated || IsDisposed) return;
        bool wasUpdating = updating; updating = true;
        // Move the viewport itself. Moving/restoring the caret can scroll back to an old selection.
        try { SendMessage(Handle, 0x115, (IntPtr)7, IntPtr.Zero); } // WM_VSCROLL / SB_BOTTOM
        finally { updating = wasUpdating; }
    }
    private void QueueFollowLatest()
    {
        if (!Following || followQueued || !IsHandleCreated || IsDisposed) return;
        followQueued = true;
        try
        {
            BeginInvoke(() =>
            {
                followQueued = false;
                // A user scroll between scheduling and execution cancels the follow.
                if (Following && !updating) ScrollToLatest();
            });
        }
        catch (InvalidOperationException) { followQueued = false; }
    }
    protected override void OnSizeChanged(EventArgs e)
    {
        base.OnSizeChanged(e);
        // Partial text, wrapping and window resizing can change the viewport after Render returns.
        QueueFollowLatest();
    }
    protected override void OnHandleDestroyed(EventArgs e)
    {
        // Native color mode changes can rebuild the RichEdit handle before Theme.Changed.
        // Preserve the reader's position before that rebuild as well as during recoloring.
        if (RecreatingHandle && IsHandleCreated && !IsDisposed)
            recreatedView = (ScrollPosition, SelectionStart, SelectionLength);
        bool wasUpdating = updating; updating = true; followQueued = false;
        try { base.OnHandleDestroyed(e); }
        finally { updating = wasUpdating; }
    }
    public void NotifyNewContent()
    {
        if (Following) QueueFollowLatest();
        else { NewBelow = true; FollowChanged?.Invoke(); }
    }
    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == (Keys.Control | Keys.Down)) { JumpToLatest(); return true; }
        if ((keyData & Keys.KeyCode) is Keys.Up or Keys.PageUp or Keys.Home) PauseFollowing();
        return base.ProcessCmdKey(ref msg, keyData);
    }
    public void Render(IReadOnlyList<TranscriptRow> rows) => RenderCore(rows, recolorOnly: false);
    private void RenderCore(IReadOnlyList<TranscriptRow> rows, bool recolorOnly)
    {
        int digits = Math.Max(2, ((int)(rows.Count == 0 ? 0 : rows.Max(row => row.Seconds)) / 60).ToString().Length);
        bool layoutChanged = recolorOnly;
        if (digits != timestampDigits || columnDpi != DeviceDpi)
        {
            using var graphics = CreateGraphics();
            int width = TextRenderer.MeasureText(graphics, new string('8', digits) + ":88", sourceFont, Size.Empty,
                TextFormatFlags.NoPadding | TextFormatFlags.SingleLine).Width;
            int column = Math.Max(LogicalToDeviceUnits(72), width + LogicalToDeviceUnits(16));
            layoutChanged |= column != textColumn;
            textColumn = column; timestampDigits = digits; columnDpi = DeviceDpi;
        }
        int prefix = 0, suffix = 0;
        while (!layoutChanged && prefix < rows.Count && prefix < rendered.Count && rows[prefix] == rendered[prefix].Row) prefix++;
        while (!layoutChanged && suffix < rows.Count - prefix && suffix < rendered.Count - prefix && rows[rows.Count - 1 - suffix] == rendered[rendered.Count - 1 - suffix].Row) suffix++;
        LastRenderedRows = rows.Count - prefix - suffix;
        if (prefix == rows.Count && prefix == rendered.Count) return;
        int replaceStart = prefix < rendered.Count ? rendered[prefix].Start : TextLength;
        int replaceEnd = suffix > 0 ? rendered[rendered.Count - suffix].Start : TextLength;
        int selectionStart = SelectionStart, selectionEnd = selectionStart + SelectionLength;
        Point scroll = ScrollPosition;
        int anchorIndex = GetCharIndexFromPosition(new Point(1, 1));
        int anchorY = GetPositionFromCharIndex(anchorIndex).Y;
        bool follow = Following;
        bool wasReadOnly = ReadOnly;
        updating = true;
        SendMessage(Handle, 0xB, IntPtr.Zero, IntPtr.Zero);
        try
        {
            // Paragraph formatting must not be applied as an edit to a read-only control.
            // Render is synchronous on the UI thread; restore read-only before returning to user input.
            ReadOnly = false;
            if (recolorOnly) ForeColor = Theme.Ink;
            Select(replaceStart, replaceEnd - replaceStart); SelectedText = "";
            var replacements = new List<(TranscriptRow Row, int Start, int Length)>();
            for (int i = prefix; i < rows.Count - suffix; i++)
            {
                var row = rows[i]; int start = SelectionStart;
                // First line starts in the timestamp column; wrapped lines start at the body tab stop.
                SelectionIndent = 0; SelectionHangingIndent = textColumn; SelectionTabs = [textColumn];
                SelectionCharOffset = 0; SelectionFont = sourceFont; SelectionColor = Theme.Muted;
                SelectedText = $"{(int)row.Seconds / 60:00}:{(int)row.Seconds % 60:00}\t";
                SelectionColor = Theme.Ink;
                var paragraphs = row.Text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
                for (int p = 0; p < paragraphs.Length; p++)
                {
                    // Explicit newlines also belong to the body column, without another timestamp.
                    if (p > 0) { SelectionIndent = textColumn; SelectionHangingIndent = 0; }
                    SelectedText = paragraphs[p] + "\n";
                }
                if (!string.IsNullOrWhiteSpace(row.Translation))
                {
                    SelectionIndent = textColumn; SelectionHangingIndent = 0; SelectionFont = translationFont; SelectionColor = Theme.Muted;
                    SelectedText = row.Translation + "\n";
                }
                SelectedText = "\n";
                replacements.Add((row, start, SelectionStart - start));
            }
            int newEnd = SelectionStart, delta = newEnd - replaceEnd;
            rendered.RemoveRange(prefix, rendered.Count - prefix - suffix);
            rendered.InsertRange(prefix, replacements);
            for (int i = prefix + replacements.Count; i < rendered.Count; i++)
            { var row = rendered[i]; rendered[i] = (row.Row, row.Start + delta, row.Length); }
            int Map(int index) => Math.Clamp(index <= replaceStart ? index : index >= replaceEnd ? index + delta : replaceStart + Math.Min(index - replaceStart, newEnd - replaceStart), 0, TextLength);
            Select(Map(selectionStart), Math.Max(0, Map(selectionEnd) - Map(selectionStart)));
            // Use document coordinates: native edits/selection restoration may already have moved the viewport.
            // Keep the same visible character at the same screen height while browsing history.
            if (!follow && TextLength > 0)
                scroll.Y = Math.Max(0, ScrollPosition.Y + GetPositionFromCharIndex(Map(anchorIndex)).Y - anchorY);
            if (!recolorOnly)
            {
                if (rows.Count == 0) { Following = true; NewBelow = false; }
                else NewBelow = !follow;
            }
        }
        finally
        {
            ReadOnly = wasReadOnly;
            SendMessage(Handle, 0xB, (IntPtr)1, IntPtr.Zero);
            if (Following) ScrollToLatest(); else ScrollPosition = scroll;
            Invalidate(); updating = false;
        }
        QueueFollowLatest();
        FollowChanged?.Invoke();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) Theme.Changed -= ApplyTheme;
        base.Dispose(disposing);
        if (disposing) { sourceFont.Dispose(); translationFont.Dispose(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct ScrollInfo { public uint Size, Mask; public int Min, Max; public uint Page; public int Position, Track; }
    [DllImport("user32.dll")] private static extern bool GetScrollInfo(IntPtr window, int bar, ref ScrollInfo info);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, ref Point point);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
}
