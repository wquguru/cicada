using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Cicada;

public sealed class UpdateChecker
{
    public sealed record Update(string Version, string Page, string? Zip, long Size, string? Setup = null, string? Checksums = null)
    {
        public string? Download => Setup ?? Zip;
    }

    public static readonly TimeSpan Every = TimeSpan.FromHours(4);
    public static readonly TimeSpan Stale = TimeSpan.FromHours(1);

    public string Feed { get; set; } = Environment.GetEnvironmentVariable("CICADA_UPDATE_FEED") is { Length: > 0 } f
        ? f : "https://api.github.com/repos/wquguru/cicada/releases?per_page=20";

    public string Current { get; set; } = "0";

    public Update? Available { get; private set; }
    public DateTimeOffset? LastChecked { get; private set; }
    public event Action? Changed;

    public static readonly TimeSpan Within = TimeSpan.FromSeconds(30);
    public TimeSpan Stall { get; set; } = TimeSpan.FromSeconds(30);

    readonly HttpClient http;
    readonly Action<DateTimeOffset> remember;
    Timer? timer;
    int checking;

    public UpdateChecker(DateTimeOffset? lastChecked, Action<DateTimeOffset> remember, HttpMessageHandler? handler = null)
    {
        LastChecked = lastChecked;
        this.remember = remember;
        http = new HttpClient(handler ?? Handler());
        http.Timeout = System.Threading.Timeout.InfiniteTimeSpan;
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Cicada-Windows");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public void Start()
    {
        _ = Check();
        timer = new Timer(_ => _ = CheckIfDue(Every), null, TimeSpan.FromMinutes(15), TimeSpan.FromMinutes(15));
    }

    public Task CheckIfDue(TimeSpan age) => Due(LastChecked, DateTimeOffset.UtcNow, age) ? Check() : Task.CompletedTask;

    public static bool Due(DateTimeOffset? last, DateTimeOffset now, TimeSpan age) =>
        last is not { } l || now - l >= age || l > now;

    public async Task<bool> Check()
    {
        if (Interlocked.Exchange(ref checking, 1) == 1) return true;
        try
        {
            var text = await Read(Feed);
            if (Decode(text) is not { } releases) { Log.Debug("update: feed unreadable"); return false; }
            var newest = NewestWindows(releases, Arch);
            LastChecked = DateTimeOffset.UtcNow;
            remember(LastChecked.Value);
            Available = newest is not null && IsNewer(newest.Version, Current) ? newest : null;
            Log.Debug($"update: checked, latest Windows {newest?.Version ?? "none"}, running {Current}");
            Changed?.Invoke();
            return true;
        }
        catch (Exception e) { Log.Debug($"update: check failed {e.GetType().Name}"); return false; }
        finally { Volatile.Write(ref checking, 0); }
    }

    async Task<string> Read(string feed)
    {
        if (Uri.TryCreate(feed, UriKind.Absolute, out var uri) && uri.IsFile) return await File.ReadAllTextAsync(uri.LocalPath);
        if (!feed.Contains("://")) return await File.ReadAllTextAsync(feed);
        using var cts = new CancellationTokenSource(Within);
        using var r = await http.GetAsync(feed, cts.Token);
        r.EnsureSuccessStatusCode();
        return await r.Content.ReadAsStringAsync(cts.Token);
    }

    static SocketsHttpHandler Handler() => new()
    {
        ConnectCallback = async (context, cancel) =>
        {
            var socket = new System.Net.Sockets.Socket(System.Net.Sockets.SocketType.Stream, System.Net.Sockets.ProtocolType.Tcp) { NoDelay = true, ReceiveBufferSize = 4 << 20 };
            try { await socket.ConnectAsync(context.DnsEndPoint, cancel); return new System.Net.Sockets.NetworkStream(socket, ownsSocket: true); }
            catch { socket.Dispose(); throw; }
        },
    };

    public static string Arch => RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "ARM64" : "x64";

    public static List<Release>? Decode(string text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text);
            return doc.RootElement.ValueKind switch
            {
                JsonValueKind.Array => doc.RootElement.Deserialize<List<Release>>(),
                JsonValueKind.Object => doc.RootElement.Deserialize<Release>() is { TagName.Length: > 0 } one ? [one] : null,
                _ => null,
            };
        }
        catch (JsonException) { return null; }
    }

    public static Update? NewestWindows(IEnumerable<Release> releases, string arch)
    {
        Update? best = null;
        foreach (var r in releases)
        {
            if (r.Draft || r.Prerelease || r.Assets is null) continue;
            var zip = r.Assets.FirstOrDefault(a => IsZip(a.Name, arch)) ?? (arch == "x64" ? null : r.Assets.FirstOrDefault(a => IsZip(a.Name, "x64")));
            var setup = r.Assets.FirstOrDefault(a => IsSetup(a.Name, arch)) ?? (arch == "x64" ? null : r.Assets.FirstOrDefault(a => IsSetup(a.Name, "x64")));
            if (zip is null && setup is null) continue;
            var sums = r.Assets.FirstOrDefault(a => a.Name == "checksums.txt");
            var u = new Update(r.TagName.TrimStart('v'), r.HtmlUrl, zip?.Url, (setup ?? zip)!.Size, setup?.Url, sums?.Url);
            if (best is null || IsNewer(u.Version, best.Version)) best = u;
        }
        return best;
        static bool IsZip(string name, string arch) => name.StartsWith("Cicada-") && name.EndsWith($"-Windows-{arch}.zip");
    }

    public static bool IsSetup(string name, string arch) =>
        (name.StartsWith("Cicada-") && name.EndsWith($"-Windows-{arch}.exe")) || name == LegacySetupName(arch);
    public static string LegacySetupName(string arch) => arch == "ARM64" ? "Cicada-Setup-arm64.exe" : "Cicada-Setup.exe";

    public static bool ShouldNotify(string version, string? notified, bool busy) => !busy && version != notified;

    public static string? ChecksumFor(string text, string name)
    {
        foreach (var line in text.Split('\n'))
        {
            var parts = line.Trim().Split((char[]?)null, 2, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 && parts[1].TrimStart('*') == name) return parts[0].ToLowerInvariant();
        }
        return null;
    }

    public async Task<string> Download(Update u, Action<double>? progress = null)
    {
        if (u.Setup is null || u.Checksums is null) throw new Failure("这个版本没有可安装的文件");
        var name = Path.GetFileName(new Uri(u.Setup).LocalPath);
        var folder = Path.Combine(Path.GetTempPath(), $"CicadaUpdate-{u.Version}-{Guid.NewGuid():N}"[..40]);
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, name);
        string? expected;
        var stage = "checksums";
        try
        {
            expected = ChecksumFor(await Read(u.Checksums), name);
            stage = "installer";
            await Fetch(u.Setup, file, u.Size, progress);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException)
        {
            var why = e is OperationCanceledException ? (stage == "installer" && e.Data["stalled"] is true ? $"nothing arrived for {Stall.TotalSeconds:0} s" : "timed out") : e.Message;
            Log.Debug($"update: download failed at {stage}: {e.GetType().Name}: {why}{(e.InnerException is { } inner ? $" ({inner.GetType().Name}: {inner.Message})" : "")}");
            try { Directory.Delete(folder, true); } catch { }
            throw new Failure("下载失败");
        }
        string got;
        using (var f = File.OpenRead(file)) got = Convert.ToHexStringLower(await SHA256.HashDataAsync(f));
        if (expected is null || got != expected)
        {
            try { Directory.Delete(folder, true); } catch { }
            throw new Failure("下载的文件校验不通过");
        }
        Log.Debug($"update: downloaded {u.Version}, checksum ok");
        return file;
    }

    public static void CleanDownloads(string? temp = null)
    {
        try
        {
            foreach (var d in Directory.GetDirectories(temp ?? Path.GetTempPath(), "CicadaUpdate-*"))
                try { Directory.Delete(d, true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    async Task Fetch(string url, string to, long expected, Action<double>? progress)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.IsFile) { File.Copy(uri.LocalPath, to, true); progress?.Invoke(1); return; }
        var started = DateTime.UtcNow;
        using var cts = new CancellationTokenSource(Within);
        using var r = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        r.EnsureSuccessStatusCode();
        var total = r.Content.Headers.ContentLength ?? expected;
        await using var src = await r.Content.ReadAsStreamAsync(cts.Token);
        await using var dst = File.Create(to);
        var buffer = new byte[1 << 17];
        long got = 0; int n, last = -1;
        while (true)
        {
            cts.CancelAfter(Stall);
            try { n = await src.ReadAsync(buffer, cts.Token); }
            catch (OperationCanceledException e) { e.Data["stalled"] = true; Log.Debug($"update: stalled after {got} of {total} bytes"); throw; }
            if (n == 0) break;
            await dst.WriteAsync(buffer.AsMemory(0, n));
            got += n;
            if (total > 0 && (int)(got * 100 / total) is var pct && pct != last) { last = pct; progress?.Invoke(Math.Min(1, (double)got / total)); }
        }
        if (r.Content.Headers.ContentLength is { } length && got != length) throw new IOException($"the connection ended after {got} of {length} bytes");
        var seconds = Math.Max(0.001, (DateTime.UtcNow - started).TotalSeconds);
        Log.Debug($"update: fetched {got / 1e6:0.0} MB in {seconds:0.0} s ({got / 1e6 / seconds:0.0} MB/s)");
    }

    public sealed class Failure(string key) : Exception(key) { public string Key => Message; }

    public static bool IsNewer(string a, string b)
    {
        var x = a.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var y = b.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int l = i < x.Length ? x[i] : 0, r = i < y.Length ? y[i] : 0;
            if (l != r) return l > r;
        }
        return false;
    }

    public sealed class Release
    {
        [JsonPropertyName("tag_name")] public string TagName { get; set; } = "";
        [JsonPropertyName("html_url")] public string HtmlUrl { get; set; } = "";
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<Asset>? Assets { get; set; }
    }

    public sealed class Asset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("browser_download_url")] public string? Url { get; set; }
        [JsonPropertyName("size")] public long Size { get; set; }
    }
}
