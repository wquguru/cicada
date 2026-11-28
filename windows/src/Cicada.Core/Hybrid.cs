namespace Cicada;

public sealed class EchoGate(Func<double>? clock = null)
{
    public const double Hang = 0.4;
    public const double Music = 20;
    public const double StretchGap = 1.5;
    public const double During = 0.15, QuietAfter = 1.0;
    public const double EchoRatio = 3, ClearRatio = 2;
    public const double Enough = 3, Window = 20;

    public readonly Func<double> Clock = clock ?? (() => Environment.TickCount64 / 1000.0);
    readonly object gate = new();
    double until = double.NegativeInfinity, lastLoud = double.NegativeInfinity, stretchStart = double.NegativeInfinity, lastWords = double.NegativeInfinity;
    readonly List<(double t, double rms, double s)> during = [], quiet = [];
    bool echo = true;
    public bool? Forced { get; set; }

    public double LastLoud { get { lock (gate) return lastLoud; } }
    public bool Echo { get { lock (gate) return Forced ?? echo; } }
    public bool PlayingMusic { get { var now = Clock(); lock (gate) return MusicLocked(now); } }
    public bool Closed { get { var now = Clock(); lock (gate) return now < until; } }

    bool MusicLocked(double now) => now - lastLoud <= StretchGap && now - stretchStart >= Music && lastWords < now - Music;

    public void Hold()
    {
        var now = Clock();
        lock (gate)
        {
            if (now - lastLoud > StretchGap) stretchStart = now;
            lastLoud = now;
            if (MusicLocked(now) || !(Forced ?? echo)) return;
            until = Math.Max(until, now + Hang);
        }
    }

    public void HeardWords() { var now = Clock(); lock (gate) lastWords = now; }

    public void RoomLevel(double rms, double seconds)
    {
        var now = Clock();
        lock (gate)
        {
            var since = now - lastLoud;
            if (since <= During) during.Add((now, rms, seconds)); else if (since >= QuietAfter) quiet.Add((now, rms, seconds)); else return;
            during.RemoveAll(b => b.t < now - Window);
            quiet.RemoveAll(b => b.t < now - Window * 3);
            if (Ratio(during.Select(b => (b.rms, b.s)), quiet.Select(b => (b.rms, b.s))) is not { } r) return;
            var was = echo;
            if (r >= EchoRatio) echo = true; else if (r < ClearRatio) echo = false;
            if (was == echo) return;
            Log.Debug($"room echo: {(echo ? "speakers reach the mic" : "none")} (x{r:F1})");
            if (!echo) until = double.NegativeInfinity;
        }
    }

    public static double? Ratio(IEnumerable<(double rms, double s)> during, IEnumerable<(double rms, double s)> quiet)
    {
        var d = during.ToList(); var q = quiet.ToList();
        if (d.Sum(b => b.s) < Enough || q.Sum(b => b.s) < Enough) return null;
        var ds = d.Select(b => b.rms).Order().ToList(); var qs = q.Select(b => b.rms).Order().ToList();
        return ds[ds.Count * 4 / 5] / Math.Max(qs[qs.Count / 5], 0.0002);
    }
}

public static class EchoMatch
{
    public sealed record Heard(string Text, double Start, double End);

    public const double Window = 3.0;
    public const double Hold = 2.5;
    public const double Contained = 0.6;

    public static bool IsEcho(Heard room, IEnumerable<Heard> online)
    {
        var near = online.Where(o => o.End >= room.Start - Window && o.Start <= room.End + Window).ToList();
        if (near.Count == 0) return false;
        var r = Units(room.Text);
        if (r.Count == 0) return false;
        var o = near.Select(n => Units(n.Text)).ToList();
        if (r.Count <= 2) return o.Any(x => x.SequenceEqual(r));
        var mine = Pairs(r).ToHashSet();
        var theirs = o.SelectMany(Pairs).ToHashSet();
        return (double)mine.Count(theirs.Contains) / mine.Count >= Contained;
    }

    public static List<string> Units(string text)
    {
        var output = new List<string>();
        var word = new System.Text.StringBuilder();
        foreach (var rune in text.ToLowerInvariant().EnumerateRunes())
        {
            if (Cjk(rune.Value))
            {
                if (word.Length > 0) { output.Add(word.ToString()); word.Clear(); }
                output.Add(rune.ToString());
            }
            else if (System.Text.Rune.IsLetterOrDigit(rune)) word.Append(rune.ToString());
            else if (word.Length > 0) { output.Add(word.ToString()); word.Clear(); }
        }
        if (word.Length > 0) output.Add(word.ToString());
        return output;
    }

    static IEnumerable<string> Pairs(List<string> u) => u.Count < 2 ? u : Enumerable.Range(1, u.Count - 1).Select(i => u[i - 1] + " " + u[i]);

    static bool Cjk(int v) => v is >= 0x3040 and <= 0x30FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF or >= 0xF900 and <= 0xFAFF;
}

public sealed class EchoFilter(EchoGate gate)
{
    public readonly EchoGate Gate = gate;
    readonly List<EchoMatch.Heard> online = [];

    public void Online(EchoMatch.Heard h)
    {
        lock (online)
        {
            online.Add(h);
            online.RemoveAll(o => o.End < h.End - 20);
        }
    }

    public bool IsEcho(EchoMatch.Heard room) { lock (online) return EchoMatch.IsEcho(room, online); }

    public bool Quiet(EchoMatch.Heard room) => Gate.LastLoud < room.Start - EchoMatch.Window;
}

public static class Places
{
    public static bool HeardBoth(IEnumerable<TranscriptLine> lines)
    {
        bool room = false, computer = false;
        foreach (var l in lines)
        {
            if (l.Speaker != "them") continue;
            if (l.Via == "room") room = true; else computer = true;
            if (room && computer) return true;
        }
        return false;
    }

    public static HashSet<string> Starts(IEnumerable<TranscriptLine> lines)
    {
        var output = new HashSet<string>();
        string? last = "\0";
        foreach (var l in lines)
        {
            var key = l.Speaker == "me" ? "me" : l.Via;
            if (l.Speaker != "me" && key != last) output.Add(l.Id);
            last = key;
        }
        return output;
    }

    public static string Place(TranscriptLine l) => l.Via == "room" ? Strings.L("现场") : Strings.L("线上");
}
