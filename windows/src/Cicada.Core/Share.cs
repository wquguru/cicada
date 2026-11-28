using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Cicada;

public enum ShareScope { Notes, Full }

public sealed record ShareDoc(string Title, string StartedAt, int Duration, List<string> Langs, ShareDoc.NotesPart? Notes, List<ShareDoc.Line> Lines, int Hidden)
{
    public sealed record Line(double T, string Who, string Src, string? Dst);
    public sealed record Topic(double Start, string Title, string Summary, List<string> Points);
    public sealed record Item(string Text, string? Owner, double? T);
    public sealed record Term(string Name, string Note);
    public sealed record NotesPart(string Summary, List<Topic> Topics, List<Item> Conclusions, List<Item> Todos, List<Term> Terms);
}

public static class ShareProjection
{
    public static ShareDoc Doc(Session s, ShareScope scope, bool names, ISet<int>? removed = null, bool dropNotes = false)
    {
        removed ??= new HashSet<int>();
        var numbers = SpeakerLabels.Numbers(s.Lines);
        var nameMap = names ? SpeakerLabels.Names(s) : [];
        string Who(TranscriptLine l)
        {
            if (l.Speaker == "me") return Strings.L("分享者");
            if (!numbers.TryGetValue(l.Id, out var n)) return Strings.L("对方");
            return names && nameMap.TryGetValue(n, out var name) ? name : Strings.LF("说话人 %lld", n);
        }
        var lines = new List<ShareDoc.Line>();
        if (scope == ShareScope.Full)
            for (int i = 0; i < s.Lines.Count; i++)
            {
                var l = s.Lines[i];
                if (removed.Contains(i) || l.Src.Length == 0) continue;
                var dst = string.IsNullOrEmpty(l.Dst) || l.Dst == l.Src ? null : l.Dst;
                lines.Add(new(Round(l.T), Who(l), l.Src, dst));
            }
        ShareDoc.NotesPart? notes = null;
        if (!dropNotes && s.Notes is { IsEmpty: false } n)
        {
            string Swap(string text) => names ? Named(text, nameMap) : text;
            notes = new(Swap(n.Summary),
                [.. n.Topics.Select(t => new ShareDoc.Topic(Round(t.Start), Swap(t.Title), Swap(t.Summary), [.. t.Points.Select(Swap)]))],
                [.. n.Conclusions.Select(c => new ShareDoc.Item(Swap(c.Text), null, c.T is { } t ? Round(t) : null))],
                [.. n.Todos.Select(c => new ShareDoc.Item(Swap(c.Text), names && c.Owner is { } o ? Swap(o) : null, c.T is { } t ? Round(t) : null))],
                names ? [.. n.Terms.Select(t => new ShareDoc.Term(t.Name, t.Note))] : []);
        }
        var hidden = (scope == ShareScope.Full ? removed.Count : 0) + (dropNotes && s.Notes is { IsEmpty: false } ? 1 : 0);
        var started = s.StartedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        return new(SessionStore.DisplayTitle(s), started, (int)Math.Round(s.Duration.TotalSeconds, MidpointRounding.AwayFromZero),
            Languages(s.Lines), notes, lines, hidden);
    }

    public static List<int> Kept(Session s, ShareScope scope, ISet<int> removed) =>
        scope == ShareScope.Full ? [.. Enumerable.Range(0, s.Lines.Count).Where(i => !removed.Contains(i) && s.Lines[i].Src.Length > 0)] : [];

    public static List<string> Languages(IReadOnlyList<TranscriptLine> lines)
    {
        var count = new Dictionary<string, int>();
        var first = new Dictionary<string, int>();
        for (int i = 0; i < lines.Count; i++)
        {
            var l = lines[i];
            if (l.Dst is null) continue;
            var key = Base(l.SrcLang) + ">" + Base(l.DstLang);
            count[key] = count.GetValueOrDefault(key) + 1;
            first.TryAdd(key, i);
        }
        if (count.Count == 0) return [];
        var top = count.Keys.OrderByDescending(k => count[k]).ThenBy(k => first[k]).First();
        return [.. top.Split('>')];
    }

