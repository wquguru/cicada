using System.Runtime.InteropServices;
using System.Windows.Interop;
using Microsoft.Win32;

namespace Cicada.App;

sealed class Hotkey : IDisposable
{
    public const string Label = "Ctrl+Alt+L";
    const int Id = 0xC1CA, WmHotkey = 0x0312;
    const uint ModAlt = 0x1, ModControl = 0x2, ModNoRepeat = 0x4000, VkL = 0x4C;
    readonly HwndSource source;
    readonly Action pressed;
    public bool Registered { get; }

    public Hotkey(Action pressed)
    {
        this.pressed = pressed;
        source = new HwndSource(new HwndSourceParameters("CicadaHotkey") { ParentWindow = new IntPtr(-3), Width = 0, Height = 0 });
        source.AddHook(Hook);
        Registered = RegisterHotKey(source.Handle, Id, ModControl | ModAlt | ModNoRepeat, VkL);
        Log.Debug($"hotkey: {(Registered ? "registered" : "taken")} {Label}");
    }

    IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WmHotkey && wParam.ToInt32() == Id) { handled = true; pressed(); }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (Registered) UnregisterHotKey(source.Handle, Id);
        source.Dispose();
    }

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}

static class AutoStart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    static string Name => Paths.Dev ? "Cicada Dev" : "Cicada";
    static string Command(string exe) => $"\"{exe}\" --background" + (Paths.Dev ? " --dev" : "");

    public static void Refresh()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            var exe = Environment.ProcessPath ?? "";
            if (k?.GetValue(Name) is string v && v.StartsWith($"\"{exe}\"", StringComparison.OrdinalIgnoreCase) && v != Command(exe)) { k.SetValue(Name, Command(exe)); Log.Debug("autostart: command updated"); }
        }
        catch (Exception e) { Log.Debug($"autostart: refresh failed {e.GetType().Name}"); }
    }

    public static bool Enabled
    {
        get
        {
            try { using var k = Registry.CurrentUser.OpenSubKey(RunKey); return k?.GetValue(Name) is string; }
            catch { return false; }
        }
        set => Set(Environment.ProcessPath ?? "", value);
    }

    public static void Set(string exe, bool on)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) k.SetValue(Name, Command(exe)); else k.DeleteValue(Name, throwOnMissingValue: false);
            Log.Debug($"autostart: {(on ? "on" : "off")}");
        }
        catch (Exception e) { Log.Debug($"autostart: failed {e.GetType().Name}"); }
    }
}

static class AudioDevice
{
    public static string? DefaultName() => Endpoints.Default(Endpoints.Flow.Render)?.Name;
}

static class MicReaders
{
    const string Root = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    public static Dictionary<string, string> Calls()
    {
        var entries = new List<(string, long)>();
        try
        {
            using var root = Registry.CurrentUser.OpenSubKey(Root);
            if (root is null) return [];
            void Read(RegistryKey parent)
            {
                foreach (var name in parent.GetSubKeyNames())
                {
                    if (name == "NonPackaged") continue;
                    using var k = parent.OpenSubKey(name);
                    if (k?.GetValue("LastUsedTimeStop") is long stop && k.GetValue("LastUsedTimeStart") is long start && start > 0)
                        entries.Add((name, stop));
                }
            }
            Read(root);
            using (var desktop = root.OpenSubKey("NonPackaged")) if (desktop is not null) Read(desktop);
        }
        catch (Exception e) { Log.Debug($"mic users: unreadable ({e.GetType().Name})"); }
        return MicUse.Calls(entries);
    }
}

static class WinProxy
{
    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";

    public static bool SystemOn()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return k?.GetValue("ProxyEnable") is int on && on == 1 || k?.GetValue("AutoConfigURL") is string { Length: > 0 };
        }
        catch (Exception e) { Log.Debug($"proxy: unreadable ({e.GetType().Name})"); return false; }
    }

    public static string Snapshot()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(Key);
            return $"{k?.GetValue("ProxyEnable")}|{k?.GetValue("ProxyServer")}|{k?.GetValue("AutoConfigURL")}|{k?.GetValue("ProxyOverride")}";
        }
        catch { return ""; }
    }
}
