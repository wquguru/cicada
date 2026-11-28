using System.Net.Sockets;
using System.Text.Json.Nodes;

namespace Cicada;

public sealed class AICheck
{
    public enum StepId { Reach, Key, Text, Hear }

    public enum Reason { Unreachable, BadAddress, InvalidKey, MgmtKey, NoCredit, NoModel, NoJSON, Deaf, Busy, ServerError }

    public enum Kind { Running, Ok, Busy, Fail, Skipped, Untested }

    public readonly record struct State(Kind Kind, double? Seconds = null, Reason? Why = null, int? Code = null)
    {
        public static State Ok(double? seconds = null) => new(Kind.Ok, seconds);
        public static State Fail(Reason why, int? code = null) => new(Kind.Fail, null, why, code);
        public static readonly State Busy = new(Kind.Busy);
        public static readonly State Skipped = new(Kind.Skipped);
        public static readonly State Running = new(Kind.Running);
        public static readonly State Untested = new(Kind.Untested);
    }

    public enum ProxyKind { SystemOn, AppRunning, None }

    public readonly record struct ProxyHint(ProxyKind Kind, int Port = 0)
    {
        public override string ToString() => Kind == ProxyKind.AppRunning ? $"appRunning({Port})" : Kind == ProxyKind.SystemOn ? "systemOn" : "none";
    }

    public static readonly StepId[] Order = [StepId.Reach, StepId.Key, StepId.Text, StepId.Hear];

    readonly State[] steps = [State.Untested, State.Untested, State.Untested, State.Untested];
    public DateTimeOffset? At { get; set; }
    public bool Passive { get; set; }
    public ProxyHint? Proxy { get; set; }
    public double? Balance { get; set; }
    public Speed? Translate { get; set; }
    public State? Notes { get; set; }
    public bool NotesFailed => Notes is { Kind: Kind.Fail, Why: not Reason.Busy };

    public readonly record struct Speed(double Seconds, bool Thinks)
    {
        public const double SlowAfter = 3;
        public bool Slow => Thinks || Seconds >= SlowAfter;
    }

    public bool Slow => Failure is null && Translate?.Slow == true;

    public const double LowBalance = 0.5;

    public State this[StepId id]
    {
        get => steps[(int)id];
        set => steps[(int)id] = value;
    }

    public IEnumerable<(StepId Id, State State)> Steps => Order.Select(id => (id, steps[(int)id]));

    public AICheck Clone()
    {
        var c = new AICheck { At = At, Passive = Passive, Proxy = Proxy, Balance = Balance, Translate = Translate, Notes = Notes };
        steps.CopyTo(c.steps, 0);
        return c;
    }

    public bool SameSteps(AICheck other) => steps.Zip(other.steps).All(p => p.First with { Seconds = null } == p.Second with { Seconds = null });

    public (StepId Step, Reason Why, int? Code)? Failure
    {
        get
        {
            foreach (var id in Order) if (steps[(int)id] is { Kind: Kind.Fail, Why: { } r } s) return (id, r, s.Code);
            return null;
        }
    }

    public bool IsRunning => steps.Any(s => s.Kind == Kind.Running) || Notes?.Kind == Kind.Running;
    public bool IsBusy => steps.Any(s => s.Kind == Kind.Busy);
    public bool Passed => At is not null && Failure is null && !IsRunning;
    public bool IsLowBalance => (Balance ?? double.PositiveInfinity) < LowBalance;

    public bool NeedsUser => Failure is { } f ? f.Why is not (Reason.Busy or Reason.ServerError) : IsLowBalance;

    public static bool Blocks(Reason why) => why is Reason.InvalidKey or Reason.MgmtKey or Reason.NoCredit
        or Reason.NoModel or Reason.BadAddress or Reason.NoJSON or Reason.Deaf;

    public bool Blocking => Failure is { } f && Blocks(f.Why);

    static bool Needs(StepId later, StepId step) => later == StepId.Hear ? step is StepId.Reach or StepId.Key : step < later;

