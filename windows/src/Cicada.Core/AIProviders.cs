using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Cicada;

public sealed record AIModel(string Id, string Note = "");

public sealed record CloudVoice(string Id, string Gender);

public sealed record AIProvider(string Id, string Name, string? Base, string? Site,
    AIModel[] TextModels, AIModel[] HearModels, AIModel[] VoiceModels, CloudVoice[] Voices, bool Clones = false, double Spacing = 0.1)
{
    public bool HasVoices => VoiceModels.Length > 0;

    static readonly CloudVoice[] Gemini = [new("Kore", "女"), new("Aoede", "女"), new("Charon", "男"), new("Puck", "男")];

    public static readonly AIProvider Ling = new("ling", "Ling", "https://api.ant-ling.com/v1/", "https://chat.ant-ling.com/platform/api",
        [new("Ling-3.1-flash", "更准"), new("Ling-3.0-flash", "更快、更省")], [new("Ming-3.0-audio-flash")], [new("Ming-3.0-tts-0.5B")], [],
        Clones: true, Spacing: 0.6);

    public static readonly AIProvider OpenRouter = new("openrouter", "OpenRouter", "https://openrouter.ai/api/v1/", "https://openrouter.ai/settings/keys",
        [new("inclusionai/ling-3.1-flash", "和 Ling 同款"), new("qwen/qwen3.8-flash", "中文好")],
        [new("qwen/qwen3.8-omni-flash", "没人说话时不乱写"), new("google/gemini-3.1-flash-lite", "最快，偶尔把杂音写成字")],
        [new("google/gemini-3.8-flash-tts", "效果和价格最均衡"), new("google/gemini-3.8-flash-lite-tts", "更省")], Gemini);

    public static readonly AIProvider ZenMux = new("zenmux", "ZenMux", "https://zenmux.ai/api/v1/", "https://zenmux.ai/settings/keys",
        [new("inclusionai/ling-3.0-flash", "和 Ling 同款"), new("qwen/qwen3.8-flash", "中文好")],
        [new("qwen/qwen3.8-omni-flash", "没人说话时不乱写"), new("bytedance/doubao-seed-2.0-mini", "更快"), new("google/gemini-3.1-flash-lite", "最快，偶尔把杂音写成字")],
        [new("google/gemini-3.8-flash-tts", "效果和价格最均衡"), new("google/gemini-3.8-flash-lite-tts", "更省")], Gemini);

    public static readonly AIProvider Custom = new("custom", "其他（兼容 OpenAI）", null, null, [], [], [], []);

    public static readonly AIProvider[] All = [Ling, OpenRouter, ZenMux, Custom];

    public static AIProvider Named(string? id) => All.FirstOrDefault(p => p.Id == id) ?? Ling;

    public static bool IsLocal(string hostOrUrl) => Host(hostOrUrl) is "localhost" or "127.0.0.1" or "::1";

    public static bool IsNearby(string hostOrUrl)
    {
        var h = Host(hostOrUrl).ToLowerInvariant();
        if (IsLocal(h) || h.EndsWith(".local")) return true;
        var parts = h.Split('.');
        if (parts.Length == 4 && parts.All(x => x.Length is > 0 and <= 3 && x.All(char.IsAsciiDigit) && int.Parse(x) <= 255))
        {
            int a = int.Parse(parts[0]), b = int.Parse(parts[1]);
            return a == 10 || a == 192 && b == 168 || a == 169 && b == 254 || a == 172 && b is >= 16 and <= 31 || a == 100 && b is >= 64 and <= 127;
        }
        if (h.Contains(':')) return h.StartsWith("fc") || h.StartsWith("fd") || h.StartsWith("fe80");
        return false;
    }

    static string Host(string hostOrUrl)
    {
        var s = hostOrUrl.Trim();
        var u = s.Contains("://") ? s : "http://" + s;
        return (Uri.TryCreate(u, UriKind.Absolute, out var uri) ? uri.Host : s).Trim('[', ']');
    }

    public static string? CustomBase(string? raw)
    {
        var s = (raw ?? "").Trim();
        if (s.Length == 0) return null;
        if (!s.Contains("://")) s = (IsNearby(s) ? "http://" : "https://") + s;
        if (!s.EndsWith('/')) s += "/";
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || u.Host.Length == 0) return null;
        if (u.Scheme == "https") return s;
        return u.Scheme == "http" && IsNearby(u.Host) ? s : null;
    }

    static readonly Regex NotChat = new(@"(embed|whisper|tts|asr|transcribe|dall-e|image|moderation|realtime|sora|search|video|seedance|wan\d)");

    public static List<string> Catalog(string json, IEnumerable<string> recommended, bool hears)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); } catch (System.Text.Json.JsonException) { root = null; }
        var ids = new List<string>();
        if (root is JsonObject o && o["data"] is JsonArray data)
            foreach (var m in data.OfType<JsonObject>())
            {
                if (Str(m["id"]) is not { Length: > 0 } id || id.EndsWith(":batch")) continue;
                var arch = m["architecture"] as JsonObject;
                var ins = Strs(m["input_modalities"] ?? arch?["input_modalities"]);
                var outs = Strs(m["output_modalities"] ?? arch?["output_modalities"]);
                if (outs.Count > 0 && !outs.Contains("text")) continue;
                if (ins is ["audio"]) continue;
                if (hears && !ins.Contains("audio")) continue;
                if (outs.Count == 0 && NotChat.IsMatch(id)) continue;
                ids.Add(id);
            }
        var rec = recommended.ToList();
        return [.. rec, .. ids.Where(i => !rec.Contains(i)).Distinct().Order(StringComparer.Ordinal)];
    }

    static string? Str(JsonNode? n) => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    static List<string> Strs(JsonNode? n) => n is JsonArray a ? a.Select(Str).OfType<string>().ToList() : [];
}

