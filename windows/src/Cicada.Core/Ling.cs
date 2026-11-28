using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Cicada;

public interface IKeyProtector
{
    string Tag { get; }
    byte[] Protect(byte[] data);
    byte[] Unprotect(byte[] data);
}

public sealed class PlainProtector : IKeyProtector
{
    public string Tag => "plain";
    public byte[] Protect(byte[] data) => data;
    public byte[] Unprotect(byte[] data) => data;
}

public sealed class AIKey(IKeyProtector protector, string? file = null, Func<string>? service = null)
{
    readonly Func<string> service = service ?? (() => "ling");
    public string File_ => file ?? Paths.KeyFile(service());

    readonly Dictionary<string, string?> cache = [];
    readonly object gate = new();

    public string? Read() => ReadAt(File_);

    public string? Read(string service) => file is null ? ReadAt(Paths.KeyFile(service)) : null;

    string? ReadAt(string path)
    {
        lock (gate)
        {
            if (cache.TryGetValue(path, out var cached)) return cached;
            string? value = null;
            try
            {
                if (File.Exists(path))
                {
                    var text = File.ReadAllText(path).Trim();
                    if (text.StartsWith("dpapi:"))
                        text = Encoding.UTF8.GetString(protector.Unprotect(Convert.FromBase64String(text["dpapi:".Length..])));
                    value = text.Trim().Length == 0 ? null : text.Trim();
                }
            }
            catch (Exception e) { Log.Debug($"ai key: read failed {e.GetType().Name}"); }
            return cache[path] = value;
        }
    }

    public bool Save(string key) => SaveAt(File_, key);

    public bool Save(string key, string service) => file is null && SaveAt(Paths.KeyFile(service), key);

    bool SaveAt(string path, string key)
    {
        key = key.Trim();
        lock (gate)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var body = protector.Tag == "plain" ? key
                    : "dpapi:" + Convert.ToBase64String(protector.Protect(Encoding.UTF8.GetBytes(key)));
                File.WriteAllText(path, body);
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                cache[path] = key;
                return true;
            }
            catch (Exception e)
            {
                Log.Debug($"ai key: save failed {e.GetType().Name}");
                return false;
            }
        }
    }

    public void Remove() => RemoveAt(File_);

    public void Remove(string service) { if (file is null) RemoveAt(Paths.KeyFile(service)); }

    void RemoveAt(string path)
    {
        lock (gate)
        {
            try { File.Delete(path); } catch { }
            cache[path] = null;
        }
    }

    public void Reload() { lock (gate) cache.Clear(); }

    public static string Masked(string key) => key.Length <= 8 ? "sk-…" : key[..3] + new string('•', 12) + key[^4..];
}

public enum Priority { Speak = 0, Translate = 1, Notes = 2 }

public enum KeyState { None, Unchecked, Checking, Ok, Invalid, Unreachable }

public sealed class LingException(LingException.Kind kind, int status = 0, double? retryAfter = null) : Exception(kind == Kind.Http ? $"http{status}" : kind.ToString())
{
    public enum Kind { NoKey, InvalidKey, RateLimited, Hijacked, Timeout, Http, Network, Parse }
    public Kind Failure { get; } = kind;
    public int Status { get; } = status;
    public double? RetryAfter { get; } = retryAfter;
}

public class GateClock
{
    public virtual DateTime UtcNow => DateTime.UtcNow;
    public virtual Task Delay(TimeSpan wait) => Task.Delay(wait);
}

public sealed class LingClient
{
    public static readonly Uri Base = new(AIProvider.Ling.Base!);
    public const string DefaultModel = "Ling-3.1-flash";
    public const string AudioModel = "Ming-3.0-audio-flash";
    public const string VoiceModel = "Ming-3.0-tts-0.5B";
    static readonly string[] HijackPrefixes = ["根据现有检索证据", "暂未找到足够可靠的信息", "根据检索", "作为一个人工智能语言模型"];

    readonly AIKey key;
    readonly HttpClient http;
    readonly Func<AIConfig> config;
    public KeyState KeyState { get; private set; }
    public DateTimeOffset? RateLimitedAt { get; private set; }
    public AICheck Health { get { lock (healthGate) return health; } }
    AICheck health = new();
    readonly object healthGate = new();
    int checking;
    int generation;
    public double? Seconds => Health[AICheck.StepId.Text].Seconds;
    public bool? Hears => Health[AICheck.StepId.Hear] switch
    {
        { Kind: AICheck.Kind.Ok or AICheck.Kind.Busy } => true,
        { Kind: AICheck.Kind.Fail, Why: AICheck.Reason.Deaf } => false,
        _ => null,
    };
    public (bool Ok, DateTimeOffset At)? LastVoice { get; private set; }
    public IReadOnlyList<string> TextCatalog { get; private set; } = [];
    public IReadOnlyList<string> HearCatalog { get; private set; } = [];
    HashSet<string>? listed, listedHearing;
    public Func<Task<AICheck.ProxyHint>>? ProxyHint { get; set; }
    public AICheck.Reason? SimulateCheck { get; set; }
    public double? SimulateBalance { get; set; }
    public event Action? Changed;