    static string Base(string code) => (code.Split('-', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? code).ToLowerInvariant();

    static double Round(double t) => Math.Round(t * 10, MidpointRounding.AwayFromZero) / 10;

    public static string Named(string text, IReadOnlyDictionary<int, string> names)
    {
        if (names.Count == 0 || !(text.Contains("说话人") || text.Contains("Speaker"))) return text;
        foreach (var (n, name) in names.OrderByDescending(kv => kv.Key))
            foreach (var form in new[] { $"说话人 {n}", $"说话人{n}", $"Speaker {n}" })
                text = text.Replace(form, name, StringComparison.Ordinal);
        return text;
    }

    public static string Encode(ShareDoc d)
    {
        var b = new StringBuilder();
        b.Append("{\"duration\":").Append(d.Duration.ToString(CultureInfo.InvariantCulture));
        b.Append(",\"hidden\":").Append(d.Hidden.ToString(CultureInfo.InvariantCulture));
        b.Append(",\"langs\":"); List(b, d.Langs, Str);
        b.Append(",\"lines\":"); List(b, d.Lines, (b, l) =>
        {
            b.Append('{');
            if (l.Dst is not null) { b.Append("\"dst\":"); Str(b, l.Dst); b.Append(','); }
            b.Append("\"src\":"); Str(b, l.Src);
            b.Append(",\"t\":"); Num(b, l.T);
            b.Append(",\"who\":"); Str(b, l.Who);
            b.Append('}');
        });
        if (d.Notes is { } n)
        {
            b.Append(",\"notes\":{\"conclusions\":"); List(b, n.Conclusions, ItemJson);
            b.Append(",\"summary\":"); Str(b, n.Summary);
            b.Append(",\"terms\":"); List(b, n.Terms, (b, t) => { b.Append("{\"name\":"); Str(b, t.Name); b.Append(",\"note\":"); Str(b, t.Note); b.Append('}'); });
            b.Append(",\"todos\":"); List(b, n.Todos, ItemJson);
            b.Append(",\"topics\":"); List(b, n.Topics, (b, t) =>
            {
                b.Append("{\"points\":"); List(b, t.Points, Str);
                b.Append(",\"start\":"); Num(b, t.Start);
                b.Append(",\"summary\":"); Str(b, t.Summary);
                b.Append(",\"title\":"); Str(b, t.Title);
                b.Append('}');
            });
            b.Append('}');
        }
        b.Append(",\"startedAt\":"); Str(b, d.StartedAt);
        b.Append(",\"title\":"); Str(b, d.Title);
        b.Append(",\"v\":1}");
        return b.ToString();
    }

    static void ItemJson(StringBuilder b, ShareDoc.Item i)
    {
        b.Append('{');
        if (i.Owner is not null) { b.Append("\"owner\":"); Str(b, i.Owner); b.Append(','); }
        if (i.T is { } t) { b.Append("\"t\":"); Num(b, t); b.Append(','); }
        b.Append("\"text\":"); Str(b, i.Text);
        b.Append('}');
    }

    static void List<T>(StringBuilder b, IEnumerable<T> items, Action<StringBuilder, T> each)
    {
        b.Append('[');
        bool first = true;
        foreach (var x in items) { if (!first) b.Append(','); first = false; each(b, x); }
        b.Append(']');
    }

    static void Num(StringBuilder b, double v) => b.Append(v.ToString("R", CultureInfo.InvariantCulture));

    static void Str(StringBuilder b, string s)
    {
        b.Append('"');
        foreach (var c in s)
            switch (c)
            {
                case '"': b.Append("\\\""); break;
                case '\\': b.Append("\\\\"); break;
                case '\n': b.Append("\\n"); break;
                case '\r': b.Append("\\r"); break;
                case '\t': b.Append("\\t"); break;
                case '\b': b.Append("\\b"); break;
                case '\f': b.Append("\\f"); break;
                case < ' ': b.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); break;
                default: b.Append(c); break;
            }
        b.Append('"');
    }
}

