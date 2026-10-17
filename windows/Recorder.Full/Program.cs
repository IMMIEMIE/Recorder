namespace Recorder.Windows;
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        try
        {
            if (args.Length > 0 && args[0] == "--verify-file") return Task.Run(() => VerifyAsync(args)).GetAwaiter().GetResult();
            if (args.Length > 0 && args[0] == "--smoke")
            {
                Directory.CreateDirectory(args[1]);
                using var main = new MainForm(SettingsStore.Load()); main.Show(); Application.DoEvents();
                using var mainImage = new Bitmap(main.Width, main.Height); main.DrawToBitmap(mainImage, main.ClientRectangle); mainImage.Save(Path.Combine(args[1], "main.png"));
                using var settings = new SettingsForm(SettingsStore.Load()); settings.Show(); Application.DoEvents();
                using var second = new Bitmap(settings.Width, settings.Height); settings.DrawToBitmap(second, settings.ClientRectangle); second.Save(Path.Combine(args[1], "settings.png"));
                settings.Close(); main.Close(); return 0;
            }
            using var mutex = new Mutex(true, "Local\\Shengjian.Windows.x64", out bool first);
            if (!first) return 0;
            Application.Run(new MainForm(SettingsStore.Load())); return 0;
        }
        catch (Exception ex) { if (args.Length > 0) { Directory.CreateDirectory(SettingsStore.Root); File.WriteAllText(Path.Combine(SettingsStore.Root, "verification-error.txt"), ex.ToString()); } else MessageBox.Show(ex.Message, "声笺", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
        finally { DesktopBackend.Shared.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
    }
    private static async Task<int> VerifyAsync(string[] args)
    {
        var config = SettingsStore.Load() with { UseLocalFile = true, ModelPath = args[2], AsrProjector = args.Length > 3 ? args[3] : "", Device = "cuda", Translation = args.Length > 5, TranslatorPath = args.Length > 5 ? args[5] : "", TargetLanguage = "en" };
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