    public LingClient(AIKey key, HttpMessageHandler? handler = null, Func<AIConfig>? config = null, GateClock? clock = null)
    {
        this.key = key;
        this.clock = clock ?? new GateClock();
        this.config = config ?? (() => AIConfig.Default);
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = Timeout.InfiniteTimeSpan;
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Cicada-Windows/0.1");
        KeyState = CurrentKey() is null ? KeyState.None : KeyState.Unchecked;
    }

    public AIConfig Config => config();
    public AIProvider Provider => Config.Provider;

    public string? CurrentKey()
    {
        var c = Config;
        var k = key.Read();
        if (k is null && c.Provider.Id == "custom" && c.Base is { } b && AIProvider.IsNearby(b)) return "";
        return k;
    }

    public bool HasKey => CurrentKey() is not null;

    public const string NotesKeyName = "custom-notes";

    public string? NotesKey() => Config.NotesOwnService && key.Read(NotesKeyName) is { } own ? own : CurrentKey();

    public bool NotesHasOwnKey => Config.NotesOwnService && key.Read(NotesKeyName) is not null;

    public bool SaveNotesKey(string raw) => raw.Trim().Length > 0 && key.Save(raw.Trim(), NotesKeyName);

    public void RemoveNotesKey() => key.Remove(NotesKeyName);

    public IReadOnlyList<string> NotesCatalog { get; private set; } = [];
    public bool Usable => HasKey && KeyState != KeyState.Invalid;
    public bool Speaks => Usable && Config.HasVoices;
    public bool Clones => Speaks && Config.Provider.Clones;
    public bool CanHear => Usable && Hears != false && Config.HearModel.Length > 0;
    readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> noTemplateKwargs = new();

    public void KeyChanged()
    {
        key.Reload();
        noTemplateKwargs.Clear();
        Interlocked.Increment(ref generation);
        lock (healthGate) health = new AICheck();
        KeyState = CurrentKey() is null ? KeyState.None : KeyState.Unchecked;
        LastVoice = null;
        listed = listedHearing = null;
        TextCatalog = HearCatalog = NotesCatalog = [];
        Changed?.Invoke();
    }

    public string ServiceName => Config.Provider.Id == "custom" ? Strings.L("这个服务") : Config.Name;
    public string ServiceHost => Host(Config.Base);
    public string ServiceLabel => Config.Provider.Id == "custom" && ServiceHost.Length > 0 ? ServiceHost : ServiceName;
    public string HearHost => Host(Config.HearBase ?? Config.Base);
    static string Host(string? b) => b is not null && Uri.TryCreate(b, UriKind.Absolute, out var u) ? u.Host : "";
    public string HearName => Config.HearModel.Length > 0 ? Config.HearModel : ServiceName;

    public async Task<(KeyState state, double seconds)> Check()
    {
        var started = DateTime.UtcNow;
        var c = Config;
        var gen = Interlocked.Increment(ref generation);
        if (CurrentKey() is not { } k)
        {
            lock (healthGate) health = new AICheck();
            KeyState = KeyState.None;
            Changed?.Invoke();
            return (KeyState, 0);
        }
        Interlocked.Increment(ref checking);
        try
        {
            var r = new AICheck();
            r[AICheck.StepId.Reach] = AICheck.State.Running;
            lock (healthGate) health = r;
            KeyState = KeyState.Checking;
            Changed?.Invoke();
            r = new AICheck();
            if (SimulateCheck is { } sim) r = Simulated(sim);
            else if (c.Provider.Id == "custom" && c.Base is null) r.Fail(AICheck.StepId.Reach, AICheck.Reason.BadAddress, reached: false);
            else if (AICheck.Owner(k) is { Management: true }) r.Fail(AICheck.StepId.Key, AICheck.Reason.MgmtKey, reached: false);
            else await Probe(r, c, k, gen);
            await Finish(r, c, gen);
        }
        finally { Interlocked.Decrement(ref checking); }
        return (KeyState, (DateTime.UtcNow - started).TotalSeconds);
    }

