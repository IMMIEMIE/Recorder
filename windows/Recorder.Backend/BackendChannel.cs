using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace Recorder.Backend;

/// <summary>FIFO capture/control mailbox. Stop barriers drain all previously accepted audio.</summary>
public sealed class BackendChannel : IAsyncDisposable
{
    private sealed record Work(Action Action, int Bytes = -1, TaskCompletionSource? Completion = null);
    private readonly BackendCore core;
    private readonly Channel<Work> queue = Channel.CreateUnbounded<Work>(new() { SingleReader = true });
    private readonly Task reader;
    private long buffered;
    private int audioPackets, overflowing, disposed;
    public BackendCore Core => core;
    public BackendChannel(BackendCore core) { this.core = core; reader = Task.Run(ReadAsync); }
    public bool Audio(string session, long sequence, long start, byte[] pcm)
    {
        if (Volatile.Read(ref disposed) != 0) return false;
        var size = Interlocked.Add(ref buffered, pcm.Length); int count = Interlocked.Increment(ref audioPackets);
        if (size > 320000 || count > 128)
        {
            Interlocked.Add(ref buffered, -pcm.Length); Interlocked.Decrement(ref audioPackets);
            if (Interlocked.Exchange(ref overflowing, 1) == 0) queue.Writer.TryWrite(new(() => core.AudioOverflow()));
            return false;
        }
        var owned = pcm.ToArray();
        if (queue.Writer.TryWrite(new(() => core.Audio(session, sequence, start, owned), pcm.Length))) return true;
        Interlocked.Add(ref buffered, -pcm.Length); Interlocked.Decrement(ref audioPackets); return false;
    }
    public async Task ControlAsync(JsonObject command)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.Writer.TryWrite(new(() => { if ((string?)command["command"] == "start") Interlocked.Exchange(ref overflowing, 0); core.Control(command); }, Completion: completion))) throw new IOException("后端通道已关闭。");
        await completion.Task;
    }
    private async Task ReadAsync()
    {
        await foreach (var item in queue.Reader.ReadAllAsync())
        {
            try { item.Action(); item.Completion?.TrySetResult(); }
            catch (Exception ex) { item.Completion?.TrySetException(ex); }
            finally { if (item.Bytes >= 0) { Interlocked.Add(ref buffered, -item.Bytes); Interlocked.Decrement(ref audioPackets); } }
        }
    }
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        queue.Writer.TryComplete(); await reader; await core.DisposeAsync();
    }
}
