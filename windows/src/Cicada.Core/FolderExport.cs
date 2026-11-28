using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Cicada;

public static class FolderExportFormat
{
    public static string Name(Session s)
    {
        if (s.Renamed ?? !s.Title.StartsWith("会议 ", StringComparison.Ordinal)) return s.Title;
        if (s.Notes?.Title is { Length: > 0 } t) return t;
        if (s.SourceFile is { } file) return Path.GetFileNameWithoutExtension(file);
        return "";
    }

    public static string SafeName(string name)
    {
        var spaced = new StringBuilder();
        foreach (var r in name.EnumerateRunes())
            spaced.Append(r.Value < 0x20 || (r.IsAscii && "/\\:*?\"<>|#^[]".Contains((char)r.Value)) ? " " : r.ToString());
        var joined = new StringBuilder();
        bool space = false;
        foreach (var r in spaced.ToString().EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(r)) { space = true; continue; }
            if (space && joined.Length > 0) joined.Append(' ');
            space = false;
            joined.Append(r.ToString());
        }
        var output = Trim(joined.ToString());
        if (Encoding.UTF8.GetByteCount(output) > 120)
        {
            var cut = new StringBuilder();
            int bytes = 0;
            foreach (var r in output.EnumerateRunes())
            {
                bytes += r.Utf8SequenceLength;
                if (bytes > 120) break;
                cut.Append(r.ToString());
            }
            output = Trim(cut.ToString());
        }
        return output;
    }

    static string Trim(string s) => s.Trim(' ', '.');

    public static string Stem(Session s, TimeZoneInfo? zone = null)
    {
        var date = Local(s.StartedAt, zone).ToString("yyyy-MM-dd HHmm", CultureInfo.InvariantCulture);
        var safe = SafeName(Name(s));
        return safe.Length == 0 ? date : $"{date} {safe}";
    }

    public static string FileName(string stem, Func<string, bool> taken)
    {
        for (int n = 1; ; n++)
        {
            var name = n == 1 ? $"{stem}.md" : $"{stem} {n}.md";
            if (!taken(name)) return name;
        }
    }

    public static string Quote(string s)
    {
        var b = new StringBuilder("\"");
        foreach (var c in s)
        {
            switch (c)
            {
                case '\\': b.Append("\\\\"); break;
                case '"': b.Append("\\\""); break;
                case '\n': b.Append("\\n"); break;
                case '\r': b.Append("\\r"); break;
                case '\t': b.Append("\\t"); break;
                case < ' ': b.Append($"\\u{(int)c:x4}"); break;
                default: b.Append(c); break;
            }
        }
        return b.Append('"').ToString();
    }

    public static string Frontmatter(Session s, TimeZoneInfo? zone = null)
    {
        var ended = s.EndedAt ?? s.StartedAt;
        var languages = s.Lines.Select(l => l.SrcLang).Distinct().OrderBy(x => x, StringComparer.Ordinal);
        var notes = s.Notes is not { IsEmpty: false } n ? "none" : n.Final ? "final" : "draft";
        string[] lines =
        [
            "---",
            "cicada: 1",
            $"id: {Quote(s.Id)}",
            $"title: {Quote(Name(s))}",
            $"started: {Quote(Time(s.StartedAt, zone))}",
            $"ended: {Quote(Time(ended, zone))}",
            $"minutes: {Math.Max(0, (long)Math.Floor((ended - s.StartedAt).TotalSeconds / 60))}",
            $"languages: [{string.Join(", ", languages.Select(Quote))}]",
            $"source: {Quote(s.SourceFile is null ? "meeting" : "file")}",
            $"notes: {Quote(notes)}",
            "tags: [\"cicada\"]",
            "---",
        ];
        return string.Join("\n", lines) + "\n";
    }

    public static string Document(Session s) => Frontmatter(s) + SessionStore.Markdown(s);

    static DateTimeOffset Local(DateTimeOffset at, TimeZoneInfo? zone) => TimeZoneInfo.ConvertTime(at, zone ?? TimeZoneInfo.Local);

    static string Time(DateTimeOffset at, TimeZoneInfo? zone) => Local(at, zone).ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);

    // MARK: Paths (split on both separators: the tests run on the Mac, the app on Windows)

    static readonly char[] Separators = ['\\', '/'];

    public static bool Under(string path, string root)
    {
        var p = path.TrimEnd(Separators);
        var r = root.TrimEnd(Separators);
        if (r.Length == 0) return false;
        if (string.Equals(p, r, StringComparison.OrdinalIgnoreCase)) return true;
        return p.Length > r.Length && p.StartsWith(r, StringComparison.OrdinalIgnoreCase) && Separators.Contains(p[r.Length]);
    }

    public static string? Parent(string path)
    {
        var p = path.TrimEnd(Separators);
        int i = p.LastIndexOfAny(Separators);
        if (i <= 0) return null;
        var parent = p[..i];
        return parent.EndsWith(':') ? parent + p[i] : parent;
    }

    public static string LastName(string path)
    {
        var p = path.TrimEnd(Separators);
        int i = p.LastIndexOfAny(Separators);
        return i < 0 ? p : p[(i + 1)..];
    }

    public static string ShortPath(string folder, Func<string, string?>? name = null)
    {
        string Named(string p) => name?.Invoke(p) is { Length: > 0 } n ? n : LastName(p) is { Length: > 0 } l ? l : p;
        return Parent(folder) is { } parent ? $"{Named(parent)} › {Named(folder)}" : Named(folder);
    }

    // MARK: Obsidian

    public static List<string> ObsidianVaults(string json, Func<string, bool>? exists = null)
    {
        exists ??= Directory.Exists;
        try
        {
            if (JsonNode.Parse(json)?["vaults"] is not JsonObject vaults) return [];
            return vaults
                .Select(v => (Path: v.Value?["path"]?.GetValueKind() == System.Text.Json.JsonValueKind.String ? (string?)v.Value["path"] : null,
                              Ts: v.Value?["ts"]?.GetValueKind() == System.Text.Json.JsonValueKind.Number ? (double)v.Value["ts"]! : 0))
                .Where(v => v.Path is not null && exists(v.Path))
                .OrderByDescending(v => v.Ts)
                .Select(v => v.Path!)
                .ToList();
        }
        catch (Exception) { return []; }
    }

    public static List<string> ObsidianVaults()
    {
        var file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "obsidian", "obsidian.json");
        try { return File.Exists(file) ? ObsidianVaults(File.ReadAllText(file)) : []; }
        catch (Exception) { return []; }
    }

    public static string? Vault(string folder, IEnumerable<string>? vaults = null) => (vaults ?? ObsidianVaults()).FirstOrDefault(v => Under(folder, v));

    public static string DocumentsFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Cicada");

    public static string DefaultFolder() => ObsidianVaults().FirstOrDefault() is { } v ? Path.Combine(v, "Cicada") : DocumentsFolder;

    // MARK: Controlled folder access

    public static List<string> ProtectedRoots()
    {
        Environment.SpecialFolder[] known =
        [
            Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.MyPictures, Environment.SpecialFolder.MyVideos,
            Environment.SpecialFolder.MyMusic, Environment.SpecialFolder.DesktopDirectory, Environment.SpecialFolder.Favorites,
            Environment.SpecialFolder.CommonDocuments, Environment.SpecialFolder.CommonPictures, Environment.SpecialFolder.CommonVideos,
            Environment.SpecialFolder.CommonMusic, Environment.SpecialFolder.CommonDesktopDirectory,
        ];
        return known.Select(Environment.GetFolderPath).Where(p => p.Length > 0).Distinct().ToList();
    }

    public static bool Protected(string folder, IEnumerable<string>? roots = null) => (roots ?? ProtectedRoots()).Any(r => Under(folder, r));
}