    async Task Probe(AICheck r, AIConfig c, string k, int gen)
    {
        double Since(DateTime t) => (DateTime.UtcNow - t).TotalSeconds;
        void Failed(LingException e, AICheck.StepId step)
        {
            if (AICheck.Classify(e.Failure, e.Status, step, c.HearElsewhere) is not { } f) return;
            if (f.Why == AICheck.Reason.Busy) r.Busy(f.Step); else r.Fail(f.Step, f.Why, f.Code);
        }
        var t = DateTime.UtcNow;
        try
        {
            if (c.IsLing) await Chat("Reply with OK.", "Reply.", Priority.Speak, maxTokens: 5, timeout: 10, model: "Ling-3.0-tiny");
            else if (c.Provider.Id != "custom") await Chat("Reply with OK.", "Reply.", Priority.Speak, maxTokens: 5, timeout: 20);
            else
            {
                JsonNode? root = null;
                try
                {
                    await Chat("Translate the text into Simplified Chinese. Reply with the translation only.\n\nWe will ship the new version on Friday after the design review.",
                        "Translate.", Priority.Speak, maxTokens: 120, timeout: 30, reply: n => root = n);
                }
                catch (LingException e) when (e.Failure == LingException.Kind.Parse && AIConfig.Thought(root)) { }
                r.Translate = new AICheck.Speed(Since(t), AIConfig.Thought(root));
            }
            r.Pass(AICheck.StepId.Text, Since(t));
            if (c.NotesApart)
            {
                r.Notes = AICheck.State.Running;
                lock (healthGate) { if (gen == generation) health = r.Clone(); }
                Changed?.Invoke();
                r.Notes = await CheckNotes(c);
            }
            else if (c.Provider.Id == "custom")
            {
                const string ask = "Reply with the JSON object {\"ok\": true}.";
                try { await Chat(ask, "Reply.", Priority.Speak, json: true, maxTokens: 20, timeout: 30, jsonFallback: false); }
                catch (LingException e) when (e.Failure == LingException.Kind.Http)
                {
                    string? said = null;
                    try { said = await Chat(ask, "Reply.", Priority.Speak, maxTokens: 20, timeout: 30); } catch (LingException) { }
                    if (!AnswersJSON(said)) r.Fail(AICheck.StepId.Text, AICheck.Reason.NoJSON, e.Status);
                }
            }
        }
        catch (LingException e) { Failed(e, AICheck.StepId.Text); }
        catch (Exception) { r.Fail(AICheck.StepId.Reach, AICheck.Reason.Unreachable); }
        if (c.IsLing || r.Failure is { Step: AICheck.StepId.Reach or AICheck.StepId.Key }) return;
        if (c.HearModel.Length == 0) r.Fail(AICheck.StepId.Hear, AICheck.Reason.Deaf);
        else if (c.HearBase is null) r.Fail(AICheck.StepId.Hear, AICheck.Reason.BadAddress);
        else
        {
            t = DateTime.UtcNow;
            try
            {
                await Chat("Transcribe the audio.", "Reply with what is said, or NONE.", Priority.Speak, maxTokens: 10, timeout: 20,
                    model: c.HearModel, audio: Wav.Bytes(new short[8000]));
                r.Pass(AICheck.StepId.Hear, Since(t));
            }
            catch (LingException e) when (e.Failure == LingException.Kind.Hijacked) { r.Pass(AICheck.StepId.Hear, Since(t)); }
            catch (LingException e) { Failed(e, AICheck.StepId.Hear); }
            catch (Exception) { }
        }
        await FetchCatalog();
        var proven = c.Provider.Id == "custom" && r.Translate is not null;
        if (listed is { } ids && c.TextModel.Length > 0 && !proven && r[AICheck.StepId.Text].Kind != AICheck.Kind.Fail && !ids.Contains(c.TextModel))
            r.Fail(AICheck.StepId.Text, AICheck.Reason.NoModel);
        if (listedHearing is { } hearing && !c.HearElsewhere && c.HearModel.Length > 0 && r[AICheck.StepId.Hear].Kind != AICheck.Kind.Fail && !hearing.Contains(c.HearModel))
            r.Fail(AICheck.StepId.Hear, AICheck.Reason.Deaf);
        if (c.Provider.Id == "openrouter") r.Balance = AICheck.BalanceFrom(await GetText("key", k), await GetText("credits", k));
    }

    async Task Finish(AICheck r, AIConfig c, int gen)
    {
        if (gen != Volatile.Read(ref generation)) { Log.Debug($"ai {c.Provider.Id}: an older check -> {r.Summary}, dropped"); return; }
        if (r.Failure?.Why == AICheck.Reason.Unreachable && r.Proxy is null && ProxyHint is { } hint) r.Proxy = await hint();
        if (SimulateBalance is { } b) r.Balance = b;
        r.At = DateTimeOffset.Now;
        lock (healthGate) { if (gen != generation) return; health = r; }
        SyncKeyState();
        Log.Debug($"ai {c.Provider.Id}: check -> {r.Summary}");
        Changed?.Invoke();
    }

    static AICheck Simulated(AICheck.Reason reason)
    {
        var r = new AICheck();
        switch (reason)
        {
            case AICheck.Reason.Busy: r.Pass(AICheck.StepId.Text, 1.2); r[AICheck.StepId.Text] = AICheck.State.Busy; r.Pass(AICheck.StepId.Hear, 0.9); break;
            case AICheck.Reason.Unreachable or AICheck.Reason.BadAddress: r.Fail(AICheck.StepId.Reach, reason, reached: false); break;
            case AICheck.Reason.InvalidKey: r.Fail(AICheck.StepId.Key, reason); break;
            case AICheck.Reason.NoCredit: r.Fail(AICheck.StepId.Key, reason, 402); break;
            case AICheck.Reason.MgmtKey: r.Fail(AICheck.StepId.Key, reason, reached: false); break;
            case AICheck.Reason.NoModel or AICheck.Reason.NoJSON: r.Fail(AICheck.StepId.Text, reason, 404); r.Pass(AICheck.StepId.Hear, 0.9); break;
            case AICheck.Reason.Deaf: r.Pass(AICheck.StepId.Text, 1.2); r.Fail(AICheck.StepId.Hear, reason, 400); break;
            default: r.Pass(AICheck.StepId.Text, 1.2); r.Fail(AICheck.StepId.Hear, reason, 503); break;
        }
        return r;
    }

