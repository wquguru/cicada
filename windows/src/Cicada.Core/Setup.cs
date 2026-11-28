namespace Cicada;

public static class SetupPlan
{
    public enum Step
    {
        Run,
        Install,
        Upgrade,
        Open,
    }

    public static Step Decide(bool dev, string running, string installed, string? installedVersion, string version)
    {
        if (dev || Same(running, installed)) return Step.Run;
        if (installedVersion is null) return Step.Install;
        return UpdateChecker.IsNewer(version, installedVersion) ? Step.Upgrade : Step.Open;
    }

    public static bool Same(string a, string b)
    {
        try { return string.Equals(Path.GetFullPath(a).TrimEnd('\\', '/'), Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    public static string ShortcutName(string language) => language == "zh-Hans" ? "知了" : "Cicada";
    public static readonly string[] ShortcutNames = ["知了", "Cicada"];
    public const string DisplayName = "知了 Cicada";
}
