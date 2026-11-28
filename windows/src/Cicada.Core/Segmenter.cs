namespace Cicada;

public sealed record Segment(int Index, double Start, short[] Samples)
{
    public double Seconds => Samples.Length / (double)Segmenter.Rate;
}

public sealed class Segmenter
{
    public const int Rate = 16000;
    const int Frame = 480;
    const int Step10 = 160;
    const int Onset = 3;
    public static double Threshold = 0.01;
    public static double Pause = 0.6, MaxLength = 8.0, MinSpeech = 0.25;
    public static double MinWord = 0.2;
    public static double Steady = 2.0;
    public static double Dips = 2.5;
    public static double Short = 2.0;
    public static double Swell = Math.Pow(10, 10 / 20.0);
    public static double Fade = Math.Pow(10, 30 / 20.0);
    public static double Voiced = 0.15;
    public static double Above = 0.25;
    const double PreRoll = 0.15, Tail = 0.15, CutWindow = 2.0;
    static readonly double HighPass = 1.0 / (1.0 + 2.0 * Math.PI * 100.0 / Rate);

    readonly List<short> pending = [];
    readonly List<short> current = [];
    readonly List<double> levels = [];
    readonly List<double> highs = [];
    readonly List<bool> speech = [];
    double hx, hy;
    readonly Queue<(short[] frame, double level, double high)> before = new();
    readonly Queue<double> idle = new();
    double? lead;
    long consumed;
    double currentStart;
    int quietFrames, loudFrames, index;
    int sounding;
    bool carried;
    public VoiceGate? Gate { get => gate; set => gate = value; }
    volatile VoiceGate? gate;
    double line = Threshold;

    public Segmenter(VoiceGate? gate = null) { this.gate = gate; }

    public double Line => line;

    public event Action<Segment>? Emitted;

    public void Feed(ReadOnlySpan<short> samples)
    {
        foreach (var s in samples) pending.Add(s);
        int whole = pending.Count / Frame * Frame;
        for (int i = 0; i < whole; i += Frame)
        {
            var frame = pending.GetRange(i, Frame).ToArray();
            Step(frame);
        }
        pending.RemoveRange(0, whole);
    }

    public void Flush()
    {
        if (current.Count > 0) Close(current.Count - quietFrames * Frame + (int)(Tail * Rate));
    }

    static double Rms(short[] frame)
    {
        double sum = 0;
        foreach (var s in frame) sum += (double)s * s;
        return Math.Sqrt(sum / frame.Length) / 32768;
    }

    bool IsSpeech(short[] frame, double level, VoiceGate? g)
    {
        if (g is not null)
        {
            bool on = g.Voiced(level, Frame / (double)Rate);
            sounding = on ? sounding + Frame / Step10 : 0;
            carried = false;
            return on;
        }
        bool said = false, early = sounding > 0;
        for (int i = 0; i < frame.Length; i += Step10)
        {
            int end = Math.Min(frame.Length, i + Step10);
            double sum = 0;
            for (int k = i; k < end; k++) sum += (double)frame[k] * frame[k];
            if (Math.Sqrt(sum / (end - i)) / 32768 >= line)
            {
                if (++sounding >= Onset && !said) { said = true; carried = early; }
            }
            else { sounding = 0; early = false; }
        }
        return said;
    }

    void Step(short[] frame)
    {
        double level = Rms(frame);
        double high = High(frame);
        var g = gate;
        line = g?.Threshold ?? Threshold;
        bool loud = IsSpeech(frame, level, g);
        double now = consumed / (double)Rate;
        consumed += frame.Length;

        if (current.Count == 0)
        {
            if (!loud)
            {
                idle.Enqueue(level);
                while (idle.Count > (int)(Pause * Rate / Frame)) idle.Dequeue();
                before.Enqueue((frame, level, high));
                while (before.Count > PreRoll * Rate / Frame + 1) before.Dequeue();
                return;
            }
            while (before.Count > PreRoll * Rate / Frame + (carried ? 1 : 0)) before.Dequeue();
            currentStart = now - before.Count * Frame / (double)Rate;
            lead = idle.Count > 0 ? idle.Min() : null;
            idle.Clear();
            foreach (var (f, l, h) in before) { current.AddRange(f); levels.Add(l); highs.Add(h); speech.Add(false); }
            before.Clear();
            quietFrames = 0; loudFrames = 0;
        }

        current.AddRange(frame);
        levels.Add(level);
        highs.Add(high);
        speech.Add(loud);
        if (loud) { quietFrames = 0; loudFrames++; } else quietFrames++;

        if (quietFrames * Frame >= Pause * Rate)
        {
            Close(current.Count - quietFrames * Frame + (int)(Tail * Rate));
        }
        else if (current.Count >= MaxLength * Rate)
        {
            int from = Math.Max(1, levels.Count - (int)(CutWindow * Rate / Frame));
            int cut = from;
            for (int i = from; i < levels.Count; i++) if (levels[i] < levels[cut]) cut = i;
            Close(cut * Frame);
        }
    }