public sealed class ShareRecord
{
    [JsonPropertyName("createdAt")] public DateTimeOffset CreatedAt { get; set; }
    [JsonPropertyName("expiresAt")] public DateTimeOffset ExpiresAt { get; set; }
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("password")] public string? Password { get; set; }
    [JsonPropertyName("scope")] public string Scope { get; set; } = "notes";
    [JsonPropertyName("token")] public string Token { get; set; } = "";
    [JsonPropertyName("url")] public string Url { get; set; } = "";

    public string Message(string title, DateTimeOffset now)
    {
        var left = DaysLeft(now);
        var valid = left >= 365 ? Strings.L("1 年内有效") : Strings.LF("%lld 天内有效", left);
        var last = Password is { } pw ? Strings.LF("密码：%@（%@）", pw, valid) : valid;
        return string.Join("\n", Strings.LF("「%@」会议记录", title), Url, last);
    }

    public int DaysLeft(DateTimeOffset now) => Math.Max(1, (int)Math.Ceiling((ExpiresAt - now - TimeSpan.FromHours(1)).TotalDays));
}

public sealed record ShareHit(
    [property: JsonPropertyName("part")] string Part,
    [property: JsonPropertyName("from")] int? From,
    [property: JsonPropertyName("to")] int? To,
    [property: JsonPropertyName("questions")] List<string> Questions)
{
    public static HashSet<int> RecordLines(IEnumerable<ShareHit> hits, IReadOnlyList<int> kept)
    {
        var outp = new HashSet<int>();
        foreach (var h in hits)
        {
            if (h.Part != "lines" || h.From is not { } a || h.To is not { } b || a > b) continue;
            for (int i = Math.Max(0, a); i <= b && i < kept.Count; i++) outp.Add(kept[i]);
        }
        return outp;
    }
}

public static class SharePassword
{
    public const int Iterations = 210_000;

    public static byte[] Verifier(string password, byte[] salt, int iterations = Iterations) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password), salt, iterations, HashAlgorithmName.SHA256, 32);

    public static string Make()
    {
        var w = Words.Split(' ');
        return $"{w[RandomNumberGenerator.GetInt32(w.Length)]}-{RandomNumberGenerator.GetInt32(10, 100)}-{w[RandomNumberGenerator.GetInt32(w.Length)]}";
    }

    const string Words = "amber apple arrow aspen basil beach birch bloom brook cedar cherry cloud coral comet dawn delta dune ember fern field flint frost grove harbor hazel honey iris island jade lake lark lemon lily linen maple meadow mint moss olive orbit pearl pine plum pond quartz rain reed river ruby sage sand shell silk sky slate snow spruce stone storm sun tide tulip velvet willow wind";
}

public static class SecretFile
{
    public static bool Write(IKeyProtector protector, string path, string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var body = protector.Tag == "plain" ? text : "dpapi:" + Convert.ToBase64String(protector.Protect(Encoding.UTF8.GetBytes(text)));
            if (!OperatingSystem.IsWindows())
            {
                using (File.Create(path, 1, FileOptions.None)) { }
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
            File.WriteAllText(path, body);
            return true;
        }
        catch (Exception e)
        {
            Log.Debug($"share: could not write {Path.GetFileName(path)} {e.GetType().Name}");
            return false;
        }
    }

    public static string? Read(IKeyProtector protector, string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var text = File.ReadAllText(path).Trim();
            return text.StartsWith("dpapi:") ? Encoding.UTF8.GetString(protector.Unprotect(Convert.FromBase64String(text["dpapi:".Length..]))) : text;
        }
        catch (Exception e)
        {
            Log.Debug($"share: could not read {Path.GetFileName(path)} {e.GetType().Name}");
            return null;
        }
    }
}

public sealed class ShareStore(IKeyProtector protector, string? folder = null)
{
    public string Folder => folder ?? Path.Combine(Paths.Root, "Shares");
    string FileOf(string sessionId) => Path.Combine(Folder, sessionId + ".json");

    public ShareRecord? Read(string sessionId)
    {
        if (SecretFile.Read(protector, FileOf(sessionId)) is not { } text) return null;
        try { return Json.Read<ShareRecord>(text); } catch { return null; }
    }

    public void Save(ShareRecord r, string sessionId) => SecretFile.Write(protector, FileOf(sessionId), JsonSerializer.Serialize(r, Json.Compact));

