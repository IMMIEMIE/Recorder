using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Recorder.Backend;
namespace Recorder.Windows;

public sealed partial class LiveTranscript
{
    public IReadOnlyList<LiveRowState> Snapshot() => rows.Select(r => new LiveRowState(r.Key, r.Value.Source.Done, r.Value.Source.Text, r.Value.Outputs.ToArray(), r.Value.Outputs.Count > 0 && r.Value.Outputs.All(o => outputs.TryGetValue(o, out var p) && p.Done))).ToArray();
}
internal static class LiveHistory
{
    public static readonly LiveReplayCache Cache = new();
}
public sealed class LivePlayer : IDisposable
{
    private readonly object gate = new();
    private WasapiOut? player;
    private BufferedWaveProvider? buffer;
    private bool failed;
    private int generation;
    public event Action<string>? Failure;
    public void Start(float volume)
    {
        lock (gate)
        {
            Stop(); failed = false;
            buffer = new BufferedWaveProvider(new WaveFormat(24000, 16, 1)) { BufferDuration = TimeSpan.FromSeconds(30), DiscardOnBufferOverflow = false, ReadFully = true };
            player = new WasapiOut(AudioClientShareMode.Shared, true, 100); player.Init(buffer); player.Volume = Math.Clamp(volume, 0, 1);
            var current = player;
            player.PlaybackStopped += (_, e) => { if (e.Exception != null && ReferenceEquals(current, player)) Fail("译音输出设备不可用，字幕继续更新。"); }; player.Play();
        }
    }
    public void Append(byte[] pcm)
    {
        lock (gate)
        {
            if (failed || buffer == null) return;
            if ((pcm.Length & 1) != 0 || buffer.BufferedBytes + pcm.Length > 24000 * 2 * 30) { Fail("译音播放积压超过 30 秒，字幕继续更新。"); return; }
            try { buffer.AddSamples(pcm, 0, pcm.Length); } catch { Fail("译音缓冲失败，字幕继续更新。"); }
        }
    }
    private void Fail(string message) { failed = true; int token = Volatile.Read(ref generation); Failure?.Invoke(message); _ = Task.Run(() => { lock (gate) if (generation == token) Stop(); }); }
    public async Task FinishAsync(CancellationToken ct)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            lock (gate) if (failed || buffer == null || buffer.BufferedBytes == 0) break;
            if (started.Elapsed > TimeSpan.FromSeconds(32)) { Fail("译音播放超时。"); break; }
            await Task.Delay(40, ct);
        }
        await Task.Delay(150, ct); Stop();
    }
    public void Stop() { lock (gate) { generation++; var current = player; player = null; buffer = null; current?.Stop(); current?.Dispose(); } }
    public void Dispose() => Stop();
}
public sealed class ProcessLoopbackInput : IDisposable
{
    // Activation callbacks may outlive a timed-out start. Keep the code module
    // loaded for the app lifetime; capture handles/threads are still released.
    private static readonly Lazy<IntPtr> module = new(() => NativeLibrary.Load(Path.Combine(AppContext.BaseDirectory, "runtime/cpu/recorder-audio.dll")));
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Audio(IntPtr bytes, int count, int error, IntPtr user);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr StartCapture(uint process, Audio callback, IntPtr user, out int error);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void StopCapture(IntPtr capture);
    private readonly IntPtr library;
    private readonly Audio callback;
    private readonly StartCapture start;
    private readonly StopCapture stop;
    private IntPtr capture;
    private bool disposed;
    public event Action<byte[]>? Data;
    public event Action<Exception?>? Ended;
    public ProcessLoopbackInput()
    {
        library = module.Value;
        start = Marshal.GetDelegateForFunctionPointer<StartCapture>(NativeLibrary.GetExport(library, "recorder_audio_start"));
        stop = Marshal.GetDelegateForFunctionPointer<StopCapture>(NativeLibrary.GetExport(library, "recorder_audio_stop"));
        callback = (bytes, count, error, user) =>
        {
            try
            {
                if (error < 0) { var ex = Marshal.GetExceptionForHR(error); _ = Task.Run(() => Ended?.Invoke(ex)); return; }
                if (count > 0) { var pcm = new byte[count]; Marshal.Copy(bytes, pcm, 0, count); Data?.Invoke(pcm); }
            }
            catch (Exception ex) { _ = Task.Run(() => Ended?.Invoke(ex)); }
        };
    }
    public void Start()
    {
        ObjectDisposedException.ThrowIf(disposed, this); if (capture != IntPtr.Zero) throw new InvalidOperationException("已开始系统声音采集。");
        capture = start((uint)Environment.ProcessId, callback, IntPtr.Zero, out int error);
        if (capture == IntPtr.Zero) throw new InvalidOperationException("无法启动排除自身播放的系统声音采集：" + Marshal.GetExceptionForHR(error)?.Message);
    }
    public async Task StopAsync() { var current = Interlocked.Exchange(ref capture, IntPtr.Zero); if (current != IntPtr.Zero) await Task.Run(() => stop(current)); }
    public void Dispose() { if (disposed) return; StopAsync().GetAwaiter().GetResult(); disposed = true; GC.KeepAlive(callback); }
}
