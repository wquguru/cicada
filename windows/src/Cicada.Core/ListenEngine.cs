using System.Threading.Channels;

namespace Cicada;

public sealed class ListenEngine
{
    readonly LingClient ling;
    readonly Translator translator;
    readonly SessionStore store;
    readonly NotesEngine notes;
    readonly AppSettings settings;
    readonly object gate = new();

    IAudioSource? source;
    Channel<(short[] buf, double at)>? audio;
    long began;
    IAudioWriter? recorder;
    public RoomMix? Mix => recorder as RoomMix;
    RoomMix? roomMix;
    Task? worker;
    Segmenter? segmenter;
    readonly Dictionary<int, Heard?> done = [];
    readonly Dictionary<int, Segment> segments = [];
    readonly Dictionary<int, Task<float[]?>> prints = [];
    VoiceClusterer clusterer = new();
    public IVoiceprint? Voiceprint { get; set; }
    readonly List<Task> inFlight = [];
    int nextToDeliver = 1, lineCount;
    TranscriptLine? last;
    double lastEnd;
    string? hint, candidate;
    int candidateVotes;

    public bool Listening { get; private set; }
    public string? SessionId { get; private set; }
    public string? Spoken => hint;
    public int Pending { get { lock (gate) return segments.Count; } }
    public LingException.Kind? Problem { get; private set; }
    public int ProblemStatus { get; private set; }
    int serverErrors;
    public const int ServerErrorsShown = 3;
    public static bool IsServerError(LingException.Kind kind, int status) => kind == LingException.Kind.Http && status >= 500;

    public static (string? Title, string Body, bool Settings) Words(LingException.Kind kind, int status, string service, string? hear = null)
    {
        var ling = service == "Ling";
        if (kind == LingException.Kind.Http && status is 400 or 404 or 415 or 422 && !ling)
            return (Strings.LF("%@ 听不了声音。", hear ?? service), Strings.L("在 设置 › AI 服务 里换一个"), true);
        return kind switch
        {
            LingException.Kind.Http when status >= 500 => (null, Strings.LF("%@ 暂时出错（HTTP %lld），稍后再试。", service, status), false),
            LingException.Kind.RateLimited => ling ?(Strings.L("Ling 太忙"), Strings.L("稍后会自动重试。"), false) : (null, Strings.LF("%@ 太忙，稍后再试", service), false),
            LingException.Kind.InvalidKey => (ling ? Strings.L("Ling key 无效") : Strings.LF("%@ 的 key 无效", service), Strings.L("去设置里换一个 key。"), true),
            LingException.Kind.NoKey => (ling ? Strings.L("Ling key 无效") : Strings.LF("需要 %@ 的 key 才能听", service), Strings.L("去设置里换一个 key。"), true),
            _ => (null, Strings.LF("字幕和纪要等 %@ 恢复 · 连上后自动继续", service), false),
        };
    }

    public void ClearProblem() { Problem = null; Changed?.Invoke(); }

    public void SimulateProblem(string kind)
    {
        var parts = kind.Split(' ');
        Problem = Enum.TryParse<LingException.Kind>(parts[0], true, out var k) ? k : null;
        ProblemStatus = parts.Length > 1 && int.TryParse(parts[1], out var s) ? s : 0;
        Changed?.Invoke();
    }
    public double Level { get; private set; }
    public event Action? Changed;

    public ListenEngine(LingClient ling, Translator translator, SessionStore store, NotesEngine notes, AppSettings settings)
    {
        this.ling = ling; this.translator = translator; this.store = store; this.notes = notes; this.settings = settings;
        translator.Glossary = notes.Glossary;
    }

    public string Target => settings.TargetCode;

    public bool Room { get; private set; }

    public bool RoomSide { get; }
    public const int RoomIDs = 1_000_000;
    public EchoFilter? Echo { get; set; }
    public LoudnessLog? Loudness { get; set; }
    double offset;
    Channel<(Segment seg, Heard heard, double at, double queued)>? held;
    Task? holding;
    CancellationTokenSource? flush;
    readonly Dictionary<int, double> emitted = [];

    public LiveFixes? Fixes { get; set; }

    public void DebugHeard(string text, string lang)
    {
        if (!Listening || SessionId is null) return;
        var start = Math.Max(lastEnd + 2, System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalSeconds);
        Segment seg;
        lock (gate) seg = new Segment(++debugSegments, start, new short[Segmenter.Rate / 2]);
        Record(seg, new Heard(lang, text, null));
        Changed?.Invoke();
    }
    int debugSegments = 100_000;

