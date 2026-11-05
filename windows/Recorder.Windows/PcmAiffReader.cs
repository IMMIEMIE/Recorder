using System.Buffers.Binary;
using System.Text;
using NAudio.Wave;

namespace Recorder.Windows;

// macOS speech fixtures use AIFC 'twos', which is big-endian PCM rather than
// compressed audio. NAudio 2.x only accepts the equivalent AIFC 'NONE' tag.
public sealed class PcmAiffReader : WaveStream
{
    private readonly FileStream file;
    private readonly WaveFormat format;
    private readonly long begin, length;
    private readonly bool bigEndian;
    public PcmAiffReader(string path)
    {
        file = File.OpenRead(path);
        try
        {
            using var reader = new BinaryReader(file, Encoding.ASCII, true);
            string Tag() => Encoding.ASCII.GetString(reader.ReadBytes(4));
            uint U32() => BinaryPrimitives.ReadUInt32BigEndian(reader.ReadBytes(4));
            short I16() => BinaryPrimitives.ReadInt16BigEndian(reader.ReadBytes(2));
            if (Tag() != "FORM") throw new InvalidDataException("AIFF 文件头无效。");
            U32(); var form = Tag(); if (form is not "AIFF" and not "AIFC") throw new InvalidDataException("不支持的 AIFF 格式。");
            WaveFormat? found = null; long dataStart = -1, dataSize = 0; bool endian = true;
            while (file.Position + 8 <= file.Length)
            {
                var tag = Tag(); long size = U32(); long chunk = file.Position;
                if (size > file.Length - chunk) throw new InvalidDataException("AIFF 文件被截断。");
                if (tag == "COMM")
                {
                    if (size < 18) throw new InvalidDataException("AIFF 通道信息无效。");
                    int channels = I16(); U32(); int bits = I16(); var rateBytes = reader.ReadBytes(10);
                    int exponent = BinaryPrimitives.ReadUInt16BigEndian(rateBytes) & 0x7fff;
                    ulong mantissa = BinaryPrimitives.ReadUInt64BigEndian(rateBytes.AsSpan(2));
                    double rate = mantissa * Math.Pow(2, exponent - 16383 - 63);
                    if (!double.IsFinite(rate) || rate < 8000 || rate > 384000 || channels < 1 || channels > 8 || bits is not 16 and not 24 and not 32)
                        throw new NotSupportedException("仅支持 16 / 24 / 32 位 PCM AIFF 音频。");
                    if (form == "AIFC")
                    {
                        if (size < 22) throw new InvalidDataException("AIFC 格式信息无效。");
                        var compression = Tag();
                        if (compression is not "NONE" and not "twos" and not "sowt") throw new NotSupportedException("此 AIFC 使用压缩编码，请先转换为 WAV。");
                        endian = compression != "sowt";
                    }
                    found = new WaveFormat((int)Math.Round(rate), bits, channels);
                }
                if (tag == "SSND")
                {
                    if (size < 8) throw new InvalidDataException("AIFF 音频块无效。");
                    var offset = U32(); U32();
                    if (offset > size - 8) throw new InvalidDataException("AIFF 音频偏移无效。");
                    dataStart = file.Position + offset; dataSize = size - 8 - offset;
                }
                file.Position = chunk + size + (size & 1);
            }
            format = found ?? throw new InvalidDataException("AIFF 缺少通道信息。");
            if (dataStart < 0) throw new InvalidDataException("AIFF 缺少音频数据。");
            begin = dataStart; length = dataSize - dataSize % format.BlockAlign; bigEndian = endian; file.Position = begin;
        }
        catch { file.Dispose(); throw; }
    }
    public override WaveFormat WaveFormat => format;
    public override long Length => length;
    public override long Position
    {
        get => file.Position - begin;
        set { long bounded = Math.Clamp(value, 0, length); file.Position = begin + bounded - bounded % format.BlockAlign; }
    }
    public override int Read(byte[] buffer, int offset, int count)
    {
        count = (int)Math.Min(count, length - Position); count -= count % format.BlockAlign;
        int total = 0;
        while (total < count) { int n = file.Read(buffer, offset + total, count - total); if (n == 0) break; total += n; }
        int width = format.BitsPerSample / 8;
        if (bigEndian) for (int p = offset; p + width <= offset + total; p += width) Array.Reverse(buffer, p, width);
        return total;
    }
    protected override void Dispose(bool disposing) { if (disposing) file.Dispose(); base.Dispose(disposing); }
}