public sealed class FolderExporter
{
    public enum Kind { Denied, Missing, Failed }

    public sealed record Problem(Kind Kind, string? Message = null);

    public sealed class Index
    {
        [JsonPropertyName("folder")] public string Folder { get; set; } = "";
        [JsonPropertyName("files")] public Dictionary<string, string> Files { get; set; } = [];
        [JsonPropertyName("pending")] public List<string> Pending { get; set; } = [];
        [JsonPropertyName("lastFile")] public string? LastFile { get; set; }
        [JsonPropertyName("lastAt")] public DateTimeOffset? LastAt { get; set; }
    }

    readonly SessionStore store;
    readonly AppSettings settings;
    readonly string indexPath;
    readonly Timer timer;
    bool scheduledFromMeeting;
    Task worker = Task.CompletedTask;
    readonly object workerGate = new();
    bool writing, again, againFromMeeting;
    bool notified;

    public Index State { get; private set; } = new();
    public Problem? Trouble { get; private set; }
    public bool Checking { get; private set; }

    public Action<Action> Post { get; set; } = a => a();
    public Func<string?> LiveId { get; set; } = () => null;
    public Func<string, bool> Settling { get; set; } = _ => false;
    public Action? NotifyDenied { get; set; }
    public TimeSpan Delay { get; set; } = TimeSpan.FromSeconds(2);
    public event Action? Changed;