    void SyncKeyState()
    {
        var h = Health;
        KeyState = !HasKey ? KeyState.None
            : h.IsRunning ? KeyState.Checking
            : h.Failure is { Why: AICheck.Reason.InvalidKey or AICheck.Reason.MgmtKey } ? KeyState.Invalid
            : h.Failure is { Step: AICheck.StepId.Reach or AICheck.StepId.Key } or { Why: AICheck.Reason.NoModel or AICheck.Reason.ServerError } ? KeyState.Unreachable
            : h.At is null ? KeyState.Unchecked
            : KeyState.Ok;
    }

    void Observe(LingException? failure, double seconds, bool audio, bool notes = false)
    {
        if (!HasKey || Volatile.Read(ref checking) > 0 || SimulateCheck is not null) return;
        if (notes)
        {
            AICheck.State now;
            if (failure is not null)
            {
                if (AICheck.Classify(failure.Failure, failure.Status, AICheck.StepId.Text) is not { } f || f.Why == AICheck.Reason.ServerError) return;
                now = AICheck.State.Fail(f.Why, f.Code);
            }
            else now = AICheck.State.Ok(seconds);
            lock (healthGate)
            {
                if (health.Notes?.Kind == AICheck.Kind.Ok && now.Kind == AICheck.Kind.Ok) return;
                if (health.Notes is { } old && old with { Seconds = null } == now with { Seconds = null }) return;
                health = health.Clone();
                health.Notes = now;
            }
            Log.Debug($"ai: notes from a real request -> {health.Summary}");
            Changed?.Invoke();
            return;
        }
        var step = audio ? AICheck.StepId.Hear : AICheck.StepId.Text;
        AICheck r;
        bool wasUnreachable;
        lock (healthGate)
        {
            var old = health;
            r = old.Clone();
            if (failure is not null)
            {
                if (AICheck.Classify(failure.Failure, failure.Status, step, Config.HearElsewhere) is not { } f || f.Why == AICheck.Reason.ServerError) return;
                if (f.Why == AICheck.Reason.Busy) r.Busy(f.Step); else r.Fail(f.Step, f.Why, f.Code);
            }
            else r.Pass(step, seconds);
            r.At = DateTimeOffset.Now;
            r.Passive = true;
            if (r.SameSteps(old) && old.Passive) { old.At = r.At; return; }
            wasUnreachable = old.Failure?.Why == AICheck.Reason.Unreachable;
            if (r.Failure?.Why == AICheck.Reason.Unreachable) r.Proxy = old.Proxy;
            health = r;
        }
        SyncKeyState();
        Log.Debug($"ai: from a real request -> {r.Summary}");
        Changed?.Invoke();
        if (r.Failure?.Why == AICheck.Reason.Unreachable && !wasUnreachable && ProxyHint is { } hint)
            _ = Task.Run(async () =>
            {
                var p = await hint();
                lock (healthGate) { if (health.Failure?.Why != AICheck.Reason.Unreachable) return; health = health.Clone(); health.Proxy = p; }
                Changed?.Invoke();
            });
    }

    public void NetworkChanged()
    {
        var h = Health;
        if (!HasKey || h.Failure?.Why != AICheck.Reason.Unreachable || h.IsRunning) return;
        Log.Debug("ai: network changed while unreachable, checking again");
        _ = Check();
    }

    public string? Recommended(AICheck.StepId step)
    {
        var c = Config;
        var (models, current) = step == AICheck.StepId.Hear ? (c.Provider.HearModels, c.HearModel) : (c.Provider.TextModels, c.TextModel);
        return models.FirstOrDefault()?.Id is { } id && id != current ? id : null;
    }

