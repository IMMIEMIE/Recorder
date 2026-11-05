using NAudio.Wave;

namespace Recorder.Windows;

// Streaming area resampling: downmix and integrate each 16 kHz output interval.
// Persistent phase prevents boundary drift between capture callbacks.
public sealed class PcmConverter(WaveFormat format)
{
    private double weight, sum;
    public byte[] Convert(byte[] data, int count)
    {
        using var output = new MemoryStream();
        using var writer = new BinaryWriter(output);
        bool floating = format.Encoding == WaveFormatEncoding.IeeeFloat ||
            format is WaveFormatExtensible ext && ext.SubFormat == new Guid("00000003-0000-0010-8000-00aa00389b71");
        int bytes = format.BitsPerSample / 8;
        for (int offset = 0; offset + format.BlockAlign <= count; offset += format.BlockAlign)
        {
            double sample = 0;
            for (int ch = 0; ch < format.Channels; ch++)
            {
                int p = offset + ch * bytes;
                sample += floating && bytes == 4 ? BitConverter.ToSingle(data, p) : bytes switch
                {
                    2 => BitConverter.ToInt16(data, p) / 32768.0,
                    3 => ((data[p] << 8 | data[p + 1] << 16 | data[p + 2] << 24) >> 8) / 8388608.0,
                    4 => BitConverter.ToInt32(data, p) / 2147483648.0,
                    1 => (data[p] - 128) / 128.0,
                    _ => throw new NotSupportedException("不支持此录音格式，请更换音频设备。")
                };
            }
            sample /= format.Channels;
            if (!double.IsFinite(sample)) sample = 0;
            double remaining = 16000.0 / format.SampleRate;
            while (remaining > 1e-9)
            {
                double take = Math.Min(1 - weight, remaining);
                sum += sample * take; weight += take; remaining -= take;
                if (weight >= 1 - 1e-9)
                {
                    writer.Write((short)Math.Clamp(sum * 32768, short.MinValue, short.MaxValue));
                    weight = sum = 0;
                }
            }
        }
        return output.ToArray();
    }
}

public sealed class AudioInput : IDisposable
{
    private IWaveIn? capture;
    private TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public event Action<byte[]>? Data;
    public event Action<Exception?>? Ended;
    public void Start(bool loopback, int microphone)
    {
        capture = loopback ? new WasapiLoopbackCapture() : new WaveInEvent
        { DeviceNumber = microphone, WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 100 };
        var converter = new PcmConverter(capture.WaveFormat);
        capture.DataAvailable += (_, e) =>
        {
            try { var pcm = converter.Convert(e.Buffer, e.BytesRecorded); if (pcm.Length > 0) Data?.Invoke(pcm); }
            catch (Exception ex) { Ended?.Invoke(ex); }
        };
        capture.RecordingStopped += (_, e) => { stopped.TrySetResult(); Ended?.Invoke(e.Exception); };
        capture.StartRecording();
    }
    public async Task StopAsync()
    {
        if (capture == null) return;
        capture.StopRecording();
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }
    public static async Task ReadFileAsync(string path, Action<byte[]> onData, bool paced, CancellationToken ct)
    {
        using WaveStream reader = Path.GetExtension(path).ToLowerInvariant() is ".aiff" or ".aif" or ".aifc"
            ? new PcmAiffReader(path) : new AudioFileReader(path);
        using var resampler = new MediaFoundationResampler(reader, new WaveFormat(16000, 16, 1)) { ResamplerQuality = 60 };
        var buffer = new byte[3200];
        int n;
        while ((n = resampler.Read(buffer, 0, buffer.Length)) > 0)
        {
            ct.ThrowIfCancellationRequested();
            onData(buffer.AsSpan(0, n).ToArray());
            if (paced) await Task.Delay(TimeSpan.FromSeconds(n / 32000.0), ct);
        }
    }
    public void Dispose() { capture?.Dispose(); capture = null; }
}

public sealed record AudioSegment(byte[] Pcm, double Seconds);

public sealed class Segmenter(int silenceMs)
{
    private readonly Queue<byte[]> preRoll = new();
    private readonly MemoryStream pending = new();
    private readonly MemoryStream speech = new();
    private int silence, voiced;
    private long samples, start;
    public event Action<AudioSegment>? Final;
    public void Append(byte[] data)
    {
        pending.Write(data);
        var bytes = pending.ToArray(); int p = 0;
        while (p + 640 <= bytes.Length)
        {
            Frame(bytes.AsSpan(p, 640).ToArray()); p += 640;
        }
        pending.SetLength(0); pending.Write(bytes, p, bytes.Length - p);
    }
    private void Frame(byte[] frame)
    {
        double power = 0;
        for (int i = 0; i < frame.Length; i += 2) { var s = BitConverter.ToInt16(frame, i) / 32768.0; power += s * s; }
        bool voice = Math.Sqrt(power / (frame.Length / 2)) >= .008;
        if (speech.Length == 0)
        {
            preRoll.Enqueue(frame); if (preRoll.Count > 10) preRoll.Dequeue();
            if (voice)
            {
                start = Math.Max(0, samples - (preRoll.Count - 1) * 320);
                foreach (var f in preRoll) speech.Write(f);
                preRoll.Clear(); voiced = 20; silence = 0;
            }
        }
        else
        {
            speech.Write(frame);
            if (voice) { voiced += 20; silence = 0; } else silence += 20;
            // Bound memory and model context on 32-bit hosts; no overlap/deduplication.
            if (silence >= Math.Clamp(silenceMs, 200, 6000) || speech.Length >= 25 * 32000) Flush();
        }
        samples += frame.Length / 2;
    }
    public void Finish()
    {
        if (pending.Length > 0) { var data = pending.ToArray(); pending.SetLength(0); Frame(data); }
        Flush();
    }
    private void Flush()
    {
        if (speech.Length > 0 && voiced >= 100) Final?.Invoke(new(speech.ToArray(), start / 16000.0));
        speech.SetLength(0); voiced = silence = 0; preRoll.Clear();
    }
}
