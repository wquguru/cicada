using System.Text.Json.Serialization;

namespace Cicada;

public sealed class TranscriptLine
{
    [JsonPropertyName("dst")] public string? Dst { get; set; }
    [JsonPropertyName("dstLang")] public string DstLang { get; set; } = "";
    [JsonPropertyName("fixes")] public List<LineFix>? Fixes { get; set; }
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("speaker")] public string Speaker { get; set; } = "them";
    [JsonPropertyName("src")] public string Src { get; set; } = "";
    [JsonPropertyName("srcLang")] public string SrcLang { get; set; } = "";
    [JsonPropertyName("t")] public double T { get; set; }
    [JsonPropertyName("via")] public string? Via { get; set; }
    [JsonPropertyName("voice")] public int? Voice { get; set; }

    [JsonIgnore] public string Shown => Fixes is { Count: > 0 } f ? Correction.Apply(f, Src).Text : Src;

    public TranscriptLine Copy() => (TranscriptLine)MemberwiseClone();
}

public sealed record LineFix
{
    [JsonPropertyName("ask")] public bool? Ask { get; init; }
    [JsonPropertyName("from")] public string From { get; init; } = "";
    [JsonPropertyName("off")] public bool? Off { get; init; }
    [JsonPropertyName("to")] public string To { get; init; } = "";
    [JsonPropertyName("user")] public bool? User { get; init; }

    public LineFix() { }
    public LineFix(string from, string to, bool ask = false, bool off = false, bool user = false)
    {
        From = from; To = to; Ask = ask ? true : null; Off = off ? true : null; User = user ? true : null;
    }

    [JsonIgnore] public bool Applied => Ask != true && Off != true;
}

public sealed class VoiceGuess
{
    [JsonPropertyName("evidence")] public string Evidence { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
}

public sealed class Session
{
    [JsonPropertyName("endedAt")] public DateTimeOffset? EndedAt { get; set; }
    [JsonPropertyName("hasAudio")] public bool HasAudio { get; set; }
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("importing")] public bool? Importing { get; set; }
    [JsonPropertyName("lines")] public List<TranscriptLine> Lines { get; set; } = [];
    [JsonPropertyName("notes")] public MeetingNotes? Notes { get; set; }
    [JsonPropertyName("renamed")] public bool? Renamed { get; set; }
    [JsonPropertyName("room")] public bool? Room { get; set; }
    [JsonPropertyName("sourceFile")] public string? SourceFile { get; set; }
    [JsonPropertyName("sourcePath")] public string? SourcePath { get; set; }
    [JsonPropertyName("startedAt")] public DateTimeOffset StartedAt { get; set; }
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("voiceGuesses")] public Dictionary<string, VoiceGuess>? VoiceGuesses { get; set; }
    [JsonPropertyName("voiceNames")] public Dictionary<string, string>? VoiceNames { get; set; }

    [JsonExtensionData] public Dictionary<string, System.Text.Json.JsonElement>? Unknown { get; set; }

    [JsonIgnore] public TimeSpan Duration => (EndedAt ?? DateTimeOffset.Now) - StartedAt;
}

public sealed class MeetingNotes
{
    [JsonPropertyName("conclusions")] public List<NoteItem> Conclusions { get; set; } = [];
    [JsonPropertyName("covered")] public int Covered { get; set; }
    [JsonPropertyName("final")] public bool Final { get; set; }
    [JsonPropertyName("summary")] public string Summary { get; set; } = "";
    [JsonPropertyName("terms")] public List<NoteTerm> Terms { get; set; } = [];
    [JsonPropertyName("title")] public string? Title { get; set; }
    [JsonPropertyName("todos")] public List<NoteItem> Todos { get; set; } = [];
    [JsonPropertyName("topics")] public List<NoteTopic> Topics { get; set; } = [];
    [JsonPropertyName("updatedAt")] public DateTimeOffset? UpdatedAt { get; set; }

    [JsonIgnore] public bool IsEmpty => Summary.Length == 0 && Topics.Count == 0;
}

public sealed class NoteTopic
{
    [JsonPropertyName("fishbone")] public Fishbone? Fishbone { get; set; }
    [JsonPropertyName("pointTimes")] public List<double?>? PointTimes { get; set; }
    [JsonPropertyName("points")] public List<string> Points { get; set; } = [];
    [JsonPropertyName("start")] public double Start { get; set; }
    [JsonPropertyName("summary")] public string Summary { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";

    public double? PointTime(int i) => PointTimes is { } p && i < p.Count ? p[i] : null;
}

public sealed class Fishbone
{
    [JsonPropertyName("branches")] public List<FishboneBranch> Branches { get; set; } = [];
    [JsonPropertyName("question")] public string Question { get; set; } = "";
}

public sealed class FishboneBranch
{
    [JsonPropertyName("detail")] public string Detail { get; set; } = "";
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("support")] public int Support { get; set; }
    [JsonPropertyName("t")] public double? T { get; set; }
}

public sealed class NoteItem
{
    [JsonPropertyName("owner")] public string? Owner { get; set; }
    [JsonPropertyName("support")] public int Support { get; set; }
    [JsonPropertyName("t")] public double? T { get; set; }
    [JsonPropertyName("text")] public string Text { get; set; } = "";

    [JsonIgnore]
    public string? OwnerShown => Owner switch
    {
        null or "" => null,
        "你" or "对方" or "未识别" => Strings.L(Owner),
        _ when Owner.StartsWith("说话人", StringComparison.Ordinal) && int.TryParse(Owner[3..].Trim(), out var n) => Strings.LF("说话人 %lld", n),
        _ => Owner,
    };

    [JsonIgnore]
    public string WithOwner => Text + (OwnerShown is { } o ? Strings.LF("待办的负责人 %@", o) : "");
}

public sealed class NoteTerm
{
    [JsonPropertyName("heard")] public List<string> Heard { get; set; } = [];
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("note")] public string Note { get; set; } = "";

    public static List<NoteTerm> Ordered(IEnumerable<NoteTerm> terms)
    {
        var list = terms.ToList();
        return [.. list.Where(t => t.Heard.Count > 0), .. list.Where(t => t.Heard.Count == 0)];
    }

    public static List<NoteTerm> KeepingOrder(IReadOnlyList<NoteTerm> old, IReadOnlyList<NoteTerm> next)
    {
        var rank = new Dictionary<string, int>();
        for (var i = 0; i < old.Count; i++) rank.TryAdd(old[i].Name, i);
        return [.. next.Select((t, i) => (t, i)).OrderBy(p => rank.TryGetValue(p.t.Name, out var r) ? r : old.Count + p.i).ThenBy(p => p.i).Select(p => p.t)];
    }
}
