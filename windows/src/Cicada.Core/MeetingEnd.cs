namespace Cicada;

public sealed class MeetingEndWatch
{
    public enum Silence { Prompt, End, Off }

    public sealed record Config(bool FollowApps = true, Silence Silence = Silence.Prompt, double SilenceAfter = 600,
                                double Countdown = 60, double AppGrace = 30);

    public sealed record Reason(string Kind, string Name = "")
    {
        public static readonly Reason SilenceEnd = new("silence");
        public static readonly Reason Nobody = new("nobody");
        public static Reason AppLeft(string name) => new("app", name);
        public override string ToString() => Name.Length > 0 ? $"{Kind}({Name})" : Kind;
    }

    public sealed record Pending(Reason Reason, DateTimeOffset Deadline);

    public Config Settings;
    public Pending? Waiting { get; private set; }
    public DateTimeOffset LastSpeech { get; private set; }
    public Dictionary<string, string> InCall { get; private set; } = [];

    public MeetingEndWatch(Config config, DateTimeOffset start)
    {
        Settings = config;
        LastSpeech = start;
    }

    public void Heard(DateTimeOffset now)
    {
        LastSpeech = now;
        if (Waiting?.Reason.Kind == "silence") Waiting = null;
    }

    public void KeepGoing(DateTimeOffset now)
    {
        Waiting = null;
        LastSpeech = now;
        InCall = [];
    }

    public Reason? Tick(DateTimeOffset now, IReadOnlyDictionary<string, string> calls, bool said)
    {
        var c = Settings;
        bool inACall = c.FollowApps && calls.Count > 0;
        double silent = (now - LastSpeech).TotalSeconds;
        if (!said)
        {
            InCall = c.FollowApps ? new Dictionary<string, string>(calls) : [];
            Waiting = null;
            return c.Silence != Silence.Off && !inACall && silent >= c.SilenceAfter ? Reason.Nobody : null;
        }
        bool appWaiting = Waiting?.Reason.Kind == "app";
        if (c.FollowApps)
        {
            foreach (var (id, name) in calls) InCall[id] = name;
            bool hungUp = InCall.Count > 0 && InCall.Keys.All(k => !calls.ContainsKey(k));
            if (appWaiting && !hungUp) Waiting = null;
            if (hungUp && (Waiting is null || Waiting.Reason.Kind == "silence"))
            {
                var name = InCall.OrderBy(p => p.Key, StringComparer.Ordinal).First().Value;
                Waiting = new Pending(Reason.AppLeft(name), now.AddSeconds(c.AppGrace));
            }
        }
        else if (appWaiting) Waiting = null;
        if (Waiting is null && c.Silence != Silence.Off && !inACall && silent >= c.SilenceAfter)
        {
            if (c.Silence == Silence.End) return Reason.SilenceEnd;
            Waiting = new Pending(Reason.SilenceEnd, now.AddSeconds(c.Countdown));
        }
        if ((c.Silence == Silence.Off || inACall) && Waiting?.Reason.Kind == "silence") Waiting = null;
        if (Waiting is { } p && now >= p.Deadline)
        {
            Waiting = null;
            return p.Reason;
        }
        return null;
    }

    public static Silence ParseSilence(string s) => s switch { "end" => Silence.End, "off" => Silence.Off, _ => Silence.Prompt };
}

public static class MicUse
{
    static readonly (string Key, string Name)[] Apps =
    [
        ("zoom.exe", "Zoom"), ("wemeetapp.exe", "腾讯会议"), ("feishu.exe", "飞书"), ("lark.exe", "Lark"),
        ("dingtalk.exe", "钉钉"), ("wxwork.exe", "企业微信"), ("teams.exe", "Teams"), ("ms-teams.exe", "Teams"), ("msteams_", "Teams"),
        ("ciscocollabhost.exe", "Webex"), ("webex.exe", "Webex"), ("cisco.webex", "Webex"),
    ];

    public static Dictionary<string, string> Calls(IEnumerable<(string Key, long LastUsedTimeStop)> entries)
    {
        var byName = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, stop) in entries)
        {
            if (stop != 0) continue;
            var program = key.Split('#', '\\').Last().ToLowerInvariant();
            foreach (var (k, name) in Apps)
            {
                if (k.EndsWith('_') ? program.StartsWith(k, StringComparison.Ordinal) : program == k)
                {
                    if (!byName.ContainsKey(name)) byName[name] = k.TrimEnd('_');
                    break;
                }
            }
        }
        return byName.ToDictionary(p => p.Value, p => p.Key);
    }
}
