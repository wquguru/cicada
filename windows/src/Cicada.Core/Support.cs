using System.Text;
using System.Globalization;

namespace Cicada;

public static class Paths
{
    public static bool Dev { get; set; } = Environment.GetEnvironmentVariable("CICADA_DEV") == "1";

    public static string Root
    {
        get
        {
            var home = Environment.GetEnvironmentVariable("CICADA_HOME");
            if (!string.IsNullOrEmpty(home)) return home;
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(appData, Dev ? "Cicada Dev" : "Cicada");
        }
    }

    public static string Sessions => Path.Combine(Root, "Sessions");
    public static string Settings => Path.Combine(Root, "settings.json");
    public static string KeyFile(string service = "ling") => Path.Combine(Root, service == "ling" ? "ling-api-key" : "ai-key-" + service);
    public static string Log => Path.Combine(Path.GetTempPath(), Dev ? "cicada-dev-debug.log" : "cicada-debug.log");
}

public static class Log
{
    static readonly object Gate = new();
    public static bool Echo { get; set; }

    public static void Debug(string message)
    {
        var line = $"{DateTime.Now:HH:mm:ss.fff} {message}";
        lock (Gate)
        {
            try { File.AppendAllText(Paths.Log, line + Environment.NewLine); } catch { }
            if (Echo) Console.Error.WriteLine(line);
        }
    }
}

public sealed record Lang(string Name, string Code);

public static class Languages
{
    public static readonly Lang[] Sources =
    [
        new("English", "en"), new("日本語", "ja"), new("中文", "zh-CN"), new("한국어", "ko"),
        new("Español", "es"), new("Français", "fr"), new("Deutsch", "de"), new("Português", "pt"),
    ];

    public static readonly Lang[] Targets =
    [
        new("简体中文", "zh-CN"), new("繁體中文", "zh-TW"), new("English", "en"), new("日本語", "ja"),
        new("한국어", "ko"), new("Español", "es"), new("Français", "fr"), new("Deutsch", "de"), new("Português", "pt"),
    ];

    public static string EnglishName(string code) => code switch
    {
        "zh-CN" => "Simplified Chinese",
        "zh-TW" => "Traditional Chinese",
        _ => TryCulture(code)?.EnglishName ?? code,
    };

    static CultureInfo? TryCulture(string code)
    {
        try { return CultureInfo.GetCultureInfo(code); } catch { return null; }
    }

    public static string FromSystem(string name)
    {
        var parts = name.Split('-');
        if (parts[0] != "zh") return parts[0];
        return parts.Contains("Hant") || parts.Contains("TW") || parts.Contains("HK") || parts.Contains("MO") ? "zh-TW" : "zh-CN";
    }

    public static string Normalize(string? reported, string fallback)
    {
        if (string.IsNullOrWhiteSpace(reported)) return fallback;
        var r = reported.Trim().Trim('.', '`', '"');
        var head = r.Split('-', '_')[0].ToLowerInvariant();
        if (head is "zh" or "cmn" or "yue")
            return r.Contains("TW", StringComparison.OrdinalIgnoreCase) || r.Contains("Hant", StringComparison.OrdinalIgnoreCase) ? "zh-TW" : "zh-CN";
        return head.Length is 2 or 3 ? head : fallback;
    }

    static bool IsCjk(Rune r) => r.Value is >= 0x3040 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF;

    public static bool InScript(string text, string target)
    {
        int letters = 0, cjk = 0;
        foreach (var r in text.EnumerateRunes())
        {
            if (!Rune.IsLetter(r)) continue;
            letters++;
            if (IsCjk(r)) cjk++;
        }
        if (letters == 0) return true;
        bool wantsCjk = target.StartsWith("zh") || target.StartsWith("ja") || target.StartsWith("ko");
        return wantsCjk ? cjk > 0 : cjk * 2 <= letters;
    }

    public static bool WrittenIn(string text, string englishLanguage)
    {
        int letters = 0, cjk = 0;
        foreach (var r in text.EnumerateRunes())
        {
            if (!Rune.IsLetter(r)) continue;
            letters++;
            if (IsCjk(r)) cjk++;
        }
        if (letters == 0) return true;
        bool wantsCjk = englishLanguage.Contains("Chinese") || englishLanguage.Contains("Japanese") || englishLanguage.Contains("Korean");
        return wantsCjk ? cjk * 5 >= letters : cjk * 2 < letters;
    }

    public static string Clock(double t)
    {
        int s = (int)Math.Max(0, t);
        return s >= 3600 ? $"{s / 3600}:{s / 60 % 60:00}:{s % 60:00}" : $"{s / 60:00}:{s % 60:00}";
    }
}