    async Task<string?> GetText(string path, string k, string? at = null)
    {
        if ((at ?? Config.Base) is not { } b) return null;
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, new Uri(new Uri(b), path));
            if (k.Length > 0) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", k);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            using var res = await http.SendAsync(req, cts.Token);
            return res.StatusCode == HttpStatusCode.OK ? await res.Content.ReadAsStringAsync(cts.Token) : null;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException) { return null; }
    }

    public async Task FetchCatalog()
    {
        var c = Config;
        if (c.IsLing || CurrentKey() is not { } k || c.Base is null) return;
        if (await GetText("models", k) is not { } body) return;
        TextCatalog = AIProvider.Catalog(body, c.Provider.TextModels.Select(m => m.Id), hears: false);
        HearCatalog = AIProvider.Catalog(body, c.Provider.HearModels.Select(m => m.Id), hears: true);
        listed = AICheck.ListedModels(body);
        listedHearing = AICheck.ListedHearing(body);
        Log.Debug($"ai {c.Provider.Id}: {TextCatalog.Count} models, {HearCatalog.Count} hear");
        Changed?.Invoke();
    }

    async Task<AICheck.State> CheckNotes(AIConfig config)
    {
        if (config.NotesBadAddress) return AICheck.State.Fail(AICheck.Reason.BadAddress);
        var c = config.ForNotes;
        if (NotesKey() is not { } k || c.Base is not { } b) return AICheck.State.Fail(AICheck.Reason.InvalidKey);
        var url = new Uri(new Uri(b), "chat/completions");
        var body = new JsonObject
        {
            ["model"] = c.TextModel,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = "Reply with the JSON object {\"ok\": true}." },
                new JsonObject { ["role"] = "user", ["content"] = "Reply." }),
            ["stream"] = false,
        };
        c.Shape(body, 20, templateKwargs: !noTemplateKwargs.ContainsKey(b));
        body["response_format"] = new JsonObject { ["type"] = "json_object" };
        var asked = DateTime.UtcNow;
        AICheck.State result;
        try
        {
            await PostChat(url, body, b, k, 60, default);
            result = AICheck.State.Ok((DateTime.UtcNow - asked).TotalSeconds);
        }
        catch (LingException e) when (e.Failure == LingException.Kind.Http && e.Status is 400 or 422)
        {
            body.Remove("response_format");
            string? said = null;
            try { said = Str((await PostChat(url, body, b, k, 60, default))["choices"]?[0]?["message"]?["content"]); } catch (LingException) { }
            result = AnswersJSON(said) ? AICheck.State.Ok((DateTime.UtcNow - asked).TotalSeconds) : AICheck.State.Fail(AICheck.Reason.NoJSON, e.Status);
        }
        catch (LingException e)
        {
            var f = AICheck.Classify(e.Failure, e.Status, AICheck.StepId.Text) ?? (AICheck.StepId.Text, AICheck.Reason.ServerError, null);
            result = AICheck.State.Fail(f.Why, f.Code);
        }
        catch (Exception) { result = AICheck.State.Fail(AICheck.Reason.Unreachable); }
        if (c.Base != config.Base) await FetchNotesCatalog();
        return result;
    }

    public async Task FetchNotesCatalog()
    {
        var c = Config;
        var b = c.ForNotes.Base;
        if (!c.NotesApart || b is null || b == c.Base || NotesKey() is not { } k) return;
        if (await GetText("models", k, b) is not { } body) return;
        NotesCatalog = AIProvider.Catalog(body, [], hears: false);
        Log.Debug($"ai notes: {NotesCatalog.Count} models");
        Changed?.Invoke();
    }

    public async Task<string> Chat(string content, string instruction, Priority priority, bool json = false,
        int maxTokens = 1024, double timeout = 30, string? model = null, byte[]? audio = null, bool patient = false,
        CancellationToken cancel = default, Action<JsonNode>? reply = null, bool jsonFallback = true, bool? notes = null)
    {
        var all = Config;
        var notesSide = (notes ?? priority == Priority.Notes) && audio is null && all.NotesApart;
        if (notesSide && all.NotesBadAddress) throw new LingException(LingException.Kind.NoKey);
        var c = notesSide ? all.ForNotes : all;
        var k = (notesSide ? NotesKey() : CurrentKey()) ?? throw new LingException(LingException.Kind.NoKey);
        if (notesSide ? Health.Notes?.Why is AICheck.Reason.InvalidKey or AICheck.Reason.MgmtKey : KeyState == KeyState.Invalid)
            throw new LingException(LingException.Kind.InvalidKey);
        var b = audio is null ? c.Base : c.Provider.Id == "custom" ? c.HearBase : c.HearBase ?? c.Base;
        if (b is null) throw new LingException(LingException.Kind.NoKey);
        model ??= c.TextModel;
        JsonNode user = audio is null ? JsonValue.Create(instruction)! : new JsonArray(c.AudioPart(audio, model), new JsonObject { ["type"] = "text", ["text"] = instruction });
        var body = new JsonObject
        {
            ["model"] = model,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = content },
                new JsonObject { ["role"] = "user", ["content"] = user }),
            ["stream"] = false,
        };
        c.Shape(body, maxTokens, templateKwargs: !noTemplateKwargs.ContainsKey(b));
        if (json) body["response_format"] = new JsonObject { ["type"] = "json_object" };
        var url = new Uri(new Uri(b), "chat/completions");

        var waits = RetryWaits(priority, audio is not null, patient);
        var g = GateFor(b);
        long? ticket = null;
        for (int attempt = 1; ; attempt++)
        {
            var queued = DateTime.UtcNow;
            ticket = await Acquire(g, priority, c.Provider.Spacing, cancel, ticket, failIfPaused: waits.Length == 0);
            var started = DateTime.UtcNow;
            if ((started - queued).TotalSeconds > 1) Log.Debug($"ling: {priority} waited {(started - queued).TotalMilliseconds:F0} ms at the gate");
            try
            {
                JsonNode root;
                try { root = await PostChat(url, body, b, k, timeout, cancel); }
                catch (LingException e) when (jsonFallback && e.Failure == LingException.Kind.Http && e.Status == 400 && body.ContainsKey("response_format"))
                {
                    Log.Debug($"ling: {priority} JSON mode refused (400), asking again without it");
                    body.Remove("response_format");
                    root = await PostChat(url, body, b, k, timeout, cancel);
                }
                reply?.Invoke(root);
                var choice = root["choices"]?[0];
                var text = Str(choice?["message"]?["content"]) ?? throw new LingException(LingException.Kind.Parse);
                var finish = Str(choice?["finish_reason"]);
                var trimmed = text.Trim();
                if (finish is null && c.IsLing || HijackPrefixes.Any(trimmed.StartsWith))
                {
                    Log.Debug($"ling: {priority} search-style reply dropped");
                    throw new LingException(LingException.Kind.Hijacked);
                }
                var usage = root["usage"];
                Log.Debug($"ai {c.Provider.Id}: {priority} ok {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms tokens={usage?["prompt_tokens"]}/{usage?["completion_tokens"]}");
                if (RateLimitedAt is not null) { RateLimitedAt = null; Changed?.Invoke(); }
                Observe(null, (DateTime.UtcNow - started).TotalSeconds, audio is not null, notesSide);
                return trimmed;
            }
            catch (LingException e)
            {
                Observe(e, 0, audio is not null, notesSide);
                if (e.Failure != LingException.Kind.RateLimited) throw;
                var wait = RateLimited(g, waits.Length > 0 ? waits[Math.Min(attempt, waits.Length) - 1] : 1, e.RetryAfter);
                if (attempt > waits.Length || wait is null) { RateLimitedAt = DateTimeOffset.Now; Changed?.Invoke(); throw; }
                Log.Debug($"ling: {priority} 429, retry in {wait:F1} s");
            }
        }
    }

    public static double[] RetryWaits(Priority priority, bool audio = false, bool patient = false) =>
        priority == Priority.Notes ? (patient ? [1, 2, 4, 8, 16, 30] : [1, 2, 4])
        : audio ? (priority == Priority.Translate ? [1, 2, 4, 8] : [1]) : [];

    public const double MaxPause = 30;

    double? RateLimited(StartGate g, double backoff, double? retryAfter)
    {
        var wait = Math.Max(backoff, retryAfter ?? 0) + Random.Shared.NextDouble() * 0.5;
        lock (gate)
        {
            var until = clock.UtcNow.AddSeconds(Math.Min(wait, MaxPause));
            if (until > g.PausedUntil) g.PausedUntil = until;
        }
        return wait <= MaxPause ? wait : null;
    }

    public static double? RetryAfterSeconds(System.Net.Http.Headers.RetryConditionHeaderValue? value, DateTimeOffset now) =>
        value?.Delta is { } d ? Math.Max(0, d.TotalSeconds)
        : value?.Date is { } at ? Math.Max(0, (at - now).TotalSeconds)
        : null;

    public async IAsyncEnumerable<byte[]> Speech(string text, string? voice, string? languageId = null,
        (string Audio, string Text)? reference = null,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancel = default)
    {
        var k = CurrentKey() ?? throw new LingException(LingException.Kind.NoKey);
        if (KeyState == KeyState.Invalid) throw new LingException(LingException.Kind.InvalidKey);
        var c = Config;
        if (!c.HasVoices) throw new LingException(LingException.Kind.NoKey);
        var body = SpeechBody(c, text, voice, languageId, reference);
        await Acquire(GateFor(c.VoiceBase), Priority.Speak, c.Provider.Spacing, cancel);
        var started = DateTime.UtcNow;
        using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(new Uri(c.VoiceBase!), "audio/speech"))
        {
            Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        if (k.Length > 0) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", k);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(TimeSpan.FromSeconds(reference is not null && c.IsLing ? 30 : 20));
        HttpResponseMessage res;
        try { res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token); }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
        catch (HttpRequestException e) { Log.Debug($"ling: voice network error {e.HttpRequestError}"); throw new LingException(LingException.Kind.Network); }
        using (res)
        {
            switch (res.StatusCode)
            {
                case HttpStatusCode.OK: break;
                case HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden:
                    Observe(new LingException(LingException.Kind.InvalidKey), 0, audio: false);
                    throw new LingException(LingException.Kind.InvalidKey);
                case HttpStatusCode.TooManyRequests: throw new LingException(LingException.Kind.RateLimited);
                default: Log.Debug($"ai {c.Provider.Id}: voice HTTP {(int)res.StatusCode}"); throw new LingException(LingException.Kind.Http, (int)res.StatusCode);
            }
            var kind = res.Content.Headers.ContentType?.MediaType ?? "";
            var stream = await res.Content.ReadAsStreamAsync(cts.Token);
            int chunks = 0;
            if (kind.Contains("event-stream") || c.IsLing)
            {
                using var reader = new StreamReader(stream);
                string? other = null;
                while (true)
                {
                    string? line;
                    try { line = await reader.ReadLineAsync(cts.Token); }
                    catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
                    if (line is null) break;
                    var pcm = SpeechChunk(line, out var done);
                    if (done) break;
                    if (pcm is null) { if (other is null && line.StartsWith("data:")) other = line; continue; }
                    if (chunks++ == 0) Log.Debug($"ai {c.Provider.Id}: Speak first audio {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms");
                    yield return pcm;
                }
                // A 200 that carried no audio (an error event inside the stream, or nothing at all) is a
                // failure, not silence: the caller tries again or says so, and the log shows what came.
                if (chunks == 0)
                {
                    Log.Debug($"ai {c.Provider.Id}: voice reply had no audio{(other is null ? "" : ": " + other[..Math.Min(other.Length, 200)])}");
                    throw new LingException(LingException.Kind.Parse);
                }
            }
            else if (kind.Contains("json"))
            {
                string all;
                try { all = await new StreamReader(stream).ReadToEndAsync(cts.Token); }
                catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
                byte[] wav;
                try { wav = Convert.FromBase64String(JsonNode.Parse(all)?["audio"]?.GetValue<string>() ?? throw new LingException(LingException.Kind.Parse)); }
                catch (Exception e) when (e is JsonException or FormatException or InvalidOperationException) { throw new LingException(LingException.Kind.Parse); }
                Log.Debug($"ai {c.Provider.Id}: Speak audio {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms");
                yield return PcmFromWav(wav);
            }
            else
            {
                var buffer = new byte[4800];
                int held = 0;
                while (true)
                {
                    int n;
                    try { n = await stream.ReadAsync(buffer.AsMemory(held), cts.Token); }
                    catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
                    if (n == 0) break;
                    n += held;
                    var even = n & ~1;
                    held = n - even;
                    if (even == 0) continue;
                    if (chunks++ == 0) Log.Debug($"ai {c.Provider.Id}: Speak first audio {(int)(DateTime.UtcNow - started).TotalMilliseconds} ms");
                    var piece = buffer[..even];
                    if (held > 0) buffer[0] = buffer[even];
                    yield return piece;
                }
            }
        }
    }

    public static JsonObject SpeechBody(AIConfig c, string text, string? voice, string? languageId, (string Audio, string Text)? reference = null)
    {
        var body = new JsonObject { ["model"] = c.VoiceModel, ["input"] = text, ["response_format"] = "pcm" };
        if (c.IsLing)
        {
            if (reference is { } r) body["references"] = new JsonArray(new JsonObject { ["audio"] = r.Audio, ["text"] = r.Text });
            else body["voice"] = voice ?? "UK_Charlotte";
            body["sample_rate"] = 24000; body["stream"] = true; body["stream_format"] = "sse";
            if (languageId is not null) body["language_id"] = languageId;
        }
        else
        {
            if (c.Provider.Id != "openrouter") body["stream"] = true;
            var ids = c.Voices.Select(v => v.Id).ToList();
            body["voice"] = voice is not null && ids.Contains(voice) ? voice : ids.FirstOrDefault() ?? c.CustomVoice ?? "Kore";
        }
        return body;
    }

    public void VoiceSpoke(bool ok)
    {
        LastVoice = (ok, DateTimeOffset.Now);
        Changed?.Invoke();
    }

    public static byte[]? SpeechChunk(string line, out bool done)
    {
        done = false;
        if (!line.StartsWith("data:")) return null;
        JsonNode? obj;
        try { obj = JsonNode.Parse(line[5..]); } catch (JsonException) { return null; }
        if (obj is not JsonObject) return null;
        if (Str(obj["type"]) == "speech.audio.done") { done = true; return null; }
        if (Str(obj["audio"]) is not { Length: > 0 } b64) return null;
        try { return Convert.FromBase64String(b64); } catch (FormatException) { return null; }
    }

    static string? Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public static byte[] PcmFromWav(byte[] wav)
    {
        if (wav.Length < 12 || Encoding.ASCII.GetString(wav, 0, 4) != "RIFF") return wav;
        int at = 12;
        while (at + 8 <= wav.Length)
        {
            int size = BitConverter.ToInt32(wav, at + 4);
            if (Encoding.ASCII.GetString(wav, at, 4) == "data") return wav[(at + 8)..Math.Min(wav.Length, at + 8 + size)];
            at += 8 + size + (size & 1);
        }
        return [];
    }

    async Task<JsonNode> PostChat(Uri url, JsonObject body, string b, string k, double timeout, CancellationToken cancel)
    {
        try { return await Post(url, body.ToJsonString(), k, timeout, cancel); }
        catch (LingException e) when (e.Failure == LingException.Kind.Http && e.Status is 400 or 422 && body.ContainsKey("chat_template_kwargs"))
        {
            var plain = (JsonObject)body.DeepClone();
            plain.Remove("chat_template_kwargs");
            JsonNode root;
            try { root = await Post(url, plain.ToJsonString(), k, timeout, cancel); }
            catch (LingException) { throw e; }
            Log.Debug($"ai custom: chat_template_kwargs refused (HTTP {e.Status}), sent without it from now on");
            noTemplateKwargs[b] = true;
            return root;
        }
    }

    public static bool AnswersJSON(string? text)
    {
        if (text is null) return false;
        int a = text.IndexOf('{'), z = text.LastIndexOf('}');
        if (a < 0 || z <= a) return false;
        try { return JsonNode.Parse(text[a..(z + 1)]) is JsonObject; } catch (JsonException) { return false; }
    }

    async Task<JsonNode> Post(Uri url, string payload, string k, double timeout, CancellationToken cancel)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(payload, Encoding.UTF8, "application/json"),
        };
        if (k.Length > 0) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", k);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        cts.CancelAfter(TimeSpan.FromSeconds(timeout));
        HttpResponseMessage res;
        try { res = await http.SendAsync(req, cts.Token); }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
        catch (HttpRequestException e)
        {
            Log.Debug($"ling: network error {e.HttpRequestError}");
            throw new LingException(LingException.Kind.Network);
        }
        using (res)
        {
            switch (res.StatusCode)
            {
                case HttpStatusCode.OK: break;
                case HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden: throw new LingException(LingException.Kind.InvalidKey);
                case HttpStatusCode.TooManyRequests:
                    throw new LingException(LingException.Kind.RateLimited, 429, RetryAfterSeconds(res.Headers.RetryAfter, DateTimeOffset.UtcNow));
                default:
                    Log.Debug($"ling: HTTP {(int)res.StatusCode}");
                    throw new LingException(LingException.Kind.Http, (int)res.StatusCode);
            }
            try
            {
                var text = await res.Content.ReadAsStringAsync(cts.Token);
                return JsonNode.Parse(text) ?? throw new LingException(LingException.Kind.Parse);
            }
            catch (OperationCanceledException) when (!cancel.IsCancellationRequested) { throw new LingException(LingException.Kind.Timeout); }
            catch (JsonException) { throw new LingException(LingException.Kind.Parse); }
        }
    }

    public static double? Spacing { get; set; }
    readonly GateClock clock;
    readonly object gate = new();
    readonly Dictionary<string, StartGate> gates = [];
    long seq;

    sealed class StartGate
    {
        public DateTime LastStart = DateTime.MinValue;
        public DateTime PausedUntil = DateTime.MinValue;
        public readonly List<(Priority priority, long seq, TaskCompletionSource ready)> Waiting = [];
        public bool Pumping;
        public double Spacing = 0.6;
    }

    StartGate GateFor(string? address)
    {
        var host = Host(address ?? Config.Base);
        lock (gate)
        {
            if (!gates.TryGetValue(host, out var g)) gates[host] = g = new StartGate();
            return g;
        }
    }

    Task<long> Acquire(StartGate g, Priority priority, double serviceSpacing, CancellationToken cancel, long? ticket = null, bool failIfPaused = false)
    {
        lock (gate)
        {
            g.Spacing = Spacing ?? serviceSpacing;
            var now = clock.UtcNow;
            if (failIfPaused && g.PausedUntil > now) throw new LingException(LingException.Kind.RateLimited);
            var me = ticket ?? ++seq;
            if (g.Waiting.Count == 0 && !g.Pumping && Wait(g, now) <= Slack)
            {
                g.LastStart = now;
                return Task.FromResult(me);
            }
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            g.Waiting.Add((priority, me, ready));
            if (!g.Pumping) { g.Pumping = true; _ = Pump(g); }
            return ready.Task.WaitAsync(cancel).ContinueWith(t => { t.GetAwaiter().GetResult(); return me; }, TaskScheduler.Default);
        }
    }

    const double Slack = 0.001;

    static double Wait(StartGate g, DateTime now) => Math.Max(g.Spacing - (now - g.LastStart).TotalSeconds, (g.PausedUntil - now).TotalSeconds);

    async Task Pump(StartGate g)
    {
        while (true)
        {
            double wait;
            lock (gate)
            {
                if (g.Waiting.Count == 0) { g.Pumping = false; return; }
                var now = clock.UtcNow;
                wait = Wait(g, now);
                if (wait <= Slack)
                {
                    var next = g.Waiting.MinBy(w => ((int)w.priority, w.seq));
                    g.Waiting.Remove(next);
                    g.LastStart = now;
                    next.ready.TrySetResult();
                    continue;
                }
            }
            await clock.Delay(TimeSpan.FromSeconds(wait));
        }
    }
}
