namespace Cicada;

public static class TalkKey
{
    public const string Default = "rcontrol";

    public sealed record Key(string Name, int Vk, string Label, bool Modifier);

    public static readonly IReadOnlyList<Key> All =
    [
        new("rcontrol", 0xA3, "右 Ctrl", true),
        new("lcontrol", 0xA2, "左 Ctrl", true),
        new("rshift", 0xA1, "右 Shift", true),
        new("lshift", 0xA0, "左 Shift", true),
        new("capslock", 0x14, "Caps Lock", false),
        new("insert", 0x2D, "Insert", false),
        new("pause", 0x13, "Pause", false),
        new("scrolllock", 0x91, "Scroll Lock", false),
        new("apps", 0x5D, "菜单键", false),
        .. Enumerable.Range(1, 24).Select(n => new Key($"f{n}", 0x6F + n, $"F{n}", false)),
    ];

    public static Key Named(string? name) => All.FirstOrDefault(k => k.Name == name) ?? All[0];

    public static Key? FromVk(int vk) => All.FirstOrDefault(k => k.Vk == vk);

    public static (Key? Key, string? Refused) Choose(int vk) => vk switch
    {
        0x5B or 0x5C => (null, "Windows 键会打开开始菜单，换一个吧"),
        0x12 or 0xA4 or 0xA5 => (null, "Alt 松开时会打开窗口的菜单，换一个吧"),
        0x11 => (Named("rcontrol"), null),
        0x10 => (Named("rshift"), null),
        _ => FromVk(vk) is { } k ? (k, null) : (null, "打字时会用到这个键，换一个不常用的吧"),
    };

    public static string? Note(Key key) => key.Name switch
    {
        "lcontrol" => "只有单独按住才算，Ctrl C 这类快捷键不会开始说话",
        "lshift" or "rshift" => "只有单独按住才算，打字时的 Shift 不会开始说话",
        "capslock" => "按住说话时不会切换大小写",
        _ => null,
    };
}
