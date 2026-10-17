using System.Buffers.Binary;
using System.Text.Json.Nodes;

namespace Recorder.Backend;

public sealed partial class BackendCore
{
    private Segmenter? segmenter;
    private IVoiceDetector? vad;
    private readonly List<byte> pendingAudio = new();
    private readonly RecognitionCache recognition = new();
    private readonly List<SegmentJob> segmentSink = new();
    private long expectedSequence, samples;
    private int pendingFinals;
    private bool asrFailed;
    private Func<IVoiceDetector> voiceFactory = () => new WebRtcVad(Path.Combine(AppContext.BaseDirectory, "runtime", "cpu", "recorder-vad.dll"));
    public void SetVoiceDetectorFactory(Func<IVoiceDetector> factory) { lock (gate) { if (state == "recording") throw new InvalidOperationException("请先停止录音。"); voiceFactory = factory; } }
    partial void StartAudio()
    {
        vad?.Dispose(); vad = null; segmenter = null; pendingAudio.Clear(); expectedSequence = samples = 0; asrFailed = false; pendingFinals = 0;
        segmentSink.Clear();
        if (!IsStreaming) { vad = voiceFactory(); segmenter = new Segmenter(config, item => segmentSink.Add(item)); }
    }
    partial void FinishAudio()
    {
        if (segmenter == null) return;
        if (pendingAudio.Count > 0) { var frame = new byte[640]; pendingAudio.CopyTo(frame); pendingAudio.Clear(); segmenter.Feed(frame, vad!.IsSpeech(frame)); }
        segmenter.Flush(); DrainSegments();
    }
    partial void ClearRecognition() => recognition.Clear();
    private void EnqueueSegment(SegmentJob raw)
    {
        var item = raw with { SessionId = session };
        if (item.Final)
        {
            finalSegments.Add(item.SegmentId); preview = null; pendingFinals++;
            Queue(async () => { lock (gate) pendingFinals--; await InferAsync(item); });
        }
        else { preview = item; Wake(); }
    }
    private void DrainSegments()
    {
        var items = segmentSink.ToArray(); segmentSink.Clear();
        foreach (var item in items) EnqueueSegment(item);
        if (pendingFinals >= 6 && state == "recording") { Finish(); Error("识别积压达到 6 句，已停止采集，已有文字已保留。"); }
    }
    public void Audio(string sessionId, long sequence, long startSample, byte[] pcm, int sampleRate = 16000, int channels = 1, string format = "s16le")
    {
        lock (gate)
        {
            if (disposed || state != "recording" || sessionId != session) return;
            try
            {
                if (segmenter == null) throw new InvalidOperationException("流式识别音频由应用直发服务，后端不接收音频。");
                if (sequence != expectedSequence || startSample != samples) { Finish(); throw new InvalidDataException("音频序号不连续，已停止采集并处理已接收音频。"); }
                if (sampleRate != 16000 || channels != 1 || format != "s16le" || pcm.Length % 2 != 0) { Finish(); throw new InvalidDataException("音频必须为 16 kHz 单声道 PCM16。"); }
                if (pcm.Length > 320000) { Finish(); throw new InvalidDataException("音频缓冲超过 320 KB，已停止采集。"); }
                expectedSequence++; samples += pcm.Length / 2;
                int offset = 0;
                if (pendingAudio.Count > 0)
                {
                    int take = Math.Min(640 - pendingAudio.Count, pcm.Length); pendingAudio.AddRange(pcm.AsSpan(0, take).ToArray()); offset += take;
                    if (pendingAudio.Count == 640) { var frame = pendingAudio.ToArray(); pendingAudio.Clear(); segmenter.Feed(frame, vad!.IsSpeech(frame)); }
                }
                while (offset + 640 <= pcm.Length && state == "recording") { var frame = pcm.AsSpan(offset, 640).ToArray(); segmenter.Feed(frame, vad!.IsSpeech(frame)); offset += 640; }
                if (state == "recording" && offset < pcm.Length) pendingAudio.AddRange(pcm.AsSpan(offset).ToArray());
                DrainSegments();
            }
            catch (Exception ex) { Error(ex.Message); }
        }
    }
    public void Audio(ReadOnlySpan<byte> payload)
    {
        try
        {
            if (payload.Length < 4) throw new InvalidDataException("音频头无效。");
            int length = BinaryPrimitives.ReadInt32BigEndian(payload);
            if (length is < 1 or > 4096 || payload.Length < 4 + length) throw new InvalidDataException("音频头过长或不完整。");
            var header = JsonNode.Parse(payload.Slice(4, length))!.AsObject();
            Audio((string?)header["session_id"] ?? "", BackendJson.Integer(header["sequence"]), BackendJson.Integer(header["start_sample"]), payload[(4 + length)..].ToArray(),
                checked((int)BackendJson.Integer(header["sample_rate"])), checked((int)BackendJson.Integer(header["channels"])), (string?)header["format"] ?? "");
        }
        catch (Exception ex) { lock (gate) Error(ex.Message); }
    }
    public void AudioOverflow()
    { lock (gate) { if (state == "recording") Finish(); Error("音频缓冲超过 320 KB，已停止采集并保留已完成文字。"); } }
    private bool Obsolete(SegmentJob item) { lock (gate) return item.SessionId != session || !item.Final && finalSegments.Contains(item.SegmentId); }
    private partial async Task InferAsync(SegmentJob item)
    {
        try
        {
            if (Obsolete(item) || asrFailed) return;
            var engine = config.Provider == "api" ? api ?? throw new InvalidOperationException("API 识别尚未就绪。") : asr;
            var result = await recognition.TranscribeAsync(engine, config, item, () => Obsolete(item), lifetime.Token);
            lock (gate)
            {
                if (Obsolete(item)) return;
                if (result.Text.Length > 0)
                {
                    Emit(item.Final ? "final" : "partial", new() { ["session_id"] = item.SessionId, ["segment_id"] = item.SegmentId, ["revision"] = item.Revision,
                        ["start_sample"] = item.StartSample, ["end_sample"] = item.EndSample, ["forced_cut"] = item.ForcedCut, ["elapsed_ms"] = result.ElapsedMs, ["text"] = result.Text });
                    if (item.Final) PlanTranslation(item.SessionId, item.SegmentId, result.Text, item.ForcedCut);
                    else { segmenter?.AcceptPreview(item, result.Text); DrainSegments(); }
                }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex)
        {
            asrFailed = true; recognition.Clear();
            if (config.Provider == "local") await asr.UnloadAsync(); else if (api != null) await api.UnloadAsync();
            lock (gate) { preview = null; Status("error", "识别失败，已有文字已保留，请重新加载识别服务。"); Error(ex.Message); }
        }
        finally { if (item.Final) { recognition.Forget(item); lock (gate) finalSegments.Remove(item.SegmentId); } }
    }
}
