namespace Recorder.Backend;

/// <summary>
/// Local, append-only diagnostics for crashes and native worker exits. Callers pass exceptions and exit details only:
/// never audio, transcripts, translations or API keys (those are never persisted).
/// </summary>
public static class DiagnosticLog
{
    private static readonly object gate = new();
    private static string? directory;
    public static string? Directory => directory;
    public static void Configure(string root) { lock (gate) directory = Path.Combine(Path.GetFullPath(root), "logs"); }
    public static void Write(string area, Exception error) => Write(area, error.ToString());
    public static void Write(string area, string detail)
    {
        try
        {
            lock (gate)
            {
                if (directory == null) return;
                System.IO.Directory.CreateDirectory(directory);
                var path = Path.Combine(directory, $"shengjian-{DateTime.Now:yyyyMMdd}.log");
                if (File.Exists(path) && new FileInfo(path).Length > 4 << 20) return;
                var version = typeof(DiagnosticLog).Assembly.GetName().Version;
                File.AppendAllText(path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {area} v{version} pid {Environment.ProcessId}{Environment.NewLine}{detail}{Environment.NewLine}{Environment.NewLine}");
                foreach (var old in new DirectoryInfo(directory).GetFiles("shengjian-*.log").OrderByDescending(f => f.Name).Skip(14)) old.Delete();
            }
        }
        catch { /* Diagnostics must never become a second failure. */ }
    }
}
