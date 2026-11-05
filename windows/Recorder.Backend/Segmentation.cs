using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace Recorder.Backend;

public interface IVoiceDetector : IDisposable { bool IsSpeech(ReadOnlySpan<byte> pcm); }
public sealed class WebRtcVad : IVoiceDetector
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr Create();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int Process(IntPtr vad, short[] samples, int count);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void Destroy(IntPtr vad);
    private IntPtr library, handle;
    private readonly Process process;
    private readonly Destroy destroy;
    public WebRtcVad(string libraryPath)
    {
        library = NativeLibrary.Load(Path.GetFullPath(libraryPath));
        try
        {
            var create = Marshal.GetDelegateForFunctionPointer<Create>(NativeLibrary.GetExport(library, "recorder_vad_create"));
            process = Marshal.GetDelegateForFunctionPointer<Process>(NativeLibrary.GetExport(library, "recorder_vad_process"));
            destroy = Marshal.GetDelegateForFunctionPointer<Destroy>(NativeLibrary.GetExport(library, "recorder_vad_destroy"));
            handle = create(); if (handle == IntPtr.Zero) throw new InvalidOperationException("无法初始化语音活动检测。");
        }
        catch { NativeLibrary.Free(library); library = IntPtr.Zero; throw; }
    }
    public bool IsSpeech(ReadOnlySpan<byte> pcm)
    {
        if (handle == IntPtr.Zero || pcm.Length != 640) throw new InvalidDataException("VAD 要求 20 ms PCM16 音频帧。");
        var samples = new short[320]; for (int i = 0; i < samples.Length; ++i) samples[i] = System.Buffers.Binary.BinaryPrimitives.ReadInt16LittleEndian(pcm.Slice(i * 2, 2));
        return process(handle, samples, 320) switch { 0 => false, 1 => true, _ => throw new InvalidOperationException("语音活动检测失败。") };
    }
    public void Dispose() { if (handle != IntPtr.Zero) { destroy(handle); handle = IntPtr.Zero; } if (library != IntPtr.Zero) { NativeLibrary.Free(library); library = IntPtr.Zero; } }
}
internal static class SentenceText
{
    public static bool CompleteCandidate(string raw)
    {
        var text = raw.TrimEnd();
        // Closing quotes/brackets (including intervening whitespace) do not hide sentence punctuation.
        while (text.Length > 0 && (char.IsWhiteSpace(text[^1]) || "”’\"'」』）)]】》〉〕}".Contains(text[^1]))) text = text[..^1];
        if (text.Length == 0 || !text.EnumerateRunes().Any(System.Text.Rune.IsLetterOrDigit)) return false;
        if (Regex.IsMatch(text, @"(?:\.{2,}|…+)[。！？!?]*$")) return false;
        if (!Complete(text)) return false;
        if (!text.EndsWith('.')) return true;
        var word = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Last().TrimStart('“', '‘', '"', '\'', '(', '[', '{', '「', '『', '（', '【', '《', '〈', '〔').ToLowerInvariant();
        if (!Complete(word)) return false;
        // Short titles, common abbreviations and units are conservative: use the fallback pause instead.
        return word is not ("st." or "mt." or "no." or "nos." or "fig." or "figs." or "vol." or "dept." or "inc." or "ltd." or "co." or "corp." or "approx." or "est." or "min." or "max." or "sec." or "hr." or "cm." or "mm." or "kg.");
    }
    public static bool Complete(string raw)
    {
        var text = raw.Trim().TrimEnd('”', '’', '"', '\'', '」', '』', '）', ')', ']').Trim();
        if (text.Length == 0 || text.EndsWith("...") || text.EndsWith('…')) return false;
        if ("。！？!?".Contains(text[^1])) return true;
        if (!text.EndsWith('.')) return false;
        string word = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Last();
        if (Regex.IsMatch(text, @"\d\.$") || word.Count(c => c == '.') > 1 || Regex.IsMatch(word, @"^[A-Za-z]\.$")) return false;
        return !new[] { "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "etc.", "vs.", "e.g.", "i.e." }.Contains(word.ToLowerInvariant());
    }
    public static string Join(string left, string right) => left.Length == 0 ? right : right.Length == 0 ? left :
        left + (left[^1] <= 127 && right[0] <= 127 && char.IsLetterOrDigit(right[0]) ? " " : "") + right;
}
internal sealed class Segmenter(ModelConfig config, Action<SegmentJob> emit)
{
    private enum EndpointState { Idle, Speaking, PauseCandidate }
    private EndpointState endpointState;
    private bool candidateProbeSent;
    private bool LocalSmart => config.Provider == "local" && config.EndpointMode == "smart";
    private bool HasCurrentTail => results.Count > 0 && results[^1].LastVoiced == lastVoiced;
    private readonly Queue<(long Offset, byte[] Pcm)> preroll = new();
    private readonly List<byte[]> frames = new();
    private readonly List<(int Revision, long LastVoiced, string Text)> results = new();
    private long position, start, lastVoiced, snapshotVoiced;
    private int segment, revision, silent, voiced, lastPreview;
    public void Feed(byte[] pcm, bool speech)
    {
        if (pcm.Length != 640) throw new InvalidDataException("VAD 要求 20 ms PCM16 音频帧。");
        long at = position; position += 320;
        if (frames.Count == 0)
        {
            if (!speech) { if (preroll.Count == 12) preroll.Dequeue(); preroll.Enqueue((at, pcm)); return; }
            start = preroll.Count > 0 ? preroll.Peek().Offset : at;
            frames.AddRange(preroll.Select(f => f.Pcm)); preroll.Clear(); segment++; revision = 0; results.Clear();
            endpointState = EndpointState.Speaking; candidateProbeSent = false;
        }
        frames.Add(pcm);
        if (speech)
        {
            voiced++; lastVoiced = position;
            endpointState = EndpointState.Speaking; candidateProbeSent = false;
        }
        else if (endpointState == EndpointState.Speaking) endpointState = EndpointState.PauseCandidate;
        silent = speech ? 0 : silent + 1;
        if (silent * 20 >= Threshold) Finish();
        else if (LocalSmart && endpointState == EndpointState.PauseCandidate && silent * 20 >= 300 && !candidateProbeSent && voiced >= 2)
        {
            // One tail probe per pause, independent of the normal preview interval. The backend's
            // single preview slot replaces waiting work, while an in-flight request can finish safely.
            candidateProbeSent = true;
            if (!HasCurrentTail) { Snapshot(false); snapshotVoiced = lastVoiced; lastPreview = frames.Count * 20; }
        }
        else if (voiced >= 3 && lastVoiced > snapshotVoiced && frames.Count * 20 - lastPreview >= config.PreviewIntervalMs)
        { Snapshot(false); snapshotVoiced = lastVoiced; lastPreview = frames.Count * 20; }
    }
    public int Threshold
    {
        get
        {
            if (config.EndpointMode == "fixed") return config.EndpointSilenceMs;
            if (LocalSmart)
                return endpointState == EndpointState.PauseCandidate && HasCurrentTail && SentenceText.CompleteCandidate(results[^1].Text)
                    ? config.SmartSentenceSilenceMs : config.SmartFallbackSilenceMs;
            // Keep the existing HTTP API segmentation policy; cloud streaming bypasses Segmenter entirely.
            if (results.Count == 0) return 1800;
            var latest = results[^1];
            if (latest.LastVoiced != lastVoiced || !SentenceText.Complete(latest.Text)) return 1800;
            if (results.Count == 1) return 1000;
            return results[^2].Text == latest.Text ? 500 : 1800;
        }
    }
    public void AcceptPreview(SegmentJob item, string text)
    {
        if (frames.Count == 0 || item.Final || item.SegmentId != segment || item.StartSample != start || item.Revision > revision || results.Count > 0 && item.Revision <= results[^1].Revision) return;
        // A pause probe that returns after speech resumes must not end the newly extended utterance.
        if (LocalSmart && item.LastVoicedSample != lastVoiced) return;
        results.Add((item.Revision, item.LastVoicedSample ?? 0, text.Trim())); if (results.Count > 2) results.RemoveAt(0);
        if (silent * 20 >= Threshold) Finish();
    }
    private void Snapshot(bool final)
    {
        var pcm = new byte[checked(frames.Count * 640)];
        for (int i = 0; i < frames.Count; ++i) Buffer.BlockCopy(frames[i], 0, pcm, i * 640, 640);
        emit(new("", segment, ++revision, start, position, final, pcm, lastVoiced));
    }
    public void Finish()
    {
        if (frames.Count > 0 && voiced >= 2) Snapshot(true);
        frames.Clear(); results.Clear(); silent = voiced = lastPreview = 0; lastVoiced = snapshotVoiced = 0;
        endpointState = EndpointState.Idle; candidateProbeSent = false;
    }
    public void Flush() { Finish(); preroll.Clear(); }
}
internal sealed class RecognitionCache
{
    private sealed class Entry { public Dictionary<int, string> Chunks = new(); public long? LastVoiced; public string? LastText; }
    private readonly Dictionary<(string Session, int Segment, long Start), Entry> entries = new();
    public int Count => entries.Count;
    public void Clear() => entries.Clear();
    public void Forget(SegmentJob item) => entries.Remove((item.SessionId, item.SegmentId, item.StartSample));
    public async Task<(string Text, int ElapsedMs)> TranscribeAsync(IAsrEngine engine, ModelConfig config, SegmentJob item, Func<bool> obsolete, CancellationToken ct)
    {
        var key = (item.SessionId, item.SegmentId, item.StartSample);
        if (!entries.TryGetValue(key, out var entry)) entries[key] = entry = new();
        if (entry.LastText != null && item.LastVoicedSample is long voiced && entry.LastVoiced == voiced) return (entry.LastText, 0);
        int chunkBytes = config.MaxSegmentSeconds * 32000; var text = ""; int elapsed = 0;
        for (int offset = 0; offset < item.Pcm.Length; offset += chunkBytes)
        {
            if (obsolete()) return ("", elapsed);
            var pcm = item.Pcm.AsMemory(offset, Math.Min(chunkBytes, item.Pcm.Length - offset));
            if (!entry.Chunks.TryGetValue(offset, out var part))
            {
                var clock = System.Diagnostics.Stopwatch.StartNew(); part = await engine.TranscribeAsync(pcm, ct); elapsed += (int)clock.ElapsedMilliseconds;
                if (pcm.Length == chunkBytes) entry.Chunks[offset] = part;
            }
            text = SentenceText.Join(text, part);
        }
        if (!obsolete()) { entry.LastText = text; entry.LastVoiced = item.LastVoicedSample; }
        return (text, elapsed);
    }
}
