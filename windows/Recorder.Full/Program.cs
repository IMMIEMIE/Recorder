namespace Recorder.Windows;
internal static class Program
{
    private static int reporting;
    [STAThread]
    private static int Main(string[] args)
    {
        // Every failure leaves a local log (exceptions and native exit codes only, never audio or text) instead of a silent exit.
        Recorder.Backend.DiagnosticLog.Configure(SettingsStore.Root);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => ReportUiError(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Recorder.Backend.DiagnosticLog.Write("fatal", e.ExceptionObject.ToString() ?? "unknown");
        TaskScheduler.UnobservedTaskException += (_, e) => { Recorder.Backend.DiagnosticLog.Write("unobserved-task", e.Exception); e.SetObserved(); };
        ApplicationConfiguration.Initialize();
        try
        {
            if (!Environment.Is64BitProcess || System.Runtime.InteropServices.RuntimeInformation.OSArchitecture != System.Runtime.InteropServices.Architecture.X64 || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) throw new PlatformNotSupportedException("完整版需要 Windows 11 x64；旧版 Windows 请使用 x86 兼容版。");
            if (args.Length > 0) { var error = Path.Combine(SettingsStore.Root, "verification-error.txt"); if (File.Exists(error)) File.Delete(error); }
            if (args.Length > 0 && args[0] == "--verify-file") return Task.Run(() => VerifyAsync(args)).GetAwaiter().GetResult();
            if (args.Length > 0 && args[0] == "--smoke")
            {
                Directory.CreateDirectory(args[1]);
                using var main = new MainForm(SettingsStore.Load()); main.Show(); Application.DoEvents();
                using var mainImage = new Bitmap(main.Width, main.Height); main.DrawToBitmap(mainImage, new Rectangle(Point.Empty, main.Size)); mainImage.Save(Path.Combine(args[1], "main.png"));
                using var settings = new SettingsForm(SettingsStore.Load()); settings.Show(); Application.DoEvents();
                using var second = new Bitmap(settings.Width, settings.Height); settings.DrawToBitmap(second, new Rectangle(Point.Empty, settings.Size)); second.Save(Path.Combine(args[1], "settings.png"));
                settings.Close(); main.Close(); return 0;
            }
            using var mutex = new Mutex(true, "Local\\Shengjian.Windows.x64", out bool first);
            if (!first) return 0;
            Application.Run(new MainForm(SettingsStore.Load())); return 0;
        }
        catch (Exception ex) { if (args.Length > 0) { Directory.CreateDirectory(SettingsStore.Root); File.WriteAllText(Path.Combine(SettingsStore.Root, "verification-error.txt"), ex.ToString()); } else MessageBox.Show(ex.Message, "声笺", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
        finally { DesktopBackend.ShutdownAsync().AsTask().GetAwaiter().GetResult(); }
    }
    private static void ReportUiError(Exception error)
    {
        Recorder.Backend.DiagnosticLog.Write("ui", error);
        if (Interlocked.Exchange(ref reporting, 1) != 0) return;
        try { MessageBox.Show("界面操作出现异常，已写入日志，可以继续使用；如反复出现请附上日志反馈。\n\n" + error.Message + "\n\n日志目录：" + Recorder.Backend.DiagnosticLog.Directory, "声笺", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        finally { Volatile.Write(ref reporting, 0); }
    }
    private static async Task<int> VerifyAsync(string[] args)
    {
        if (args.Length < 5) throw new ArgumentException("Usage: --verify-file audio model projector output [translator] [--device cpu|cuda|auto] [--engine qwen|whisper] [--translator-engine qwen3|hunyuan]");
        string device = "auto", engine = "qwen", translatorEngine = "qwen3", translatorPath = ""; int index = 5;
        if (index < args.Length && !args[index].StartsWith("--")) translatorPath = args[index++];
        while (index < args.Length) { string option = args[index++]; if (index == args.Length) throw new ArgumentException("Missing option value."); string value = args[index++]; switch (option) { case "--device": device = value; break; case "--engine": engine = value; break; case "--translator-engine": translatorEngine = value; break; default: throw new ArgumentException("Unknown verification option."); } }
        var config = SettingsStore.Load() with { UseLocalFile = true, ModelPath = args[2], AsrProjector = args[3], AsrEngine = engine, Device = device, Translation = translatorPath.Length > 0, TranslatorPath = translatorPath, TranslatorEngine = translatorEngine, TargetLanguage = "en" };
        var translated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void Translation(System.Text.Json.Nodes.JsonObject message) { if ((string?)message["type"] == "translation" && (bool?)message["done"] == true) translated.TrySetResult(); }
        DesktopBackend.Shared.Event += Translation;
        await using var session = new RecordingSession(config); var result = new List<TranscriptRow>();
        session.Row += row => { lock (result) { int index = result.FindIndex(r => r.Id == row.Id); if (index < 0) result.Add(row); else result[index] = row; } };
        await session.StartAsync(2, 0, args[1]); await session.Completion.WaitAsync(TimeSpan.FromMinutes(3));
        if (config.Translation) await translated.Task.WaitAsync(TimeSpan.FromMinutes(1));
        DesktopBackend.Shared.Event -= Translation;
        await File.WriteAllTextAsync(args.Length > 4 ? args[4] : "verification-transcript.txt", TranscriptExport.Text(result));
        return result.Count > 0 ? 0 : 2;
    }
}
