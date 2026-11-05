namespace Recorder.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.ThreadException += (_, e) => MessageBox.Show(e.Exception.Message, "声笺", MessageBoxButtons.OK, MessageBoxIcon.Error);
        using var mutex = new Mutex(true, "Local\\Shengjian.Windows.x86", out var owns);
        if (!owns) { MessageBox.Show("声笺已在运行，请从任务栏或托盘打开。", "声笺"); return; }
        try { Application.Run(new MainForm(SettingsStore.Load())); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "声笺启动失败", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
