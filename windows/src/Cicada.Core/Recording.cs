namespace Cicada;

public interface IAudioFiles
{
    IAudioWriter? Open(string path);
    bool Rewrap(string from, string to, double? until);
}

public interface IAudioWriter
{
    void Write(ReadOnlySpan<short> pcm);
    void Close();
}

public sealed class RoomMix(IAudioWriter writer) : IAudioWriter
{
    const int Delay = Segmenter.Rate;
    const int Limit = 30 * Segmenter.Rate;
    readonly object gate = new();
    readonly List<short> pc = [], room = [];
    long at, roomAt;
    bool closed;

    public void Write(ReadOnlySpan<short> pcm)
    {
        short[] output;
        lock (gate)
        {
            if (closed) return;
            pc.AddRange(pcm);
            output = Take(pc.Count - Delay);
        }
        if (output.Length > 0) writer.Write(output);
    }

    public void Room(ReadOnlySpan<short> pcm, long start)
    {
        lock (gate)
        {
            if (closed) return;
            var end = roomAt + room.Count;
            if (room.Count == 0) roomAt = start;
            else if (start > end) room.AddRange(new short[start - end]);
            else if (start < end) pcm = pcm[(int)Math.Min(end - start, pcm.Length)..];
            room.AddRange(pcm);
            Drop(at);
            if (room.Count > Limit) { roomAt += room.Count - Limit; room.RemoveRange(0, room.Count - Limit); }
        }
    }

    public void Close()
    {
        List<short> output;
        lock (gate)
        {
            if (closed) return;
            closed = true;
            output = [.. Take(pc.Count)];
            if (room.Count > 0 && roomAt >= at)
            {
                output.AddRange(new short[roomAt - at]);
                output.AddRange(room);
                room.Clear();
            }
        }
        if (output.Count > 0) writer.Write(output.ToArray());
        writer.Close();
    }

    void Drop(long upto)
    {
        var late = (int)Math.Min(room.Count, upto - roomAt);
        if (late <= 0) return;
        room.RemoveRange(0, late);
        roomAt += late;
    }

    short[] Take(int n)
    {
        if (n <= 0) return [];
        var output = pc.GetRange(0, n).ToArray();
        pc.RemoveRange(0, n);
        var start = at;
        at += n;
        Drop(start);
        if (room.Count > 0 && roomAt < at)
        {
            var off = (int)(roomAt - start);
            var k = (int)Math.Min(room.Count, at - roomAt);
            for (int i = 0; i < k; i++) output[off + i] = (short)Math.Clamp(output[off + i] + room[i], short.MinValue, short.MaxValue);
            room.RemoveRange(0, k);
            roomAt += k;
        }
        return output;
    }
}

public static class Recording
{
    public static string SystemAudio(string sessionId) => Path.Combine(Paths.Sessions, sessionId, "system.m4a");
    public static string Partial(string m4a) => Path.ChangeExtension(m4a, ".aac");

    public static string? Playable(Session s)
    {
        var own = SystemAudio(s.Id);
        if (File.Exists(own)) return own;
        if (s.SourcePath is { Length: > 0 } p && File.Exists(p)) return p;
        return null;
    }

    public static int Behind(double at, long fed, int count)
    {
        var lag = at - (fed + count) / (double)Segmenter.Rate;
        return lag >= LoopbackGap.Late ? (int)(lag * Segmenter.Rate) : 0;
    }
}
