using System.Text.Json.Nodes;
namespace Recorder.Backend;
public sealed record LiveRowState(string Id, bool SourceDone, string SourceText, string[] Outputs, bool TranslationDone);
public sealed class LiveAudioDecoder
{
    private readonly HashSet<string> seen = new(), completed = new();
    private readonly Dictionary<string, byte> tails = new();
    public bool HasIncompleteSample => tails.Count > 0;
    public byte[]? Consume(JsonNode message)
    {
        string? type = (string?)message["type"];
        if (type is not ("response.audio.delta" or "response.audio.done")) return null;
        if ((string?)message["event_id"] is string eventId && !seen.Add(eventId)) return null;
        string id = (string?)message["item_id"] ?? throw new InvalidDataException("译音缺少消息标识。");
        if (completed.Contains(id)) return null;
        if (type == "response.audio.done") { completed.Add(id); if (tails.Remove(id)) throw new InvalidDataException("译音 PCM 样本不完整，字幕继续更新。"); return null; }
        byte[] chunk = Convert.FromBase64String((string?)message["delta"] ?? throw new InvalidDataException("译音数据无效。"));
        var bytes = new List<byte>(chunk.Length + 1); if (tails.Remove(id, out byte tail)) bytes.Add(tail); bytes.AddRange(chunk);
        if ((bytes.Count & 1) != 0) { tails[id] = bytes[^1]; bytes.RemoveAt(bytes.Count - 1); }
        return bytes.Count == 0 ? null : bytes.ToArray();
    }
}
public sealed class LivePlaybackQueue(bool afterFinal)
{
    private readonly LiveAudioDecoder decoder = new();
    private readonly Dictionary<string, MemoryStream> buffers = new();
    private readonly HashSet<string> done = new(), released = new();
    private int buffered;
    public bool HasPending => buffered > 0 || decoder.HasIncompleteSample;
    public IReadOnlyList<byte[]> Consume(JsonNode message, IReadOnlyList<LiveRowState> rows)
    {
        var pcm = decoder.Consume(message); if (!afterFinal) return pcm == null ? [] : [pcm];
        if ((string?)message["item_id"] is string id)
        {
            if (pcm != null && !released.Contains(id))
            {
                if (buffered + pcm.Length > 24000 * 2 * 30) throw new InvalidDataException("等待定稿的译音超过 30 秒，字幕继续更新。");
                if (!buffers.TryGetValue(id, out var stream)) buffers[id] = stream = new(); stream.Write(pcm); buffered += pcm.Length;
            }
            if ((string?)message["type"] == "response.audio.done") done.Add(id);
        }
        var ready = new List<byte[]>();
        foreach (var row in rows)
        {
            var waiting = row.Outputs.Where(o => !released.Contains(o)).ToArray();
            if (row.Outputs.Length > 0 && waiting.Length == 0) continue;
            if (!row.SourceDone) break;
            if (row.Outputs.Length == 0) { if (row.SourceText.Length == 0) continue; break; }
            if (!row.TranslationDone || waiting.Any(o => !done.Contains(o))) break;
            foreach (string output in waiting) { released.Add(output); if (buffers.Remove(output, out var stream)) { ready.Add(stream.ToArray()); buffered -= (int)stream.Length; stream.Dispose(); } }
        }
        return ready;
    }
}
public sealed class LiveReplayCache(int capacity = 128 * 1024 * 1024)
{
    private readonly object gate = new();
    private LiveAudioDecoder decoder = new();
    private readonly Dictionary<string, MemoryStream> pending = new();
    private readonly Dictionary<string, byte[]> clips = new();
    private readonly Queue<string> order = new();
    private readonly HashSet<string> done = new(), rejected = new(), finalized = new();
    private long pendingBytes, clipBytes;
    public long Bytes { get { lock (gate) return pendingBytes + clipBytes; } }
    public byte[]? Get(string id) { lock (gate) return clips.TryGetValue(id, out var clip) ? clip.ToArray() : null; }
    public void BeginSession() { lock (gate) { decoder = new(); foreach (var stream in pending.Values) stream.Dispose(); pending.Clear(); done.Clear(); rejected.Clear(); finalized.Clear(); pendingBytes = 0; } }
    public void Clear() { lock (gate) { BeginSession(); clips.Clear(); order.Clear(); clipBytes = 0; } }
    private void Reject(string id) { if (pending.Remove(id, out var data)) { pendingBytes -= data.Length; data.Dispose(); } rejected.Add(id); }
    public void Consume(JsonNode message, IReadOnlyList<LiveRowState> rows, string session)
    {
        lock (gate)
        {
            string id = (string?)message["item_id"] ?? "";
            try
            {
                var pcm = decoder.Consume(message);
                if (pcm != null && !rejected.Contains(id))
                {
                    long length = pending.TryGetValue(id, out var stream) ? stream.Length : 0;
                    while (pendingBytes + clipBytes + pcm.Length > capacity && order.TryDequeue(out string? old)) { if (clips.Remove(old, out var clip)) clipBytes -= clip.Length; }
                    if (length + pcm.Length > 24000 * 2 * 30 || pendingBytes + clipBytes + pcm.Length > capacity) Reject(id);
                    else { if (stream == null) pending[id] = stream = new(); stream.Write(pcm); pendingBytes += pcm.Length; }
                }
                if ((string?)message["type"] == "response.audio.done") done.Add(id);
            }
            catch (FormatException) { Reject(id); } catch (InvalidDataException) { Reject(id); }
            foreach (var row in rows)
            {
                if (finalized.Contains(row.Id) || !row.SourceDone || !row.TranslationDone || row.Outputs.Length == 0 || row.Outputs.Any(o => !done.Contains(o) && !rejected.Contains(o))) continue;
                finalized.Add(row.Id); using var data = new MemoryStream();
                foreach (string output in row.Outputs) if (pending.Remove(output, out var stream)) { stream.WriteTo(data); pendingBytes -= stream.Length; stream.Dispose(); }
                if (data.Length == 0 || data.Length > Math.Min(capacity, 24000 * 2 * 30) || row.Outputs.Any(rejected.Contains)) continue;
                string key = session + ":live:" + row.Id; var clip = data.ToArray(); clips[key] = clip; order.Enqueue(key); clipBytes += clip.Length;
            }
        }
    }
}