public sealed record AIConfig(AIProvider Provider, string? Base, string TextModel, string HearModel,
    string? VoiceModel = null, string? VoiceBase = null, string? CustomVoice = null, string? HearBase = null,
    string? NotesModel = null, string? NotesBase = null, bool NotesOwnService = false, bool NotesBadAddress = false)
{
    public bool NotesApart => Provider.Id == "custom" && (NotesModel is not null || NotesBase is not null || NotesOwnService);

    public AIConfig ForNotes => !NotesApart ? this : this with { TextModel = NotesModel ?? TextModel, Base = NotesBase ?? Base };

    public bool IsLing => Provider.Id == "ling";
    public bool HasVoices => VoiceModel is not null && VoiceBase is not null;
    public string Name => Provider.Id == "custom" ? Strings.L(Provider.Name) : Provider.Name;

    public IReadOnlyList<CloudVoice> Voices =>
        !HasVoices || IsLing ? [] : Provider.Id == "custom" ? (CustomVoice is { } v ? [new CloudVoice(v, "")] : []) : Provider.Voices;

    public static AIConfig Default => From(new AppSettings());

    public bool HearElsewhere => HearBase != Base;

    public void Shape(JsonObject body, int maxTokens, bool templateKwargs = true)
    {
        body["max_tokens"] = maxTokens;
        body["temperature"] = 0.2;
        if (IsLing) body["thinking"] = new JsonObject { ["type"] = "disabled" };
        else if (Provider.Id is "openrouter" or "zenmux") body["reasoning"] = new JsonObject { ["enabled"] = false };
        else if (Provider.Id == "custom" && templateKwargs) body["chat_template_kwargs"] = new JsonObject { ["enable_thinking"] = false };
    }

    public static bool Thought(JsonNode? root)
    {
        var message = root?["choices"]?[0]?["message"];
        foreach (var k in new[] { "reasoning_content", "reasoning" })
            if (message?[k] is JsonValue v && v.TryGetValue<string>(out var r) && r.Trim().Length > 0) return true;
        if (root?["usage"]?["completion_tokens_details"]?["reasoning_tokens"] is JsonValue n && n.TryGetValue<int>(out var tokens) && tokens > 0) return true;
        return message?["content"] is JsonValue c && c.TryGetValue<string>(out var content) && content.Contains("<think>");
    }

    public JsonObject AudioPart(byte[] wav, string model)
    {
        var b64 = Convert.ToBase64String(wav);
        if (IsLing) return new JsonObject { ["type"] = "audio_url", ["audio_url"] = new JsonObject { ["url"] = "data:audio/wav;base64," + b64 } };
        if (model.Split('/')[^1].StartsWith("qwen")) b64 = "data:audio/wav;base64," + b64;
        return new JsonObject { ["type"] = "input_audio", ["input_audio"] = new JsonObject { ["data"] = b64, ["format"] = "wav" } };
    }

    public static AIConfig From(AppSettings s)
    {
        var p = AIProvider.Named(s.AiProvider);
        if (p.Id == "ling")
        {
            var text = p.TextModels.Any(m => m.Id == s.Model) ? s.Model : p.TextModels[0].Id;
            return new(p, p.Base, text, p.HearModels[0].Id, p.VoiceModels[0].Id, p.Base, HearBase: p.Base);
        }
        string Pick(Dictionary<string, string> table) => table.TryGetValue(p.Id, out var v) ? v.Trim() : "";
        if (p.Id == "custom")
        {
            var b = AIProvider.CustomBase(s.AiCustomBase);
            var voice = Pick(s.AiVoiceModels);
            var voiceBase = s.AiCustomVoiceBase.Trim().Length > 0 ? AIProvider.CustomBase(s.AiCustomVoiceBase) : b;
            var name = s.AiCustomVoice.Trim();
            var hearBase = s.AiCustomHearBase.Trim().Length > 0 ? AIProvider.CustomBase(s.AiCustomHearBase) : b;
            var textModel = Pick(s.AiModels);
            var notesModel = s.AiModels.TryGetValue("custom.notes", out var nm) ? nm.Trim() : "";
            var notesAddress = s.AiCustomNotesOwn ? s.AiCustomNotesBase.Trim() : "";
            var notesBase = notesAddress.Length == 0 ? null : AIProvider.CustomBase(notesAddress);
            return new(p, b, textModel, Pick(s.AiHearModels), voice.Length > 0 ? voice : null,
                voice.Length > 0 ? voiceBase : null, name.Length > 0 ? name : null, hearBase,
                NotesModel: notesModel.Length == 0 || notesModel == textModel ? null : notesModel,
                NotesBase: notesBase == b ? null : notesBase, NotesOwnService: s.AiCustomNotesOwn,
                NotesBadAddress: notesAddress.Length > 0 && notesBase is null);
        }
        static string Or(string v, AIModel[] rec) => v.Length > 0 ? v : rec[0].Id;
        return new(p, p.Base, Or(Pick(s.AiModels), p.TextModels), Or(Pick(s.AiHearModels), p.HearModels), Or(Pick(s.AiVoiceModels), p.VoiceModels), p.Base, HearBase: p.Base);
    }
}