    public ListenEngine(LingClient ling, Translator translator, SessionStore store, NotesEngine notes, AppSettings settings, bool roomSide)
        : this(ling, translator, store, notes, settings) { RoomSide = roomSide; }

    public void Start(IAudioSource from, bool room = false)
    {
        if (Listening || RoomSide) return;
        var session = store.Begin();
        var since = System.Diagnostics.Stopwatch.GetTimestamp();
        SessionId = session.Id;
        Room = room;
        if (room) store.MarkRoom(session.Id);
        if (settings.RecordAudio && store.Audio is { } files && from is not SilentSource)
        {
            var path = Recording.Partial(Recording.SystemAudio(session.Id));
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                recorder = files.Open(path) is { } file ? new RoomMix(file) : null;
            }
            catch (Exception e) { Log.Debug($"listen: recording not started {e.GetType().Name}"); }
            if (recorder is null) Log.Debug("listen: no recording, the encoder refused");
        }
        Begin(from, room, 0, since);
        Fixes?.MeetingStarted();
        notes.Language = () => Languages.EnglishName(settings.NotesCode);
        notes.Begin(session.Id);
        Log.Debug($"listen: started {session.Id} target={Target}");
        Changed?.Invoke();
    }

    public void Join(IAudioSource mic, string sessionId, DateTimeOffset startedAt, RoomMix? mix = null)
    {
        if (Listening || !RoomSide) return;
        SessionId = sessionId;
        roomMix = mix;
        Room = true;
        store.MarkRoom(sessionId);
        Begin(mic, true, Math.Max(0, (DateTimeOffset.Now - startedAt).TotalSeconds));
        if (Echo is { } echo)
        {
            held = Channel.CreateUnbounded<(Segment, Heard, double, double)>(new UnboundedChannelOptions { SingleReader = true });
            flush = new CancellationTokenSource();
            holding = Hold(held.Reader, echo, flush.Token);
        }
        Log.Debug($"listen: room side joined {sessionId} at {offset:F1}s");
        Changed?.Invoke();
    }

    void Begin(IAudioSource from, bool room, double at, long? since = null)
    {
        lock (gate)
        {
            done.Clear(); segments.Clear(); inFlight.Clear(); prints.Clear(); clusterer = new(); emitted.Clear();
            nextToDeliver = 1; lineCount = RoomSide ? RoomIDs : 0; last = null; lastEnd = 0;
            hint = null; candidate = null; candidateVotes = 0; Problem = null; serverErrors = 0;
        }
        offset = at;
        segmenter = new Segmenter(room ? new VoiceGate() : null);
        segmenter.Emitted += Send;
        audio = Channel.CreateUnbounded<(short[], double)>(new UnboundedChannelOptions { SingleReader = true });
        var reader = audio.Reader;
        began = since ?? System.Diagnostics.Stopwatch.GetTimestamp();
        long fed = 0;
        worker = Task.Run(async () =>
        {
            await foreach (var (buf, at) in reader.ReadAllAsync())
            {
                if (Recording.Behind(at, fed, buf.Length) is > 0 and var gap)
                {
                    var silence = new short[gap];
                    segmenter.Feed(silence);
                    Record(silence, fed);
                    fed += gap;
                }
                Record(buf, fed);
                fed += buf.Length;
                Level = Rms(buf);
                if (!RoomSide && Echo is { } echo && Level >= Segmenter.Threshold) echo.Gate.Hold();
                if (!RoomSide) Loudness?.Add(Level >= Segmenter.Threshold);
                segmenter.Feed(buf);
            }
            segmenter.Flush();
        });
        source = from;
        source.Samples += OnSamples;
        source.Start();
        Listening = true;
    }

    async Task Hold(ChannelReader<(Segment seg, Heard heard, double at, double queued)> reader, EchoFilter echo, CancellationToken stopping)
    {
        await foreach (var (seg, heard, at, queued) in reader.ReadAllAsync())
        {
            var h = new EchoMatch.Heard(heard.Original, at - seg.Seconds, at);
            if (!echo.Quiet(h))
            {
                var wait = queued + EchoMatch.Hold - echo.Gate.Clock();
                if (wait > 0) try { await Task.Delay(TimeSpan.FromSeconds(wait), stopping); } catch (OperationCanceledException) { }
            }
            if (echo.IsEcho(h)) { Log.Debug($"listen: room line dropped as an echo ({heard.Original.Length} chars)"); continue; }
            Record(seg, heard);
            Changed?.Invoke();
        }
    }

    void OnSamples(short[] buf) => audio?.Writer.TryWrite((buf, System.Diagnostics.Stopwatch.GetElapsedTime(began).TotalSeconds));

    void Record(short[] pcm, long fed)
    {
        if (RoomSide)
        {
            roomMix?.Room(pcm, (long)Math.Round(offset * Segmenter.Rate) + fed);
            return;
        }
        if (recorder is null) return;
        try { recorder.Write(pcm); }
        catch (Exception e)
        {
            Log.Debug($"listen: recording failed {e.GetType().Name} 0x{e.HResult:X8}, stopped");
            CloseRecording();
        }
    }

    void CloseRecording()
    {
        var r = recorder;
        recorder = null;
        try { r?.Close(); } catch (Exception e) { Log.Debug($"listen: recording close failed {e.GetType().Name}"); }
    }

    public void SwitchSource(IAudioSource to, bool room)
    {
        if (!Listening || SessionId is not { } id) return;
        if (source is not null) { source.Samples -= OnSamples; source.Stop(); }
        if (room) store.MarkRoom(id);
        Room = room;
        if (segmenter is not null) segmenter.Gate = room ? new VoiceGate() : null;
        source = to;
        source.Samples += OnSamples;
        source.Start();
        Log.Debug($"listen: now {(room ? "the room" : "the computer")}");
        Changed?.Invoke();
    }

    static double Rms(short[] buf)
    {
        if (buf.Length == 0) return 0;
        double sum = 0;
        foreach (var s in buf) sum += (double)s * s;
        return Math.Sqrt(sum / buf.Length) / 32768;
    }

    public async Task Stop(DateTimeOffset? endedAt = null)
    {
        if (!Listening) return;
        Listening = false;
        if (source is not null) { source.Samples -= OnSamples; source.Stop(); }
        audio?.Writer.TryComplete();
        if (worker is not null) await worker;
        Task[] waiting;
        lock (gate) waiting = inFlight.ToArray();
        CloseRecording();
        roomMix = null;
        await Task.WhenAny(Task.WhenAll(waiting), Task.Delay(15_000));
        var id = SessionId!;
        if (RoomSide)
        {
            held?.Writer.TryComplete();
            flush?.Cancel();
            if (holding is not null) await holding;
            held = null; holding = null;
            Log.Debug($"listen: room side stopped, {lineCount - RoomIDs} lines");
            Changed?.Invoke();
            return;
        }
        store.End(id, endedAt);
        Log.Debug($"listen: stopped {id}, {lineCount} lines");
        Changed?.Invoke();
        _ = notes.Finish();
    }

    void Send(Segment seg)
    {
        var wav = Wav.Bytes(seg.Samples);
        string? lang;
        lock (gate)
        {
            segments[seg.Index] = seg; lang = hint;
            if (Echo is { } echo) emitted[seg.Index] = echo.Gate.Clock();
            if (settings.SpeakerVoices && Voiceprint is { } vp) prints[seg.Index] = Task.Run(() => vp.Embed(seg.Samples));
        }
        Changed?.Invoke();
        var task = Task.Run(async () =>
        {
            Heard? heard = null;
            var started = DateTime.UtcNow;
            try
            {
                heard = await translator.Hear(wav, Target, lang);
                Interlocked.Exchange(ref serverErrors, 0);
                Problem = null;
            }
            catch (LingException e)
            {
                var server = IsServerError(e.Failure, e.Status);
                if (!server) Interlocked.Exchange(ref serverErrors, 0);
                if (!server || Interlocked.Increment(ref serverErrors) >= ServerErrorsShown)
                {
                    Problem = e.Failure is LingException.Kind.Hijacked or LingException.Kind.Parse ? null : e.Failure;
                    ProblemStatus = e.Status;
                }
                Log.Debug($"listen: segment {seg.Index} failed {e.Message}");
            }
            Log.Debug($"listen: segment {seg.Index} {seg.Seconds:F1}s -> {(heard is null ? "nothing" : heard.Lang)} in {(DateTime.UtcNow - started).TotalMilliseconds:F0} ms");
            lock (gate) done[seg.Index] = heard;
            Deliver();
        });
        lock (gate) { inFlight.Add(task); inFlight.RemoveAll(t => t.IsCompleted); }
    }

    void Deliver()
    {
        var ready = new List<(Segment seg, Heard? heard)>();
        lock (gate)
        {
            while (done.Remove(nextToDeliver, out var heard))
            {
                ready.Add((segments[nextToDeliver], heard));
                segments.Remove(nextToDeliver);
                nextToDeliver++;
            }
        }
        foreach (var (seg, heard) in ready)
        {
            if (heard is null) continue;
            if (!RoomSide && Echo is { } words && !string.IsNullOrWhiteSpace(heard.Original)) words.Gate.HeardWords();
            if (RoomSide && held is { } h && Echo is { } echo) h.Writer.TryWrite((seg, heard, EmittedAt(seg), echo.Gate.Clock()));
            else Record(seg, heard);
        }
        if (ready.Count > 0) Changed?.Invoke();
    }

    double EmittedAt(Segment seg)
    {
        lock (gate) return emitted.Remove(seg.Index, out var at) ? at : Echo?.Gate.Clock() ?? 0;
    }

    void Record(Segment seg, Heard heard)
    {
        var id = SessionId!;
        var target = Target;
        if (!RoomSide && Echo is { } echo)
        {
            var at = EmittedAt(seg);
            echo.Online(new EchoMatch.Heard(heard.Original, at - seg.Seconds, at));
        }
        lock (gate)
        {
            if (hint is null) hint = heard.Lang;
            else if (heard.Lang != hint)
            {
                if (candidate == heard.Lang) candidateVotes++; else { candidate = heard.Lang; candidateVotes = 1; }
                if (candidateVotes >= 2) { hint = candidate; candidate = null; candidateVotes = 0; }
            }
            else { candidate = null; candidateVotes = 0; }
        }

        int? voice = null;
        Task<float[]?>? print;
        lock (gate) { prints.Remove(seg.Index, out print); }
        if (print is not null && heard.Original.Count(char.IsLetter) >= 2)
        {
            var v = print.Wait(3000) ? print.Result : null;
            if (v is not null) lock (gate) voice = clusterer.Label(v, seg.Seconds);
        }

        TranscriptLine line;
        bool joined = false;
        lock (gate)
        {
            if (last is not null && Continues(last, seg.Start - lastEnd, heard) && (voice is null || last.Voice is null || voice == last.Voice))
            {
                last.Src = Join(last.Src, heard.Original, heard.Lang);
                last.Dst = last.Dst is null || heard.Translation is null ? null : Join(last.Dst, heard.Translation, target);
                line = last;
                joined = true;
            }
            else
            {
                line = new TranscriptLine
                {
                    Id = $"h{++lineCount}-{(RoomSide ? RoomIDs : 0) + seg.Index}", T = Math.Round(offset + seg.Start, 3), Speaker = "them",
                    Src = heard.Original, Dst = heard.Translation, SrcLang = heard.Lang, DstLang = target, Voice = voice,
                    Via = RoomSide || settings.ListensToRoom ? "room" : null,
                };
                last = line;
            }
            lastEnd = seg.Start + seg.Seconds;
        }
        if (joined) store.Replace(id, line.Copy()); else store.Append(id, line.Copy());
        Fixes?.ApplyKnown(id, line.Id);

        var retranslate = (joined || line.Dst is null) && line.SrcLang != target;
        var context = line.SrcLang != target && ling.Usable ? Fixes?.Context(id, line.Id) : null;
        if (retranslate || context is not null)
        {
            var src = line.Src;
            var lineId = line.Id;
            _ = Task.Run(async () =>
            {
                string? dst = null;
                if (context is not null && Fixes is { } fixes
                    && await translator.TranslateFixing(src, line.SrcLang, target, context, retranslate ? Priority.Translate : Priority.Notes) is { } got)
                {
                    lock (gate) if (line.Src != src) return;
                    dst = got.Translation;
                    fixes.Received(id, lineId, got.Edits);
                }
                if (dst is null && !retranslate) return;
                dst ??= await translator.Translate(src, line.SrcLang, target, Translator.Kind.Sentence, lingTried: context is not null);
                TranscriptLine copy;
                lock (gate)
                {
                    if (dst is null || line.Src != src) return;
                    line.Dst = dst;
                    copy = line.Copy();
                }
                store.Replace(id, copy);
                Changed?.Invoke();
            });
        }
    }

    public static bool Continues(TranscriptLine last, double gap, Heard next)
    {
        if (gap > 0.8 || last.SrcLang != next.Lang) return false;
        var text = last.Src.TrimEnd();
        if (text.Length == 0 || ".!?。！？…".Contains(text[^1])) return false;
        bool cjk = next.Lang.StartsWith("zh") || next.Lang.StartsWith("ja") || next.Lang.StartsWith("ko");
        int size = cjk ? text.Length + next.Original.Length : (text + " " + next.Original).Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
        return size <= (cjk ? 80 : 45);
    }

    public static string Join(string a, string b, string lang)
    {
        bool cjk = lang.StartsWith("zh") || lang.StartsWith("ja");
        a = a.TrimEnd(); b = b.TrimStart();
        if (cjk) return a + b;
        return a + " " + b;
    }
}