    public FolderExporter(SessionStore store, AppSettings settings, string? indexPath = null)
    {
        this.store = store;
        this.settings = settings;
        this.indexPath = indexPath ?? Path.Combine(Paths.Root, "FolderExport.json");
        timer = new Timer(_ => { var m = scheduledFromMeeting; Post(() => Flush(m)); }, null, Timeout.Infinite, Timeout.Infinite);
        try { if (File.Exists(this.indexPath) && Json.Read<Index>(File.ReadAllText(this.indexPath)) is { } i) State = i; }
        catch (Exception e) { Log.Debug($"folder export: index unreadable ({e.GetType().Name})"); }
    }

    public bool On => settings.ExportOn && settings.ExportFolder.Length > 0;
    public string? Folder => settings.ExportFolder.Length == 0 ? null : settings.ExportFolder;

    public string? FileFor(string id) =>
        On && State.Folder == settings.ExportFolder && State.Files.TryGetValue(id, out var name) ? Path.Combine(settings.ExportFolder, name) : null;

    public bool IsPending(string id) => On && State.Pending.Contains(id);

    public bool Ready(Session s) => s.EndedAt is not null && s.Importing != true && s.Lines.Count > 0 && s.Id != LiveId();

    public List<Session> Unwritten => store.All().Where(s => Ready(s) && !State.Files.ContainsKey(s.Id) && !State.Pending.Contains(s.Id)).ToList();

    // MARK: Triggers

    public void Ended(string id)
    {
        if (!On) return;
        if (!State.Pending.Contains(id)) State.Pending.Add(id);
        SaveIndex();
        Schedule();
    }

    public void Saved(string id)
    {
        if (!On || !(State.Files.ContainsKey(id) || State.Pending.Contains(id))) return;
        if (!State.Pending.Contains(id)) State.Pending.Add(id);
        Schedule();
    }

    public void Settled(string id) { if (On && State.Pending.Contains(id)) Schedule(); }

    public void WriteAll()
    {
        if (!On) return;
        State.Pending.AddRange(Unwritten.Select(s => s.Id));
        SaveIndex();
        Flush(fromMeeting: false);
    }

    public void Retry()
    {
        if (!On || State.Pending.Count == 0) return;
        Schedule(TimeSpan.FromMilliseconds(500), fromMeeting: false);
    }

    public void Deleted(string id)
    {
        State.Files.Remove(id);
        State.Pending.Remove(id);
        SaveIndex();
        Changed?.Invoke();
    }

    // MARK: Choosing the folder

    public void Choose(string folder)
    {
        settings.ExportFolder = folder;
        settings.ExportOn = true;
        settings.Save();
        if (State.Folder != folder) State = new Index { Folder = folder };
        SaveIndex();
        Checking = true;
        Trouble = null;
        Changed?.Invoke();
        Enqueue(() =>
        {
            var result = Probe(folder);
            Post(() =>
            {
                Checking = false;
                Trouble = result;
                if (result is null) { notified = false; Retry(); }
                Log.Debug($"folder export: chosen → {result?.Kind.ToString() ?? "ok"}");
                Changed?.Invoke();
            });
        });
    }

    public void TurnOff()
    {
        settings.ExportOn = false;
        settings.Save();
        Trouble = null;
        Changed?.Invoke();
    }

    // MARK: Writing

    void Schedule(TimeSpan? after = null, bool fromMeeting = true)
    {
        scheduledFromMeeting = fromMeeting;
        timer.Change(after ?? Delay, Timeout.InfiniteTimeSpan);
    }

    void Enqueue(Action work)
    {
        lock (workerGate) worker = worker.ContinueWith(_ => work(), TaskScheduler.Default);
    }

    public async Task Idle()
    {
        while (true)
        {
            Task w;
            lock (workerGate) w = worker;
            await w;
            lock (workerGate) if (w == worker && !writing) return;
        }
    }

    sealed record Job(string Id, string Stem, string? Old, string Text);

    abstract record Outcome
    {
        public sealed record Wrote(string Id, string Name) : Outcome;
        public sealed record Unchanged(string Id) : Outcome;
        public sealed record Stopped(Problem Problem) : Outcome;
    }

    void Flush(bool fromMeeting)
    {
        if (!On || Folder is not { } folder) return;
        if (writing) { again = true; againFromMeeting |= fromMeeting; return; }
        if (State.Folder != folder) State = new Index { Folder = folder, Pending = State.Pending };
        var jobs = new List<Job>();
        foreach (var id in State.Pending.ToList())
        {
            if (store.Get(id) is not { } s) { State.Pending.Remove(id); continue; }
            if (!Ready(s) || Settling(id)) continue;
            jobs.Add(new Job(id, FolderExportFormat.Stem(s), State.Files.GetValueOrDefault(id), FolderExportFormat.Document(s)));
        }
        SaveIndex();
        if (jobs.Count == 0) return;
        writing = true;
        var ours = new Dictionary<string, string>(State.Files);
        Enqueue(() =>
        {
            var outcomes = Write(jobs, folder, ours);
            Post(() => Apply(outcomes, folder, fromMeeting));
        });
    }