    internal static bool IsSteady(IEnumerable<double> frameLevels, double? gate = null)
    {
        var all = frameLevels.ToList();
        var threshold = gate ?? Threshold;
        int first = all.FindIndex(l => l >= threshold), last = all.FindLastIndex(l => l >= threshold);
        if (first < 0 || last <= first) return false;
        var body = all.GetRange(first, last - first + 1);
        var top = body.Select(l => Math.Max(l, threshold)).Order().ToList();
        if (top[(int)(0.9 * (top.Count - 1))] >= Steady * top[(int)(0.1 * (top.Count - 1))]) return false;
        var low = body.Select(l => Math.Max(l, threshold / 8)).Order().ToList();
        return low[(int)(0.5 * (low.Count - 1))] < Dips * low[(int)(0.1 * (low.Count - 1))];
    }

    internal bool IsWord(List<double> frameLevels, double gate)
    {
        int first = frameLevels.FindIndex(l => l >= gate), last = frameLevels.FindLastIndex(l => l >= gate);
        if (first < 0 || (last - first + 1) * Frame > Short * Rate) return false;
        double quiet = gate / 4;
        if (lead is not { } q || q > quiet || last + 1 >= frameLevels.Count || frameLevels.Skip(last + 1).Min() > quiet) return false;
        var steps = new List<double>();
        for (int i = 0; i + Step10 <= current.Count; i += Step10)
        {
            double sum = 0;
            for (int k = i; k < i + Step10; k++) sum += (double)current[k] * current[k];
            steps.Add(Math.Sqrt(sum / Step10) / 32768);
        }
        double rise = Math.Min(quiet, steps.Max() / Fade);
        int from = steps.FindIndex(l => l >= rise), to = steps.FindLastIndex(l => l >= rise);
        var body = steps.GetRange(from, to - from + 1).Select(l => Math.Max(l, gate / 8)).Order().ToList();
        int low = Math.Max(2, (int)(0.05 * (body.Count - 1)));
        return low < body.Count && body[(int)(0.9 * (body.Count - 1))] >= Swell * body[low] && IsVoiced(frameLevels);
    }

    bool IsVoiced(List<double> frameLevels)
    {
        double full = frameLevels.Order().ElementAt((int)(0.9 * (frameLevels.Count - 1))) / Math.Sqrt(2);
        int slow = 0;
        for (int i = 0; i < frameLevels.Count; i++)
        {
            if (frameLevels[i] < full) continue;
            int start = i * Frame, end = Math.Min(current.Count, start + Frame), crossings = 0;
            for (int k = start + 1; k < end; k++) if (current[k] >= 0 != current[k - 1] >= 0) crossings++;
            if (crossings < Voiced * (end - start - 1)) slow++;
        }
        return slow >= 2;
    }

    double High(short[] frame)
    {
        double a = HighPass, x0 = hx, y = hy, total = 0;
        foreach (var s in frame)
        {
            double x = s;
            y = a * (y + x - x0);
            x0 = x;
            total += y * y;
        }
        hx = x0; hy = y;
        return frame.Length == 0 ? 0 : Math.Sqrt(total / frame.Length) / 32768;
    }

    internal static bool IsRumble(List<double> frameLevels, List<double> frameHighs, double gate)
    {
        double full = 0, above = 0;
        for (int i = 0; i < frameLevels.Count && i < frameHighs.Count; i++)
        {
            if (frameLevels[i] < gate) continue;
            full += frameLevels[i] * frameLevels[i];
            above += frameHighs[i] * frameHighs[i];
        }
        return above < Above * full;
    }

    void Close(int end)
    {
        end = Math.Clamp(end, 0, current.Count);
        var samples = current.GetRange(0, end).ToArray();
        var rest = current.GetRange(end, current.Count - end);
        var restLevels = levels.GetRange(end / Frame, levels.Count - end / Frame);
        var restHighs = highs.GetRange(end / Frame, highs.Count - end / Frame);
        var restSpeech = speech.GetRange(end / Frame, speech.Count - end / Frame);
        double start = currentStart;
        var sent = levels.GetRange(0, Math.Min(levels.Count, end / Frame));
        bool said = IsWord(levels, line)
            ? sent.Count(l => l >= line / 4) * Frame >= MinWord * Rate
            : loudFrames * Frame >= MinSpeech * Rate && !IsSteady(sent, line);
        said = said && !IsRumble(sent, highs.GetRange(0, sent.Count), line);
        current.Clear(); levels.Clear(); highs.Clear(); speech.Clear();
        quietFrames = 0; loudFrames = 0;
        if (said) Emitted?.Invoke(new Segment(++index, Math.Round(start, 3), samples));

        if (restSpeech.Contains(true))
        {
            currentStart = start + end / (double)Rate;
            lead = null;
            current.AddRange(rest);
            levels.AddRange(restLevels);
            highs.AddRange(restHighs);
            speech.AddRange(restSpeech);
            int trailing = 0;
            for (int i = speech.Count - 1; i >= 0 && !speech[i]; i--) trailing++;
            quietFrames = trailing;
            loudFrames = speech.Count(v => v);
        }
    }
}