    public void Fail(StepId step, Reason why, int? code = null, bool reached = true)
    {
        foreach (var id in Order)
        {
            if (id == step) steps[(int)id] = State.Fail(why, code);
            else if (Needs(id, step)) steps[(int)id] = State.Skipped;
            else if (reached && Needs(step, id) && steps[(int)id].Kind != Kind.Ok) steps[(int)id] = State.Ok();
        }
        if (why != Reason.Unreachable) Proxy = null;
    }

    public void Pass(StepId step, double? seconds)
    {
        foreach (var id in Order)
        {
            if (id == step) steps[(int)id] = State.Ok(seconds);
            else if (Needs(step, id) && steps[(int)id].Kind != Kind.Ok) steps[(int)id] = State.Ok();
        }
        foreach (var id in Order)
            if (steps[(int)id].Kind == Kind.Skipped && !Order.Any(n => Needs(id, n) && steps[(int)n].Kind == Kind.Fail)) steps[(int)id] = State.Untested;
        Proxy = null;
    }

    public void Busy(StepId step)
    {
        Pass(step, null);
        steps[(int)step] = State.Busy;
    }

    public static (StepId Step, Reason Why, int? Code)? Classify(LingException.Kind kind, int status, StepId step, bool hearElsewhere = false) => kind switch
    {
        LingException.Kind.Network or LingException.Kind.Timeout when hearElsewhere && step == StepId.Hear => (StepId.Hear, Reason.Unreachable, null),
        LingException.Kind.Network or LingException.Kind.Timeout => (StepId.Reach, Reason.Unreachable, null),
        LingException.Kind.InvalidKey => (StepId.Key, Reason.InvalidKey, null),
        LingException.Kind.RateLimited => (step, Reason.Busy, null),
        LingException.Kind.Http when status == 402 => (StepId.Key, Reason.NoCredit, 402),
        LingException.Kind.Http when step == StepId.Hear && status is 400 or 404 or 415 or 422 => (StepId.Hear, Reason.Deaf, status),
        LingException.Kind.Http when step == StepId.Text && status is 400 or 404 => (StepId.Text, Reason.NoModel, status),
        LingException.Kind.Http => (step, Reason.ServerError, status),
        _ => null,
    };

    public static (string Service, bool Management)? Owner(string key)
    {
        var k = key.Trim();
        if (k.StartsWith("sk-or-")) return ("openrouter", false);
        if (k.StartsWith("sk-payg")) return ("zenmux", false);
        if (k.StartsWith("sk-mgmt")) return ("zenmux", true);
        return null;
    }