    void Apply(List<Outcome> outcomes, string folder, bool fromMeeting)
    {
        writing = false;
        if (State.Folder == folder)
        {
            Problem? stopped = null;
            foreach (var o in outcomes)
            {
                switch (o)
                {
                    case Outcome.Wrote w:
                        State.Files[w.Id] = w.Name;
                        State.Pending.Remove(w.Id);
                        State.LastFile = w.Name;
                        State.LastAt = DateTimeOffset.Now;
                        break;
                    case Outcome.Unchanged u: State.Pending.Remove(u.Id); break;
                    case Outcome.Stopped p: stopped = p.Problem; break;
                }
            }
            SaveIndex();
            Trouble = stopped;
            Log.Debug($"folder export: {outcomes.Count(o => o is Outcome.Wrote)} written, {outcomes.Count(o => o is Outcome.Unchanged)} unchanged{(stopped is null ? "" : $", stopped: {stopped.Kind}")}");
            if (stopped is null) notified = false;
            if (stopped?.Kind == Kind.Denied && fromMeeting && !notified && !State.Pending.Any(Settling))
            {
                notified = true;
                if (FolderExportFormat.Protected(folder)) Log.Debug("folder export: denied in a protected folder, Windows says so itself");
                else NotifyDenied?.Invoke();
            }
            Changed?.Invoke();
        }
        if (again)
        {
            var m = againFromMeeting;
            again = againFromMeeting = false;
            Flush(m);
        }
    }

    static bool Same(string? a, string? b) => a is not null && b is not null && string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    static List<Outcome> Write(List<Job> jobs, string folder, Dictionary<string, string> ours)
    {
        if (Ensure(folder) is { } p) return [new Outcome.Stopped(p)];
        var output = new List<Outcome>();
        foreach (var job in jobs)
        {
            var mine = new HashSet<string>(ours.Where(o => o.Key != job.Id).Select(o => o.Value), StringComparer.OrdinalIgnoreCase);
            var name = FolderExportFormat.FileName(job.Stem, candidate =>
            {
                if (Same(candidate, job.Old)) return false;
                var at = Path.Combine(folder, candidate);
                return mine.Contains(candidate) || File.Exists(at) || Directory.Exists(at);
            });
            var path = Path.Combine(folder, name);
            if (Same(name, job.Old))
            {
                try { if (File.Exists(path) && File.ReadAllText(path) == job.Text) { output.Add(new Outcome.Unchanged(job.Id)); continue; } }
                catch (Exception) { }
            }
            try { WriteAtomically(path, job.Text); }
            catch (Exception e)
            {
                output.Add(new Outcome.Stopped(Classify(e, folder)));
                return output;
            }
            if (job.Old is { } old && !Same(old, name)) try { File.Delete(Path.Combine(folder, old)); } catch (Exception) { }
            ours[job.Id] = name;
            output.Add(new Outcome.Wrote(job.Id, name));
        }
        return output;
    }

    static void WriteAtomically(string path, string text)
    {
        var tmp = Path.Combine(Path.GetDirectoryName(path)!, $".cicada-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            File.Move(tmp, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(tmp); } catch (Exception) { }
            throw;
        }
    }

    static Problem? Ensure(string folder)
    {
        if (Directory.Exists(folder)) return null;
        if (File.Exists(folder) || FolderExportFormat.Parent(folder) is not { } parent || !Directory.Exists(parent)) return new Problem(Kind.Missing);
        try { Directory.CreateDirectory(folder); return null; }
        catch (Exception e) { return Classify(e, folder); }
    }

    public static Problem? Probe(string folder)
    {
        if (Ensure(folder) is { } p) return p;
        var file = Path.Combine(folder, ".cicada-check");
        try
        {
            File.WriteAllBytes(file, []);
            try { File.Delete(file); } catch (Exception) { }
            return null;
        }
        catch (Exception e) { return Classify(e, folder); }
    }

    static Problem Classify(Exception e, string folder)
    {
        if (e is UnauthorizedAccessException) return new Problem(Kind.Denied);
        if (e is DirectoryNotFoundException or DriveNotFoundException || !Directory.Exists(folder)) return new Problem(Kind.Missing);
        return new Problem(Kind.Failed, e.Message);
    }

    void SaveIndex()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(indexPath)!);
            var tmp = indexPath + ".tmp";
            File.WriteAllText(tmp, Json.Write(State), new UTF8Encoding(false));
            File.Move(tmp, indexPath, overwrite: true);
        }
        catch (Exception e) { Log.Debug($"folder export: index not saved ({e.GetType().Name})"); }
    }
}