    public void Remove(string sessionId) { try { File.Delete(FileOf(sessionId)); } catch { } }

    public Dictionary<string, ShareRecord> All()
    {
        var outp = new Dictionary<string, ShareRecord>();
        if (!Directory.Exists(Folder)) return outp;
        foreach (var f in Directory.GetFiles(Folder, "*.json"))
        {
            var id = Path.GetFileNameWithoutExtension(f);
            if (Read(id) is { } r) outp[id] = r;
        }
        return outp;
    }
}

public sealed record ShareOptions
{
    public ShareScope Scope { get; init; } = ShareScope.Notes;
    public int Days { get; init; } = 7;
    public bool Names { get; init; }
    public string? Password { get; init; }
    public bool SummaryInPreview { get; init; }
    public HashSet<int> Removed { get; init; } = [];
    public bool DropNotes { get; init; }
}

public abstract record ShareOutcome
{
    public sealed record Shared(ShareRecord Record) : ShareOutcome;
    public sealed record Blocked(List<ShareHit> Hits, List<int> Kept) : ShareOutcome;
    public sealed record Failed(string Code, int? RetryAfter) : ShareOutcome;
}

public sealed class ShareClient
{
    readonly IKeyProtector protector;
    readonly string platform, version;
    readonly HttpClient http;
    readonly SemaphoreSlim registering = new(1, 1);
    public ShareStore Store { get; }

    public ShareClient(IKeyProtector protector, string platform, string version, HttpMessageHandler? handler = null, string? folder = null)
    {
        this.protector = protector; this.platform = platform; this.version = version;
        http = new HttpClient(handler ?? new HttpClientHandler()) { Timeout = TimeSpan.FromSeconds(90) };
        root = folder;
        Store = new ShareStore(protector, folder is null ? null : Path.Combine(folder, "Shares"));
    }

    readonly string? root;

    public Uri Base => Environment.GetEnvironmentVariable("CICADA_SHARE_SERVER") is { Length: > 0 } s && Uri.TryCreate(s, UriKind.Absolute, out var u)
        ? u : new Uri("https://cicada.indaloop.app");

    string DeviceFile => Path.Combine(root ?? Paths.Root, "share-device.json");

    sealed class Device
    {
        [JsonPropertyName("device")] public string? Id { get; set; }
        [JsonPropertyName("key")] public string Key { get; set; } = "";
        [JsonPropertyName("server")] public string? Server { get; set; }
    }

    Device LoadDevice()
    {
        if (SecretFile.Read(protector, DeviceFile) is { } text)
            try
            {
                if (Json.Read<Device>(text) is { } d && Convert.FromBase64String(d.Key).Length == 32) return d;
            }
            catch { }
        var f = new Device { Key = Convert.ToBase64String(Ed25519.NewKey()) };
        SaveDevice(f);
        return f;
    }

    void SaveDevice(Device d) => SecretFile.Write(protector, DeviceFile, JsonSerializer.Serialize(d, Json.Compact));

    async Task<(byte[] key, string id)> Registered(bool force = false)
    {
        await registering.WaitAsync();
        try
        {
            var d = LoadDevice();
            var key = Convert.FromBase64String(d.Key);
            if (!force && d.Id is { } known && d.Server == Base.AbsoluteUri) return (key, known);
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var pub = Ed25519.PublicKey(key);
            var nonce = await Task.Run(() => ProofOfWork(pub));
            Log.Debug($"share: proof of work in {watch.ElapsedMilliseconds} ms");
            var body = new JsonObject { ["key"] = B64Url(pub), ["pow"] = B64Url(nonce), ["platform"] = platform, ["version"] = version }.ToJsonString();
            var (data, status) = await Send("POST", "/api/v1/devices", body, null, null);
            var id = status == 201 ? Field(data, "device") : null;
            if (id is null)
            {
                Log.Debug($"share: register failed {status} {Field(data, "code") ?? "?"}");
                throw new Failure(Field(data, "code") ?? "register_failed", RetryAfter(data));
            }
            d.Id = id; d.Server = Base.AbsoluteUri;
            SaveDevice(d);
            Log.Debug("share: device registered");
            return (key, id);
        }
        finally { registering.Release(); }
    }

