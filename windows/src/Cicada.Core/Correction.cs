using System.Globalization;
using System.Text.Json.Nodes;

namespace Cicada;

public static class Correction
{
    public sealed record Edit(string From, string To, double Confidence);

    public enum Verdict { Apply, Ask, Drop }

    public const double ApplyAt = 0.6, SpellingAt = 0.8, AskAt = 0.8;

    static string[] Chars(string s)
    {
        var e = StringInfo.GetTextElementEnumerator(s);
        var out_ = new List<string>();
        while (e.MoveNext()) out_.Add(e.GetTextElement());
        return [.. out_];
    }

    public static int Length(string s) => new StringInfo(s).LengthInTextElements;

    static bool Word(string c) => c.Length == 1 && char.IsAsciiLetterOrDigit(c[0]);

    public static (string From, string To) Label(LineFix f)
    {
        var c = Core(f.From, f.To);
        return c.From.Length == 0 || c.To.Length == 0 ? (f.From, f.To) : c;
    }

    public static (string From, string To) Core(string from, string to)
    {
        var a = Chars(from); var b = Chars(to);
        int min = Math.Min(a.Length, b.Length);
        int i = 0;
        while (i < min && a[i] == b[i]) i++;
        int j = 0;
        while (j < min - i && a[a.Length - 1 - j] == b[b.Length - 1 - j]) j++;
        bool FromEdge(int k) => (k < a.Length && Word(a[k])) || (k < b.Length && Word(b[k]));
        if (FromEdge(i)) while (i > 0 && Word(a[i - 1])) i--;
        if ((a.Length - j - 1 >= 0 && Word(a[a.Length - j - 1])) || (b.Length - j - 1 >= 0 && Word(b[b.Length - j - 1])))
            while (j > 0 && Word(a[a.Length - j])) j--;
        while (a.Length - j - i < 2 || b.Length - j - i < 2)
        {
            if (j > 0 && !Word(a[a.Length - j])) j--;
            else if (i > 0 && !Word(a[i - 1])) i--;
            else break;
        }
        return (string.Concat(a[i..(a.Length - j)]), string.Concat(b[i..(b.Length - j)]));
    }

    public static Verdict Decide(Edit e, Func<string, string, bool> known, Func<string, string, bool> rejected)
    {
        var c = Core(e.From, e.To);
        if (c.From.Length == 0 || c.To.Length == 0 || c.From.ToLowerInvariant() == c.To.ToLowerInvariant()
            || rejected(e.From, e.To) || rejected(c.From, c.To)) return Verdict.Drop;
        if (known(e.From, e.To) || known(c.From, c.To)) return Verdict.Apply;
        if (e.Confidence < ApplyAt) return Verdict.Drop;
        bool latinFrom = c.From.Any(char.IsAsciiLetter), latinTo = c.To.Any(char.IsAsciiLetter);
        if (!latinFrom && !latinTo && Han(c.From) && Han(c.To) && SoundsAlike(c.From, c.To)) return Verdict.Apply;
        if (latinFrom && latinTo && c.From.All(char.IsAscii) && c.To.All(char.IsAscii) && e.Confidence >= SpellingAt
            && Distance(c.From.ToLowerInvariant(), c.To.ToLowerInvariant()) <= 2) return Verdict.Apply;
        if (latinTo && e.Confidence >= AskAt && NameShaped(c.To)) return Verdict.Ask;
        return Verdict.Drop;
    }

    public static bool NameShaped(string s) => s.Any(c => char.IsAsciiLetterUpper(c) || char.IsAsciiDigit(c));

    public static bool Translation(string heard, string word) =>
        Han(heard) && word.Any(char.IsAsciiLetter) && word.All(char.IsAscii) && !NameShaped(word);

    static readonly Lazy<Dictionary<char, string>> Table = new(() =>
    {
        var d = new Dictionary<char, string>();
        using var stream = typeof(Correction).Assembly.GetManifestResourceStream("pinyin.tsv");
        if (stream is null) return d;
        using var reader = new StreamReader(stream);
        while (reader.ReadLine() is { } line)
            if (line.Length > 2 && line[1] == '\t') d[line[0]] = line[2..];
        return d;
    });

