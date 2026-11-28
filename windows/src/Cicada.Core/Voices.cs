namespace Cicada;

/// audio becomes a voiceprint (WeSpeaker ResNet34-LM, VoxCeleb, CC BY 4.0, compressed to int8 by
public interface IVoiceprint
{
    float[]? Embed(short[] samples);
}

public static class Fbank
{
    public const int Bins = 80, FrameLength = 400, Shift = 160, FftSize = 512;
    public const double MinSeconds = 0.5, MaxSeconds = 20;

    static readonly double[] window = Enumerable.Range(0, FrameLength).Select(i => Math.Pow(0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (FrameLength - 1)), 0.85)).ToArray();

    static readonly double[,] banks = MakeBanks();

    static double[,] MakeBanks()
    {
        static double Mel(double f) => 1127 * Math.Log(1 + f / 700);
        int cols = FftSize / 2 + 1;
        double lo = Mel(20), hi = Mel(8000), delta = (hi - lo) / (Bins + 1);
        var w = new double[Bins, cols];
        for (int m = 0; m < Bins; m++)
        {
            double left = lo + m * delta, center = left + delta, right = center + delta;
            for (int k = 0; k < FftSize / 2; k++)
            {
                var x = Mel(k * 16000.0 / FftSize);
                var v = Math.Min((x - left) / (center - left), (right - x) / (right - center));
                if (v > 0) w[m, k] = v;
            }
        }
        return w;
    }

    public static float[]? Features(short[] samples)
    {
        if (samples.Length < MinSeconds * 16000) return null;
        int n = Math.Min(samples.Length, (int)(MaxSeconds * 16000));
        int frames = 1 + (n - FrameLength) / Shift;
        if (frames < 50) return null;
        int cols = FftSize / 2 + 1;
        var outp = new float[frames * Bins];
        var re = new double[FftSize]; var im = new double[FftSize];
        var power = new double[cols];
        for (int f = 0; f < frames; f++)
        {
            int start = f * Shift;
            double mean = 0;
            for (int i = 0; i < FrameLength; i++) mean += samples[start + i];
            mean /= FrameLength;
            var frame = new double[FrameLength];
            for (int i = 0; i < FrameLength; i++) frame[i] = samples[start + i] - mean;
            for (int i = FrameLength - 1; i > 0; i--) frame[i] -= 0.97 * frame[i - 1];
            frame[0] -= 0.97 * frame[0];
            Array.Clear(im);
            for (int i = 0; i < FftSize; i++) re[i] = i < FrameLength ? frame[i] * window[i] : 0;
            Fft(re, im);
            for (int k = 0; k < cols; k++) power[k] = re[k] * re[k] + im[k] * im[k];
            for (int b = 0; b < Bins; b++)
            {
                double e = 0;
                for (int k = 0; k < cols; k++) e += banks[b, k] * power[k];
                outp[f * Bins + b] = (float)Math.Log(Math.Max(e, 1.1920929e-07));
            }
        }
        for (int b = 0; b < Bins; b++)
        {
            double sum = 0;
            for (int f = 0; f < frames; f++) sum += outp[f * Bins + b];
            var m = (float)(sum / frames);
            for (int f = 0; f < frames; f++) outp[f * Bins + b] -= m;
        }
        return outp;
    }

    static void Fft(double[] re, double[] im)
    {
        int n = re.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { (re[i], re[j]) = (re[j], re[i]); (im[i], im[j]) = (im[j], im[i]); }
        }
        for (int len = 2; len <= n; len <<= 1)
        {
            double ang = -2 * Math.PI / len, wr = Math.Cos(ang), wi = Math.Sin(ang);
            for (int i = 0; i < n; i += len)
            {
                double cr = 1, ci = 0;
                for (int k = 0; k < len / 2; k++)
                {
                    int a = i + k, b = a + len / 2;
                    double tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
                    re[b] = re[a] - tr; im[b] = im[a] - ti;
                    re[a] += tr; im[a] += ti;
                    (cr, ci) = (cr * wr - ci * wi, cr * wi + ci * wr);
                }
            }
        }
    }
}

public sealed class VoiceClusterer
{
    public const double NewSeconds = 2.0;
    public const float Join = 0.5f, StartNew = 0.5f;
    readonly List<float[]> sums = [];

    public int? Label(float[] v, double seconds)
    {
        int best = -1; float bestSim = -1;
        for (int i = 0; i < sums.Count; i++)
        {
            float dot = 0, sq = 0;
            for (int k = 0; k < v.Length; k++) { dot += v[k] * sums[i][k]; sq += sums[i][k] * sums[i][k]; }
            var sim = dot / Math.Max(MathF.Sqrt(sq), float.Epsilon);
            if (sim > bestSim) { bestSim = sim; best = i; }
        }
        if (best >= 0 && bestSim >= Join)
        {
            for (int k = 0; k < v.Length; k++) sums[best][k] += v[k];
            return best;
        }
        if (seconds >= NewSeconds && (sums.Count == 0 || bestSim < StartNew))
        {
            sums.Add((float[])v.Clone());
            return sums.Count - 1;
        }
        return null;
    }
}

public static class SpeakerLabels
{
    public const int ShownAfter = 5;

    public static bool Voices { get; set; } = true;

    public static Dictionary<int, string> Names(Session s)
    {
        var outp = new Dictionary<int, string>();
        if (s.VoiceNames is null && s.VoiceGuesses is null) return outp;
        foreach (var (v, n) in VoiceNumbers(s.Lines))
        {
            var key = v.ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (s.VoiceNames?.TryGetValue(key, out var mine) == true) { if (mine.Length > 0) outp[n] = mine; }
            else if (s.VoiceGuesses?.TryGetValue(key, out var g) == true) outp[n] = g.Name;
        }
        return outp;
    }

    public static bool Substantive(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(w => w.Any(char.IsLetter));
        if (words >= 3) return true;
        return text.Count(c => c is >= '一' and <= '鿿' or >= '㐀' and <= '䶿' or >= '぀' and <= 'ヿ' or >= '가' and <= '힣') >= 4;
    }

    public static Dictionary<int, int> VoiceNumbers(IReadOnlyList<TranscriptLine> lines)
    {
        var count = new Dictionary<int, int>();
        var reached = new Dictionary<int, int>();
        for (int i = 0; i < lines.Count; i++)
        {
            var l = lines[i];
            if (l.Speaker != "them" || l.Voice is not { } v || !Substantive(l.Src)) continue;
            count[v] = count.GetValueOrDefault(v) + 1;
            if (count[v] == ShownAfter) reached[v] = i;
        }
        if (reached.Count < 2) return [];
        return reached.OrderBy(kv => kv.Value).Select((kv, n) => (kv.Key, n + 1)).ToDictionary(x => x.Key, x => x.Item2);
    }

    public static Dictionary<string, int> Numbers(IReadOnlyList<TranscriptLine> lines)
    {
        var number = VoiceNumbers(lines);
        var outp = new Dictionary<string, int>();
        foreach (var l in lines)
            if (l.Speaker == "them" && l.Voice is { } v && number.TryGetValue(v, out var n)) outp[l.Id] = n;
        return outp;
    }
}
