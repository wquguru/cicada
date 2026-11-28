using System.Text;

namespace Cicada.App;

static class Bundled
{
    static readonly System.Reflection.Assembly Self = typeof(Bundled).Assembly;
    static readonly Dictionary<string, string> Names = Self.GetManifestResourceNames().ToDictionary(n => n.Replace('\\', '/'), n => n);

    public static string? Strings(string path)
    {
        if (!Names.TryGetValue("strings/" + path, out var name) || Self.GetManifestResourceStream(name) is not { } s) return null;
        using var reader = new StreamReader(s, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    public static string? Sample()
    {
        var path = Path.Combine(Path.GetTempPath(), $"cicada-sample-{Controller.Version}.wav");
        try
        {
            if (File.Exists(path)) return path;
            using var s = Self.GetManifestResourceStream("sample.wav");
            if (s is null) return null;
            var part = path + ".part";
            using (var f = File.Create(part)) s.CopyTo(f);
            File.Move(part, path, overwrite: true);
            return path;
        }
        catch (Exception e) { Log.Debug($"sample: unavailable {e.GetType().Name}"); return null; }
    }
}