    public static HashSet<string>? ListedModels(string json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); } catch (System.Text.Json.JsonException) { return null; }
        if (root is not JsonObject o || o["data"] is not JsonArray data) return null;
        var ids = data.OfType<JsonObject>().Select(m => m["id"] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null).OfType<string>().ToHashSet();
        return ids.Count == 0 ? null : ids;
    }

    public static HashSet<string>? ListedHearing(string json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); } catch (System.Text.Json.JsonException) { return null; }
        if (root is not JsonObject o || o["data"] is not JsonArray data) return null;
        bool told = false;
        var ids = new HashSet<string>();
        foreach (var m in data.OfType<JsonObject>())
        {
            var ins = m["input_modalities"] ?? (m["architecture"] as JsonObject)?["input_modalities"];
            if (ins is not JsonArray a) continue;
            told = true;
            if (a.Any(x => x is JsonValue v && v.TryGetValue<string>(out var s) && s == "audio") && m["id"] is JsonValue idv && idv.TryGetValue<string>(out var id)) ids.Add(id);
        }
        return told ? ids : null;
    }

    public static double? BalanceFrom(string? key, string? credits)
    {
        static JsonObject? Data(string? json)
        {
            if (json is null) return null;
            try { return JsonNode.Parse(json)?["data"] as JsonObject; } catch (System.Text.Json.JsonException) { return null; }
        }
        static double? Num(JsonNode? n) => n is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
        var k = Num(Data(key)?["limit_remaining"]);
        double? c = null;
        if (Data(credits) is { } d && Num(d["total_credits"]) is { } total && Num(d["total_usage"]) is { } used) c = total - used;
        return k is { } a && c is { } b ? Math.Min(a, b) : k ?? c;
    }

    // MARK: Words (Chinese keys, localized here: the Mac's own strings, "这台电脑" for the ports)

    public static string Title(StepId id, string host) => id switch
    {
        StepId.Reach => Strings.LF("连上 %@", host),
        StepId.Key => Strings.L("key 可以用"),
        StepId.Text => Strings.L("纪要和翻译"),
        _ => Strings.L("听对方"),
    };

    public string? Message(string service, string host, string model, string hear)
    {
        if (Failure is not { } f) return IsBusy ? Strings.LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service) : null;
        return f.Why switch
        {
            Reason.Unreachable => Strings.LF("这台电脑访问不到 %@。", host),
            Reason.BadAddress => Strings.L("地址要用 https；这台电脑和局域网里的服务可以用 http。"),
            Reason.InvalidKey => Strings.LF("%@ 说这个 key 无效，可能没复制全，或已删除。", service),
            Reason.MgmtKey => Strings.L("这是 ZenMux 的管理 key，不能用来调用模型。请粘贴 sk-payg 开头的 key。"),
            Reason.NoCredit => Strings.LF("%@ 账户余额不足。", service),
            Reason.NoModel => Strings.LF("%@ 上找不到 %@ 这个模型。", service, model),
            Reason.NoJSON => Strings.L("这个服务不支持 JSON，纪要写不了；翻译照常。"),
            Reason.Deaf => Strings.LF("%@ 听不了声音。", hear),
            Reason.Busy => Strings.LF("%@ 现在很忙，key 没问题。开会时会自动重试。", service),
            _ => Strings.LF("%@ 暂时出错（HTTP %lld），稍后再试。", service, f.Code ?? 0),
        };
    }

    public string? SlowLine(bool googleOff = false)
    {
        if (!Slow || Translate is not { } t) return null;
        var secs = t.Seconds.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
        if (googleOff)
            return t.Thinks ? Strings.LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒这句就不等它了。在服务端关掉思考，或换一个不思考的模型。", secs)
                : Strings.LF("翻一句要 %@ 秒，超过 6 秒这句就不等它了。换一个更小的模型会快一些。", secs);
        return t.Thinks ? Strings.LF("这个模型先思考再回答，翻一句要 %@ 秒，超过 6 秒会改用 Google。在服务端关掉思考，或换一个不思考的模型。", secs)
            : Strings.LF("翻一句要 %@ 秒，超过 6 秒会改用 Google。换一个更小的模型会快一些。", secs);
    }

    public string? NotesLine(string host, string model, bool sharedKey)
    {
        if (Notes is not { Kind: Kind.Fail, Why: { } why } n) return null;
        return why switch
        {
            Reason.InvalidKey or Reason.MgmtKey => sharedKey ? Strings.LF("%@ 不认上面的 key，给它单独填一个。", host) : Strings.LF("%@ 说这个 key 无效，可能没复制全，或已删除。", host),
            Reason.Unreachable => Strings.LF("这台电脑访问不到 %@。", host),
            Reason.BadAddress => Strings.L("地址要用 https；这台电脑和局域网里的服务可以用 http。"),
            Reason.NoCredit => Strings.LF("%@ 账户余额不足。", host),
            Reason.NoModel => Strings.LF("%@ 上找不到 %@ 这个模型。", host, model),
            Reason.NoJSON => Strings.L("这个模型没按要求返回 JSON，写不了纪要。换一个通用模型。"),
            Reason.Busy => null,
            _ => Strings.LF("%@ 暂时出错（HTTP %lld），稍后再试。", host, n.Code ?? 0),
        };
    }

    public string? ProxyLine(string service, string host)
    {
        if (Failure?.Why != Reason.Unreachable || Proxy is not { } p || AIProvider.IsNearby(host)) return null;
        return p.Kind switch
        {
            ProxyKind.SystemOn => Strings.LF("开了代理也连不上：换一个节点，或检查代理软件是否放过 %@。", host),
            ProxyKind.AppRunning => Strings.LF("代理软件在运行（端口 %@），但没开系统代理。在代理软件里打开“系统代理”。", p.Port.ToString(System.Globalization.CultureInfo.InvariantCulture)),
            _ => Strings.LF("这台电脑没开代理。在国内通常要开代理才能用 %@。", service),
        };
    }

    public string? BalanceLine(string service) =>
        IsLowBalance && Balance is { } b ? Strings.LF("%@ 余额快用完了（还剩 $%@）", service, Math.Max(0, b).ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)) : null;

    public string Summary
    {
        get
        {
            static string Lower(object o) { var s = o.ToString()!; return char.ToLowerInvariant(s[0]) + s[1..]; }
            static string Step(State s) => s.Kind switch
            {
                Kind.Ok => s.Seconds is { } sec ? $"ok({sec.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)}s)" : "ok",
                Kind.Fail => $"fail({(s.Why is { } w ? Lower(w) : "?")}{(s.Code is { } c ? $" {c}" : "")})",
                var k => Lower(k),
            };
            var parts = Steps.Select(s => $"{Lower(s.Id)}=" + Step(s.State));
            return string.Join(" ", parts) + (Proxy is { } p ? $" proxy={p}" : "")
                + (Balance is { } b ? $" balance={b.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)}" : "") + (Passive ? " passive" : "")
                + (Translate is { } t ? $" translate={t.Seconds.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)}s{(t.Thinks ? " thinks" : "")}" : "")
                + (Notes is { } n ? " notes=" + Step(n) : "");
        }
    }

    public static string HelpUrl => "https://cicada.indaloop.app" + (Strings.Language is "en" or "ja" or "ko" ? "/" + Strings.Language : "") + "/start/#proxy";

    public static string Ago(DateTimeOffset at, DateTimeOffset now)
    {
        var minutes = (int)Math.Floor((now - at).TotalMinutes);
        if (minutes < 1) return Strings.L("刚刚");
        if (minutes < 60) return Strings.LF("%lld 分钟前", minutes);
        var hours = minutes / 60;
        if (hours < 24) return Strings.LF("%lld 小时前", hours);
        return Strings.LF("%lld 天前", hours / 24);
    }
}

