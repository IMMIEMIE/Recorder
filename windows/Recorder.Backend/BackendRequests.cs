using System.Collections.Concurrent;
using System.Text.Json.Nodes;

namespace Recorder.Backend;

/// <summary>
/// Matches backend events to the control command that caused them (events carry its request_id).
/// Shared by the desktop app and the portable tests so both exercise the same completion rules.
/// </summary>
public sealed class BackendRequests
{
    /// <summary>asr: model/service load; translator: translator load; preferences: translation_settings.</summary>
    public enum Kind { Asr, Translator, Preferences }
    private sealed class Pending(Kind kind)
    {
        public readonly Kind Kind = kind;
        public readonly TaskCompletionSource Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool Configured;
    }
    private readonly ConcurrentDictionary<string, Pending> pending = new();
    public async Task RunAsync(BackendChannel channel, JsonObject command, Kind kind, TimeSpan? timeout = null, CancellationToken ct = default)
    {
        var id = (string?)command["request_id"] is { Length: > 0 } value ? value : throw new ArgumentException("Command needs a request_id.");
        var waiter = new Pending(kind); pending[id] = waiter;
        try
        {
            await channel.ControlAsync(command);
            await (timeout is { } limit ? waiter.Completion.Task.WaitAsync(limit, ct) : waiter.Completion.Task.WaitAsync(ct));
        }
        finally { pending.TryRemove(id, out _); }
    }
    public void Observe(JsonObject message)
    {
        if ((string?)message["request_id"] is not { Length: > 0 } id || !pending.TryGetValue(id, out var waiter)) return;
        string type = (string?)message["type"] ?? "", state = (string?)message["state"] ?? "";
        string Reason() => (string?)message["message"] is { Length: > 0 } text ? text : (string?)message["detail"] is { Length: > 0 } detail ? detail : "模型操作失败。";
        if (type == "error") { waiter.Completion.TrySetException(new InvalidOperationException(Reason())); return; }
        switch (waiter.Kind)
        {
            case Kind.Asr:
                if (type == "config") waiter.Configured = true;
                else if (type == "status" && state == "ready" && waiter.Configured) waiter.Completion.TrySetResult();
                break;
            case Kind.Translator:
                if (type == "translator" && state == "error") waiter.Completion.TrySetException(new InvalidOperationException(Reason()));
                else if (type == "translator" && state == "ready") waiter.Completion.TrySetResult();
                break;
            case Kind.Preferences:
                // The backend answers with its current translator state; an earlier translator failure is not a failure of this change.
                if (type == "translator") waiter.Completion.TrySetResult();
                break;
        }
    }
    public void FailAll(Exception error) { foreach (var waiter in pending.Values) waiter.Completion.TrySetException(error); }
}
