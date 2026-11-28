using System.Text;

namespace Cicada;

public sealed class VoiceReference(IKeyProtector protector, string? folder = null)
{
    public const double MinSeconds = 10, MaxSeconds = 15;

    public string Folder => folder ?? Path.Combine(Paths.Root, "voice");
    public string AudioFile => Path.Combine(Folder, "reference.wav");
    public string TextFile => Path.Combine(Folder, "reference.txt");

    const string Sealed = "dpapi:";
    readonly object gate = new();
    (DateTime at, byte[]? wav, string? text)? cache;

    public event Action? Changed;

    public bool Exists => Load() is { wav: not null, text: { Length: > 0 } };
    public string? Text => Load().text;
    public byte[]? Wav => Load().wav;

    public double Duration => Wav is { } w ? Math.Max(0, w.Length - 44) / 32000.0 : 0;

    public (string Audio, string Text)? Reference() =>
        Load() is { wav: { } w, text: { Length: > 0 } t } ? ("data:audio/wav;base64," + Convert.ToBase64String(w), t) : null;

    (byte[]? wav, string? text) Load()
    {
        lock (gate)
        {
            var at = File.Exists(AudioFile) ? File.GetLastWriteTimeUtc(AudioFile) : DateTime.MinValue;
            if (cache is { } c && c.at == at) return (c.wav, c.text);
            byte[]? wav = null; string? text = null;
            try
            {
                if (File.Exists(AudioFile) && File.Exists(TextFile))
                {
                    wav = Open(File.ReadAllText(AudioFile));
                    text = Open(File.ReadAllText(TextFile)) is { } t ? Encoding.UTF8.GetString(t).Trim() : null;
                }
            }
            catch (Exception e) { Log.Debug($"voice clone: read failed {e.GetType().Name}"); wav = null; text = null; }
            cache = (at, wav, text);
            return (wav, text);
        }
    }

    byte[]? Open(string body) =>
        body.StartsWith(Sealed) ? (protector.Tag == "plain" ? Convert.FromBase64String(body[Sealed.Length..]) : protector.Unprotect(Convert.FromBase64String(body[Sealed.Length..]))) : null;

    string Seal(byte[] data) => Sealed + Convert.ToBase64String(protector.Tag == "plain" ? data : protector.Protect(data));

