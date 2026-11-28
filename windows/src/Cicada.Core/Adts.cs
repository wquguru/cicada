namespace Cicada;

public static class Adts
{
    public readonly record struct Frame(int Offset, int Length);

    public sealed record Config(int ObjectType, int Rate, int Channels, byte[] SpecificConfig);

    static readonly int[] Rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

    public static Config? Read(ReadOnlySpan<byte> file)
    {
        int at = Sync(file, 0);
        if (at < 0 || file.Length - at < 7) return null;
        var h = file[at..];
        int obj = (h[2] >> 6) + 1, index = (h[2] >> 2) & 0xF, channels = ((h[2] & 1) << 2) | (h[3] >> 6);
        if (index >= Rates.Length) return null;
        byte[] asc = [(byte)((obj << 3) | (index >> 1)), (byte)(((index & 1) << 7) | (channels << 3))];
        return new Config(obj, Rates[index], channels, asc);
    }

    public static List<Frame> Frames(ReadOnlySpan<byte> file)
    {
        var frames = new List<Frame>();
        int at = Sync(file, 0);
        while (at >= 0 && file.Length - at >= 7)
        {
            var h = file[at..];
            int length = ((h[3] & 3) << 11) | (h[4] << 3) | (h[5] >> 5);
            int header = (h[1] & 1) == 1 ? 7 : 9;
            if (length <= header) { at = Sync(file, at + 1); continue; }
            if (at + length > file.Length) break;
            frames.Add(new Frame(at + header, length - header));
            at += length;
            if (at < file.Length && !IsSync(file, at)) at = Sync(file, at);
        }
        return frames;
    }

    static bool IsSync(ReadOnlySpan<byte> f, int i) => i + 1 < f.Length && f[i] == 0xFF && (f[i + 1] & 0xF6) == 0xF0;

    static int Sync(ReadOnlySpan<byte> f, int from)
    {
        for (int i = from; i + 1 < f.Length; i++) if (IsSync(f, i)) return i;
        return -1;
    }
}