    public static byte[] ProofOfWork(byte[] pub)
    {
        var work = new byte[pub.Length + 8];
        pub.CopyTo(work, 0);
        Span<byte> h = stackalloc byte[32];
        for (ulong n = 0; ; n++)
        {
            System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(work.AsSpan(pub.Length), n);
            SHA256.HashData(work, h);
            if (h[0] == 0 && h[1] == 0 && h[2] < 16) return work[pub.Length..];
        }
    }

    sealed class Failure(string code, int? retryAfter) : Exception
    {
        public string Code { get; } = code;
        public int? RetryAfter { get; } = retryAfter;
    }

    async Task<(string body, int status)> Send(string method, string path, string? body, Dictionary<string, string>? headers, (byte[] key, string id)? signer)
    {
        using var req = new HttpRequestMessage(new HttpMethod(method), new Uri(Base, path));
        if (body is not null) req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        req.Headers.TryAddWithoutValidation("X-Cicada-Client", $"{platform}/{version}");
        foreach (var (k, v) in headers ?? []) req.Headers.TryAddWithoutValidation(k, v);
        if (signer is var (key, id))
        {
            var time = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
            var nonce = B64Url(RandomNumberGenerator.GetBytes(16));
            var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(body ?? "")));
            var message = $"{method}\n{req.RequestUri!.PathAndQuery}\n{time}\n{nonce}\n{hash}";
            req.Headers.TryAddWithoutValidation("X-Cicada-Device", id);
            req.Headers.TryAddWithoutValidation("X-Cicada-Time", time);
            req.Headers.TryAddWithoutValidation("X-Cicada-Nonce", nonce);
            req.Headers.TryAddWithoutValidation("X-Cicada-Signature", B64Url(Ed25519.Sign(key, Encoding.UTF8.GetBytes(message))));
        }
        try
        {
            using var resp = await http.SendAsync(req);
            return (await resp.Content.ReadAsStringAsync(), (int)resp.StatusCode);
        }
        catch (Exception e)
        {
            Log.Debug($"share: {method} failed {e.GetType().Name}");
            throw new Failure("network", null);
        }
    }

    async Task<(string body, int status)> Signed(string method, string path, string? body = null, Dictionary<string, string>? headers = null)
    {
        var signer = await Registered();
        var (data, status) = await Send(method, path, body, headers, signer);
        if (status == 401 && Field(data, "code") == "unknown_device")
        {
            signer = await Registered(force: true);
            (data, status) = await Send(method, path, body, headers, signer);
        }
        return (data, status);
    }

    public async Task<ShareOutcome> Share(Session s, ShareOptions o)
    {
        try { return await Attempt(s, o); }
        catch (Exception e)
        {
            Log.Debug($"share: {e.GetType().Name}");
            return new ShareOutcome.Failed("server_error", null);
        }
    }

    async Task<ShareOutcome> Attempt(Session s, ShareOptions o)
    {
        var doc =ShareProjection.Encode(ShareProjection.Doc(s, o.Scope, o.Names, o.Removed, o.DropNotes));
        var kept = ShareProjection.Kept(s, o.Scope, o.Removed);
        var scope = o.Scope == ShareScope.Full ? "full" : "notes";
        var body = new JsonObject
        {
            ["doc"] = JsonNode.Parse(doc), ["scope"] = scope, ["days"] = o.Days, ["summaryInPreview"] = o.SummaryInPreview,
        };
        if (o.Password is { } pw)
        {
            var salt = RandomNumberGenerator.GetBytes(16);
            var v = await Task.Run(() => SharePassword.Verifier(pw, salt));
            body["password"] = new JsonObject { ["salt"] = B64Url(salt), ["iter"] = SharePassword.Iterations, ["hash"] = B64Url(SHA256.HashData(v)) };
        }
        var settings = $"{scope}|{o.Days}|{(o.Names ? "true" : "false")}|{o.Password ?? ""}|{(o.SummaryInPreview ? "true" : "false")}";
        var idem = s.Id + "-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(doc + settings))[..8]);
        try
        {
            var (data, status) = await Signed("POST", "/api/v1/shares", body.ToJsonString(Json.Compact), new() { ["Idempotency-Key"] = idem });
            var obj = Parse(data);
            switch (status)
            {
                case 200 or 201:
                    if (obj?["id"]?.GetValue<string>() is not { } id || obj["url"]?.GetValue<string>() is not { } url
                        || obj["token"]?.GetValue<string>() is not { } token || obj["expiresAt"] is not JsonValue exp)
                        return new ShareOutcome.Failed("server_error", null);
                    if (Store.Read(s.Id) is { } old && old.Id != id) await Revoke(old, null);
                    var r = new ShareRecord
                    {
                        Id = id, Url = url, Token = token, ExpiresAt = DateTimeOffset.FromUnixTimeSeconds((long)exp.GetValue<double>()),
                        Scope = scope, Password = o.Password, CreatedAt = DateTimeOffset.UtcNow,
                    };
                    Store.Save(r, s.Id);
                    Log.Debug($"share: {s.Id} shared ({scope}, {o.Days} days{(o.Password is null ? "" : ", password")})");
                    return new ShareOutcome.Shared(r);
                case 422:
                    var hits = obj?["hits"]?.Deserialize<List<ShareHit>>(Json.Compact) ?? [];
                    Log.Debug($"share: {s.Id} blocked " + string.Join("; ", hits.Select(h => h.Part + (h.From is { } f ? $" {f}-{h.To ?? f}" : "") + " " + string.Join(",", h.Questions))));
                    return new ShareOutcome.Blocked(hits, kept);
                default:
                    Log.Debug($"share: {s.Id} failed {status} {Field(data, "code") ?? "?"}");
                    return new ShareOutcome.Failed(Field(data, "code") ?? "server_error", RetryAfter(data));
            }
        }
        catch (Failure f) { return new ShareOutcome.Failed(f.Code, f.RetryAfter); }
        catch (Exception e)
        {
            Log.Debug($"share: {e.GetType().Name}");
            return new ShareOutcome.Failed("server_error", null);
        }
    }

    public async Task<bool> Revoke(ShareRecord r, string? sessionId)
    {
        bool ok;
        try
        {
            var (data, status) = await Signed("DELETE", "/api/v1/shares/" + r.Id, null, new() { ["Authorization"] = "Bearer " + r.Token });
            ok = status is 204 or 404;
            if (!ok) Log.Debug($"share: revoke failed {status} {Field(data, "code") ?? "?"}");
        }
        catch (Exception e) { Log.Debug($"share: revoke {e.GetType().Name}"); ok = false; }
        if (ok && sessionId is not null) Store.Remove(sessionId);
        return ok;
    }

    public sealed record Stats(string Id, double ExpiresAt, string State, int Views);

    public async Task<Dictionary<string, Stats>> StatsOf(IEnumerable<string> ids)
    {
        var list = ids.ToList();
        var outp = new Dictionary<string, Stats>();
        if (list.Count == 0) return outp;
        try
        {
            var (data, status) = await Signed("GET", "/api/v1/shares?ids=" + string.Join(",", list));
            if (status != 200 || Parse(data)?["shares"] is not JsonArray shares) return outp;
            foreach (var x in shares)
                if (x?["id"]?.GetValue<string>() is { } id)
                    outp[id] = new(id, x["expiresAt"]?.GetValue<double>() ?? 0, x["state"]?.GetValue<string>() ?? "", (int)(x["views"]?.GetValue<double>() ?? 0));
        }
        catch (Exception e) { Log.Debug($"share: stats {e.GetType().Name}"); }
        return outp;
    }

    public static string B64Url(byte[] d) => Convert.ToBase64String(d).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    static JsonNode? Parse(string text) { try { return JsonNode.Parse(text); } catch { return null; } }
    static string? Field(string text, string key) { try { return Parse(text)?[key]?.GetValue<string>(); } catch { return null; } }
    static int? RetryAfter(string text) { try { return Parse(text)?["retryAfter"] is JsonValue v ? (int)v.GetValue<double>() : null; } catch { return null; } }
}
