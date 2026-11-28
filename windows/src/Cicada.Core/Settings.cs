using System.Globalization;
using System.Text.Json.Serialization;

namespace Cicada;

public sealed class AppSettings
{
    [JsonPropertyName("target")] public string Target { get; set; } = "system";
    [JsonPropertyName("notesLanguage")] public string NotesLanguage { get; set; } = "system";
    [JsonPropertyName("model")] public string Model { get; set; } = LingClient.DefaultModel;
    [JsonPropertyName("aiProvider")] public string AiProvider { get; set; } = "ling";
    [JsonPropertyName("aiModels")] public Dictionary<string, string> AiModels { get; set; } = [];
    [JsonPropertyName("aiHearModels")] public Dictionary<string, string> AiHearModels { get; set; } = [];
    [JsonPropertyName("aiVoiceModels")] public Dictionary<string, string> AiVoiceModels { get; set; } = [];
    [JsonPropertyName("aiCustomBase")] public string AiCustomBase { get; set; } = "";
    [JsonPropertyName("aiCustomVoiceBase")] public string AiCustomVoiceBase { get; set; } = "";
    [JsonPropertyName("aiCustomVoice")] public string AiCustomVoice { get; set; } = "";
    [JsonPropertyName("aiCustomHearBase")] public string AiCustomHearBase { get; set; } = "";
    [JsonPropertyName("aiCustomOnly")] public bool AiCustomOnly { get; set; }
    [JsonPropertyName("aiCustomNotesOwn")] public bool AiCustomNotesOwn { get; set; }
    [JsonPropertyName("aiCustomNotesBase")] public string AiCustomNotesBase { get; set; } = "";
    [JsonIgnore] public bool GoogleOff => AiProvider == "custom" && AiCustomOnly;
    [JsonIgnore] public string ListenSourceValue { get; set; } = ListenSource.System;
    [JsonIgnore] public string Listens => ListenSource.Parse(ListenSourceValue);
    [JsonIgnore] public bool ListensToRoom => Listens == ListenSource.Room;
    [JsonIgnore] public bool HearsBoth => Listens == ListenSource.Both;
    [JsonPropertyName("view")] public string View { get; set; } = "notes";
    [JsonPropertyName("trayHintShown")] public bool TrayHintShown { get; set; }
    [JsonPropertyName("showInCapture")] public bool ShowInCapture { get; set; }
    [JsonPropertyName("onboarded")] public bool Onboarded { get; set; }
    [JsonPropertyName("heardSystemAudio")] public bool HeardSystemAudio { get; set; }
    [JsonPropertyName("sampleSeen")] public bool SampleSeen { get; set; }
    [JsonPropertyName("uiLanguage")] public string UiLanguage { get; set; } = "system";
    [JsonPropertyName("subtitleSize")] public int SubtitleSize { get; set; } = 24;
    [JsonPropertyName("recordAudio")] public bool RecordAudio { get; set; } = true;
    [JsonPropertyName("exportOn")] public bool ExportOn { get; set; }
    [JsonPropertyName("exportFolder")] public string ExportFolder { get; set; } = "";
    [JsonPropertyName("speakerVoices")] public bool SpeakerVoices { get; set; } = true;
    [JsonPropertyName("fixMisheard")] public bool FixMisheard { get; set; } = true;
    [JsonPropertyName("askNames")] public bool AskNames { get; set; } = true;
    [JsonPropertyName("speak")] public bool Speak { get; set; }
    [JsonPropertyName("talkKey")] public string TalkKey { get; set; } = Cicada.TalkKey.Default;
    [JsonPropertyName("speakFrom")] public string SpeakFrom { get; set; } = "system";
    [JsonPropertyName("speakTo")] public string SpeakTo { get; set; } = "room";
    [JsonPropertyName("speakVoices")] public Dictionary<string, string> SpeakVoices { get; set; } = [];
    [JsonPropertyName("toldStillListening")] public bool ToldStillListening { get; set; }
    [JsonPropertyName("endWithApp")] public bool EndWithApp { get; set; } = true;
    [JsonPropertyName("silenceEnd")] public string SilenceEnd { get; set; } = "prompt";
    [JsonPropertyName("silenceMinutes")] public double SilenceMinutes { get; set; } = 10;
    [JsonPropertyName("updateLastChecked")] public DateTimeOffset? UpdateLastChecked { get; set; }
    [JsonPropertyName("updateNotified")] public string? UpdateNotified { get; set; }
    [JsonPropertyName("cableSpeakerNotified")] public bool CableSpeakerNotified { get; set; }

    [JsonIgnore] public string TargetCode => Target == "system" ? Languages.FromSystem(CultureInfo.CurrentUICulture.Name) : Target;
    public AIConfig AIConfig() => Cicada.AIConfig.From(this);
    [JsonIgnore] public string NotesCode => NotesLanguage == "system" ? TargetCode : NotesLanguage;

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(Paths.Settings) && Json.Read<AppSettings>(File.ReadAllText(Paths.Settings)) is { } s) return s;
        }
        catch (Exception e) { Log.Debug($"settings: unreadable, defaults used ({e.GetType().Name})"); }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Paths.Root);
            File.WriteAllText(Paths.Settings, Json.Write(this));
        }
        catch (Exception e) { Log.Debug($"settings: save failed {e.GetType().Name}"); }
    }
}
