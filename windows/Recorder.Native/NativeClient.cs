using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json.Nodes;
using Microsoft.Win32.SafeHandles;

namespace Recorder.Native;

/// <summary>One serialized native engine. Control cancellation uses the same pipe while inference runs.</summary>
public sealed class NativeClient : IAsyncDisposable
{
    private readonly NamedPipeServerStream pipe;
    private readonly Process process;
    private readonly SafeFileHandle job;
    private readonly SemaphoreSlim calls = new(1), writes = new(1);
    private readonly CancellationTokenSource lifetime = new();
    private long sequence;
    private int disposed;
    private NativeClient(NamedPipeServerStream pipe, Process process, SafeFileHandle job)
    {
        this.pipe = pipe; this.process = process; this.job = job;
        process.Exited += (_, _) => { if (Volatile.Read(ref disposed) == 0 && !lifetime.IsCancellationRequested) UnexpectedExit?.Invoke(); };
        process.EnableRaisingEvents = true;
    }
    public int ProcessId => process.Id;
    public long PrivateBytes { get { process.Refresh(); return process.PrivateMemorySize64; } }
    public bool IsAlive { get { try { return !process.HasExited && pipe.IsConnected; } catch (InvalidOperationException) { return false; } } }
    public event Action? UnexpectedExit;
    public static async Task<NativeClient> StartAsync(string executable, CancellationToken ct = default)
    {
        if (!File.Exists(executable)) throw new FileNotFoundException("原生推理组件缺失，请重新安装 x64 完整版。", executable);
        var name = "Shengjian-" + Guid.NewGuid().ToString("N");
        var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var info = new ProcessStartInfo(Path.GetFullPath(executable)) { UseShellExecute = false, CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(executable))! };
        info.ArgumentList.Add("--pipe"); info.ArgumentList.Add(name);
        Process? process = null;
        SafeFileHandle? job = null;
        try
        {
            process = Process.Start(info) ?? throw new IOException("无法启动原生推理进程。");
            job = ProcessJob.Attach(process);
            await pipe.WaitForConnectionAsync(ct).WaitAsync(TimeSpan.FromSeconds(20), ct);
            var client = new NativeClient(pipe, process, job);
            await client.CallAsync("hello", ct: ct); return client;
        }
        catch { pipe.Dispose(); job?.Dispose(); if (process != null) { if (!process.HasExited) process.Kill(true); process.Dispose(); } throw; }
    }
    public async Task<JsonObject> CallAsync(string command, JsonObject? parameters = null, ReadOnlyMemory<byte> pcm = default, CancellationToken ct = default)
    {
        ObjectDisposedException.ThrowIf(disposed != 0, this);
        await calls.WaitAsync(ct);
        try
        {
            ct.ThrowIfCancellationRequested();
            var id = Interlocked.Increment(ref sequence);
            var request = parameters?.DeepClone().AsObject() ?? new JsonObject();
            request["rpc_version"] = 1; request["id"] = id; request["command"] = command; request["payload_bytes"] = pcm.Length;
            await WriteAsync(request, pcm, lifetime.Token);
            var reading = ReadAsync(lifetime.Token);
            JsonObject response;
            try { response = await reading.WaitAsync(ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                try
                {
                    await WriteAsync(new JsonObject { ["rpc_version"] = 1, ["command"] = "cancel", ["target_id"] = id }, default, lifetime.Token);
                    await reading.WaitAsync(TimeSpan.FromSeconds(10));
                }
                catch { lifetime.Cancel(); pipe.Dispose(); if (!process.HasExited) process.Kill(true); }
                throw;
            }
            if ((long?)response["id"] != id || (int?)response["rpc_version"] != 1) throw new InvalidDataException("原生推理协议不匹配。");
            if (response["error"] is JsonNode error) throw new InvalidOperationException("原生推理失败：" + error.GetValue<string>());
            return response["result"]?.AsObject() ?? throw new InvalidDataException("原生推理响应缺少结果。");
        }
        catch (EndOfStreamException ex) { throw new IOException("原生推理进程已退出，已有文字已保留。请重新加载模型。", ex); }
        finally { calls.Release(); }
    }
    private async Task WriteAsync(JsonObject value, ReadOnlyMemory<byte> payload, CancellationToken ct)
    {
        var raw = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(value);
        if (raw.Length > 1024 * 1024 || payload.Length > 800000 || payload.Length % 2 != 0) throw new InvalidDataException("推理请求过长或音频格式无效。");
        var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, raw.Length);
        await writes.WaitAsync(ct);
        try { await pipe.WriteAsync(header, ct); await pipe.WriteAsync(raw, ct); if (!payload.IsEmpty) await pipe.WriteAsync(payload, ct); await pipe.FlushAsync(ct); }
        finally { writes.Release(); }
    }
    private async Task<JsonObject> ReadAsync(CancellationToken ct)
    {
        var header = new byte[4]; await pipe.ReadExactlyAsync(header, ct);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length is < 1 or > 1048576) throw new InvalidDataException("原生推理响应长度无效。");
        var raw = new byte[length]; await pipe.ReadExactlyAsync(raw, ct);
        return JsonNode.Parse(raw)?.AsObject() ?? throw new InvalidDataException("原生推理响应格式无效。");
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        lifetime.Cancel(); pipe.Dispose();
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } catch { if (!process.HasExited) process.Kill(true); }
        job.Dispose(); process.Dispose(); lifetime.Dispose();
        // Calls may still be unwinding; do not dispose their semaphores underneath them.
    }
}