public sealed class ProxyWatch
{
    string? seen;

    public bool Update(bool unreachable, bool running, Func<string> settings)
    {
        if (!unreachable && !running) { seen = null; return false; }
        if (seen is null)
        {
            if (!unreachable) return false;
            seen = settings();
        }
        return true;
    }

    public bool Changed(string now, bool running)
    {
        if (seen is null || running || now == seen) return false;
        seen = now;
        return true;
    }
}

public static class ProxyProbe
{
    public static readonly int[] Ports = [7890, 7897, 1080];

    public static async Task<AICheck.ProxyHint> Hint(Func<bool> systemOn)
    {
        if (systemOn() || EnvProxy()) return new(AICheck.ProxyKind.SystemOn);
        foreach (var port in Ports) if (await Listening(port)) return new(AICheck.ProxyKind.AppRunning, port);
        return new(AICheck.ProxyKind.None);
    }

    static bool EnvProxy() => new[] { "HTTPS_PROXY", "https_proxy" }.Any(n => Environment.GetEnvironmentVariable(n) is { Length: > 0 });

    public static async Task<bool> Listening(int port)
    {
        using var tcp = new TcpClient();
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        try { await tcp.ConnectAsync("127.0.0.1", port, cts.Token); return true; }
        catch { return false; }
    }
}