    public static string[] Pinyin(string s) =>
        Chars(s).Select(ch => ch.Length == 1 && Table.Value.TryGetValue(ch[0], out var p) ? p : ch.ToLowerInvariant().Trim()).ToArray();

    static readonly string[] Initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q",
                                         "x", "r", "z", "c", "s", "y", "w"];

    static (string, string) Split(string syllable)
    {
        foreach (var i in Initials) if (syllable.StartsWith(i, StringComparison.Ordinal)) return (i, syllable[i.Length..]);
        return ("", syllable);
    }

    public static bool SoundsAlike(string a, string b)
    {
        var x = Pinyin(a); var y = Pinyin(b);
        if (x.Length != y.Length || x.Length == 0) return false;
        double score = 0;
        for (int k = 0; k < x.Length; k++)
        {
            if (x[k] == y[k]) { score += 1; continue; }
            var (i1, f1) = Split(x[k]); var (i2, f2) = Split(y[k]);
            if (i1 == i2 || f1 == f2 || f1.Replace("ng", "n") == f2.Replace("ng", "n")) score += 0.5;
        }
        return score / x.Length >= 0.75;
    }

    public static bool Han(string s) => s.EnumerateRunes().All(r => r.Value is >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF
        or >= 0xF900 and <= 0xFAFF or >= 0x20000 and <= 0x3134F or 0x3006 or 0x3007 or >= 0x3021 and <= 0x3029);

    public static int Distance(string a, string b)
    {
        var row = Enumerable.Range(0, b.Length + 1).ToArray();
        for (int i = 0; i < a.Length; i++)
        {
            int prev = row[0];
            row[0] = i + 1;
            for (int j = 0; j < b.Length; j++)
            {
                int cur = row[j + 1];
                row[j + 1] = Math.Min(Math.Min(row[j + 1] + 1, row[j] + 1), prev + (a[i] == b[j] ? 0 : 1));
                prev = cur;
            }
        }
        return row[b.Length];
    }

    public static int WordIn(string s, string text)
    {
        if (s.Length == 0) return -1;
        static bool Latin(char c) => char.IsAsciiLetterOrDigit(c);
        for (int from = 0; from < text.Length;)
        {
            int at = text.IndexOf(s, from, StringComparison.Ordinal);
            if (at < 0) return -1;
            int end = at + s.Length;
            if (!(Latin(s[0]) && at > 0 && Latin(text[at - 1])) && !(Latin(s[^1]) && end < text.Length && Latin(text[end]))) return at;
            from = at + 1;
        }
        return -1;
    }

    public static (string Text, List<(int Start, int Length)> Marks) Apply(IReadOnlyList<LineFix> fixes, string src)
    {
        var text = src;
        var spans = new List<(string Word, int At)>();
        foreach (var f in fixes.Where(f => f.User != true).Concat(fixes.Where(f => f.User == true)))
        {
            if (!f.Applied || f.From.Length == 0) continue;
            var at = WordIn(f.From, text);
            if (at < 0) at = text.IndexOf(f.From, StringComparison.Ordinal);
            if (at < 0) continue;
            var delta = f.To.Length - f.From.Length;
            for (int k = 0; k < spans.Count; k++) if (spans[k].At > at) spans[k] = (spans[k].Word, spans[k].At + delta);
            text = text[..at] + f.To + text[(at + f.From.Length)..];
            spans.Add((f.To, at));
        }
        var marks = spans.Where(s => s.At + s.Word.Length <= text.Length).Select(s => (s.At, s.Word.Length)).OrderBy(m => m.Item1).ToList();
        return (text, marks);
    }

    public static (string Translation, List<Edit> Edits)? Parse(string reply, string subtitle)
    {
        int open = reply.IndexOf('{'), close = reply.LastIndexOf('}');
        if (open < 0 || close <= open) return null;
        JsonObject? o;
        try { o = JsonNode.Parse(reply[open..(close + 1)]) as JsonObject; } catch { return null; }
        if (o?["translation"] is not JsonValue tv || !tv.TryGetValue<string>(out var translation)) return null;
        var edits = new List<Edit>();
        if (o["fixes"] is JsonArray raw)
            foreach (var f in raw.OfType<JsonObject>())
            {
                if (f["from"] is not JsonValue fv || !fv.TryGetValue<string>(out var from) || f["to"] is not JsonValue tov || !tov.TryGetValue<string>(out var to)) continue;
                if (from.Length == 0 || from == to || !subtitle.Contains(from, StringComparison.Ordinal)) continue;
                double c = f["confidence"] is JsonValue cv && cv.TryGetValue<double>(out var d) ? d : 0;
                edits.Add(new Edit(from, to, c));
            }
        return (translation.Trim(), edits);
    }

    public static List<LineFix> Merge(IReadOnlyList<LineFix> old, IReadOnlyList<LineFix> fresh)
    {
        var kept = old.Where(f => f.Off == true || f.User == true).ToList();
        var added = fresh.Where(n =>
        {
            var c = Core(n.From, n.To);
            return !kept.Any(k => k.From == n.From || Core(k.From, k.To).From == c.From);
        });
        return [.. kept, .. added];
    }

    public static (LineFix Fix, string Heard, bool Swap)? UserEdit(string shown, string edited, string src, IReadOnlyList<LineFix> fixes)
    {
        var now = edited.Trim();
        if (now.Length == 0 || now == shown) return null;
        static string[] Chars(string x)
        {
            var e = StringInfo.GetTextElementEnumerator(x);
            var o = new List<string>();
            while (e.MoveNext()) o.Add(e.GetTextElement());
            return [.. o];
        }
        string[] a = Chars(shown), b = Chars(now);
        int p = 0;
        while (p < Math.Min(a.Length, b.Length) && a[p] == b[p]) p++;
        int q = 0;
        while (q < Math.Min(a.Length, b.Length) - p && a[a.Length - 1 - q] == b[b.Length - 1 - q]) q++;
        bool swap = a.Length - p - q > 0 && b.Length - p - q > 0;
        static bool Latin(string c) => c.Length == 1 && c[0] < 128 && char.IsLetterOrDigit(c[0]);
        var tokens = new List<(int Lo, int Hi)>();
        for (int k = 0; k < a.Length;)
        {
            int e = k + 1;
            if (Latin(a[k])) while (e < a.Length && Latin(a[e])) e++;
            tokens.Add((k, e));
            k = e;
        }
        int start = p, end = a.Length - q;
        foreach (var t in tokens) if (t.Lo <= start && start < t.Hi) { start = t.Lo; break; }
        if (end > start) foreach (var t in tokens) if (t.Lo <= end - 1 && end - 1 < t.Hi) { end = t.Hi; break; }
        string Span() => string.Concat(a[start..end]);
        int Count(string x)
        {
            if (x.Length == 0) return 0;
            int n = 0;
            for (int at = shown.IndexOf(x, StringComparison.Ordinal); at >= 0; at = shown.IndexOf(x, at + x.Length, StringComparison.Ordinal)) n++;
            return n;
        }
        string Replacement() => string.Concat(b[start..(b.Length - (a.Length - end))]);
        while (!Span().Any(char.IsLetterOrDigit) || Count(Span()) != 1 || Replacement().Length == 0)
        {
            int before = tokens.FindLastIndex(t => t.Hi <= start), after = tokens.FindIndex(t => t.Lo >= end);
            if (before >= 0) start = tokens[before].Lo;
            else if (after >= 0) end = tokens[after].Hi;
            else break;
        }
        var from = Span();
        var to = Replacement();
        if (from.Length == 0 || from == to) return null;
        var heard = from;
        if (!src.Contains(from, StringComparison.Ordinal) && fixes.FirstOrDefault(f => f.Applied && from.Contains(f.To, StringComparison.Ordinal)) is { } earlier)
            heard = Core(earlier.From, earlier.To).From;
        return (new LineFix(from, to, user: true), heard, swap);
    }
}
