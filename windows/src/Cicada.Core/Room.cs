namespace Cicada;

public static class ListenSource
{
    public const string System = "system", Room = "room", Both = "both";
    public static string Parse(string? s) => s is Room or Both ? s : System;
}

public static class RoomMicPlan
{
    public sealed record Input(string Id, bool Bluetooth = false, bool Virtual = false);

    public static string? Pick(string? defaultId, IReadOnlyList<Input> inputs)
    {
        if (inputs.FirstOrDefault(i => i.Id == defaultId) is { Virtual: false, Bluetooth: false } d) return d.Id;
        return inputs.FirstOrDefault(i => !i.Virtual && !i.Bluetooth)?.Id ?? inputs.FirstOrDefault(i => !i.Virtual)?.Id;
    }
}

public sealed class VoiceGate
{
    public const double Fixed = 0.01, Lowest = 0.0015;
    readonly List<double> quietest = [];
    double second = double.PositiveInfinity, elapsed;

    public double Threshold
    {
        get
        {
            if (quietest.Count < 3) return 0.004;
            var floor = quietest.Order().ElementAt(quietest.Count / 5);
            return Math.Min(Fixed, Math.Max(Lowest, floor * 2));
        }
    }

    public bool Voiced(double rms, double seconds)
    {
        var on = rms >= Threshold;
        second = Math.Min(second, rms);
        elapsed += seconds;
        if (elapsed >= 1 - 1e-9)
        {
            quietest.Add(second);
            if (quietest.Count > 30) quietest.RemoveAt(0);
            second = double.PositiveInfinity;
            elapsed = 0;
        }
        return on;
    }
}

public sealed class GatedSource : IAudioSource
{
    readonly IAudioSource inner;
    public Func<bool>? Silenced { get; set; }
    public Action<double, double>? Heard { get; set; }
    public volatile bool Muted;
    public event Action<short[]>? Samples;
    public event Action<string?>? Ended;
    public string? Name { get; init; }

    public GatedSource(IAudioSource inner)
    {
        this.inner = inner;
        inner.Samples += buf =>
        {
            if (Heard is { } heard && buf.Length > 0)
            {
                double sum = 0;
                foreach (var v in buf) sum += (double)v * v;
                heard(Math.Sqrt(sum / buf.Length) / 32768, buf.Length / 16000.0);
            }
            Samples?.Invoke(Muted || Silenced?.Invoke() == true ? new short[buf.Length] : buf);
        };
        inner.Ended += why => Ended?.Invoke(why);
    }

    public void Start() => inner.Start();
    public void Stop() => inner.Stop();
}
