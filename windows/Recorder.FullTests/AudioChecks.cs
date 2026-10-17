using NAudio.Wave;
using Recorder.Windows;
using System.Text.Json;
internal static class AudioChecks
{
    public static async Task Tone()
    {
        byte[] data = new byte[32000 * 2];
        for (int i = 0; i < data.Length / 2; i++) BitConverter.TryWriteBytes(data.AsSpan(i * 2, 2), (short)(Math.Sin(i * 2 * Math.PI * 440 / 16000) * 2000));
        using var stream = new RawSourceWaveStream(new MemoryStream(data), new WaveFormat(16000, 16, 1));
        using var player = new WasapiOut(); player.Init(stream); player.Play(); await Task.Delay(2200);
    }
    public static async Task<int> Loopback(string directory)
    {
        Directory.CreateDirectory(directory); double peak = 0; long samples = 0; Exception? failure = null;
        using var input = new ProcessLoopbackInput();
        input.Data += bytes => { for (int i = 0; i + 1 < bytes.Length; i += 2) { double value = Math.Abs(BitConverter.ToInt16(bytes, i) / 32768.0); peak = Math.Max(peak, value); samples++; } };
        input.Ended += ex => failure = ex;
        input.Start(); await Tone(); double selfPeak = peak; peak = 0; samples = 0;
        File.WriteAllText(Path.Combine(directory, "external-ready"), "ready");
        await Task.Delay(5000); await input.StopAsync();
        var report = new { self_peak = selfPeak, external_peak = peak, external_samples = samples, error = failure?.Message, passed = selfPeak < .001 && peak > .005 && failure == null };
        File.WriteAllText(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        return report.passed ? 0 : 1;
    }
}