    public void Save(byte[] wav, string text)
    {
        wav = VoicePace.Trim(wav);
        lock (gate)
        {
            Directory.CreateDirectory(Folder);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(Folder, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            File.WriteAllText(TextFile, Seal(Encoding.UTF8.GetBytes(text.Trim())));
            File.WriteAllText(AudioFile, Seal(wav));
            if (!OperatingSystem.IsWindows())
                foreach (var f in new[] { AudioFile, TextFile }) File.SetUnixFileMode(f, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            cache = null;
            slow = null;
        }
        Changed?.Invoke();
    }

    public void Remove()
    {
        lock (gate)
        {
            try { if (Directory.Exists(Folder)) Directory.Delete(Folder, true); } catch (Exception e) { Log.Debug($"voice clone: remove failed {e.GetType().Name}"); }
            cache = null;
            slow = null;
        }
        Changed?.Invoke();
    }

    (DateTime at, bool slow)? slow;

    public bool SavedIsSlow
    {
        get
        {
            var at = File.Exists(AudioFile) ? File.GetLastWriteTimeUtc(AudioFile) : DateTime.MinValue;
            if (slow is { } s && s.at == at) return s.slow;
            var result = Load() is { wav: { } w, text: { } t } && VoicePace.Pace(t, VoicePace.Samples(w), 16000) is { } p && VoicePace.IsSlow(t, p);
            slow = (at, result);
            return result;
        }
    }
}

public static class VoicePace
{
    public const double SlowCharacters = 2.5, SlowWords = 1.6;

    public static double? Pace(string text, float[] samples, double sampleRate)
    {
        var units = Tokens(text).Count;
        if (units == 0 || SpeechSpan(samples, sampleRate) is not { } span || span <= 0.5) return null;
        return units / span;
    }

    public static bool IsSlow(string text, double pace)
    {
        var tokens = Tokens(text);
        var characters = tokens.Count(t => t.Any(IsCjk));
        return pace < (characters * 2 >= tokens.Count ? SlowCharacters : SlowWords);
    }

    public static double? SpeechSpan(float[] samples, double sampleRate) =>
        SpeechWindows(samples, sampleRate) is var (first, last, size) ? (last - first + 1) * (double)size / sampleRate : null;

    public const double TrimPad = 0.2;

    public static byte[] Trim(byte[] wav, int rate = 16000)
    {
        var start = wav.Length >= 44 && wav[0] == 'R' && wav[1] == 'I' ? 44 : 0;
        if (SpeechWindows(Samples(wav), rate) is not var (first, last, size)) return wav;
        var pad = (int)(TrimPad * rate);
        var n = (wav.Length - start) / 2;
        int from = Math.Max(0, first * size - pad), to = Math.Min(n, (last + 1) * size + pad);
        var pcm = new short[to - from];
        Buffer.BlockCopy(wav, start + from * 2, pcm, 0, pcm.Length * 2);
        return Cicada.Wav.Bytes(pcm, rate);
    }

    static (int first, int last, int size)? SpeechWindows(float[] samples, double sampleRate)
    {
        var size = Math.Max(1, (int)(sampleRate * 0.02));
        var levels = new List<float>();
        for (var i = 0; i < samples.Length; i += size)
        {
            var end = Math.Min(samples.Length, i + size);
            float sum = 0;
            for (var k = i; k < end; k++) sum += samples[k] * samples[k];
            levels.Add(MathF.Sqrt(sum / (end - i)));
        }
        if (levels.Count == 0) return null;
        var loudest = levels.Max();
        if (loudest <= 0.003f) return null;
        var floor = loudest * 0.0178f;
        return (levels.FindIndex(l => l >= floor), levels.FindLastIndex(l => l >= floor), size);
    }

    public static List<string> Tokens(string text)
    {
        var out_ = new List<string>();
        var word = new StringBuilder();
        void Flush() { if (word.Length > 0) { out_.Add(word.ToString().ToLowerInvariant()); word.Clear(); } }
        foreach (var ch in text)
        {
            if (IsCjk(ch)) { Flush(); out_.Add(ch.ToString()); }
            else if (char.IsLetterOrDigit(ch) || ch == '\'' || ch == '’') word.Append(ch == '’' ? '\'' : ch);
            else Flush();
        }
        Flush();
        return out_;
    }

    public static bool IsCjk(char c) => c is (>= '぀' and <= 'ヿ') or (>= '㐀' and <= '䶿') or (>= '一' and <= '鿿') or (>= '가' and <= '힯') or (>= '豈' and <= '﫿');

    public static float[] Samples(byte[] wav)
    {
        var start = wav.Length >= 44 && wav[0] == 'R' && wav[1] == 'I' ? 44 : 0;
        var n = (wav.Length - start) / 2;
        var out_ = new float[n];
        for (var i = 0; i < n; i++) out_[i] = BitConverter.ToInt16(wav, start + i * 2) / 32768f;
        return out_;
    }
}

public static class VoiceCloneCheck
{
    public enum Outcome { Ready, TooShort, NotHeard, Slow }

    public static async Task<(Outcome outcome, string text, byte[] wav)> Check(byte[] recorded, Func<byte[], Task<string?>> transcribe)
    {
        var wav = VoicePace.Trim(recorded);
        var (outcome, text) = await CheckTrimmed(wav, transcribe);
        return (outcome, text, wav);
    }

    static async Task<(Outcome outcome, string text)> CheckTrimmed(byte[] wav, Func<byte[], Task<string?>> transcribe)
    {
        var seconds = Math.Max(0, wav.Length - 44) / 32000.0;
        if (seconds < VoiceReference.MinSeconds) return (Outcome.TooShort, "");
        string? text = null;
        try { text = await transcribe(wav); } catch (LingException e) { Log.Debug($"voice clone: hearing failed {e.Message}"); }
        text = text?.Trim() ?? "";
        if (text.Length < 6) return (Outcome.NotHeard, text);
        var pace = VoicePace.Pace(text, VoicePace.Samples(wav), 16000);
        Log.Debug($"voice clone: {text.Length} chars, {seconds:F1} s, pace {(pace is { } p ? p.ToString("F1", System.Globalization.CultureInfo.InvariantCulture) : "-")}/s");
        if (pace is { } q && VoicePace.IsSlow(text, q)) return (Outcome.Slow, text);
        return (Outcome.Ready, text);
    }

    public static string Passage(string language) => VoiceCatalog.Key(language) switch
    {
        "zh" => "大家好，我是这次会议的主持人。今天我们主要讨论新产品的上线计划，包括时间安排、测试范围和市场推广。请大家先看一下屏幕上的议程。",
        "ja" => "皆さん、こんにちは。今日の会議では、新製品の発売計画について話し合います。スケジュール、テストの範囲、そしてマーケティングについて順番に確認しましょう。",
        _ => "Hello everyone, thanks for joining. Today we'll walk through the launch plan for the new product: the schedule, what we still need to test, and how we'll tell people about it. Let's start with the agenda on the screen.",
    };
}
