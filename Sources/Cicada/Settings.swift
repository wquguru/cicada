import AppKit
import Foundation

enum SourceMode: Equatable {
    case auto
    case fixed(Lang)
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var sourceMode: SourceMode {
        didSet { save() }
    }
    @Published var target: String {
        didSet { save() }
    }
    @Published var subtitles: String {
        didSet { save() }
    }
    @Published var notesLanguage: String {
        didSet { save() }
    }
    @Published var speakEnabled: Bool {
        didSet { save() }
    }
    @Published var speakConfirmed: Bool {
        didSet { save() }
    }
    @Published var speakHandsFree: Bool {
        didSet { save() }
    }
    @Published var speakFrom: String {
        didSet { save() }
    }
    @Published var speakTo: String {
        didSet { save() }
    }
    @Published var speakOutput: String {
        didSet { save() }
    }
    @Published var autoSystemMic: Bool {
        didSet { save() }
    }
    @Published var speakMic: String {
        didSet { save() }
    }
    @Published var savedSystemInput: String {
        didSet { save() }
    }
    @Published var recordAudio: Bool {
        didSet { save() }
    }
    @Published var exportOn: Bool {
        didSet { save() }
    }
    @Published var exportFolder: String {
        didSet { save() }
    }
    @Published var importLanguage: String {
        didSet { save() }
    }
    @Published var importNotes: Bool {
        didSet { save() }
    }
    @Published var overlayAuto: Bool {
        didSet { save() }
    }
    @Published var overlayHideAfter: Double {
        didSet { save() }
    }

    @Published var talkKey: Shortcut {
        didSet { save() }
    }
    @Published var toggleKey: Shortcut {
        didSet { save() }
    }

    @Published var displayMode: String {
        didSet { save() }
    }
    @Published var speakVoices: [String: String] {
        didSet { save() }
    }
    @Published var aiModel: String {
        didSet { save() }
    }
    @Published var aiProvider: String {
        didSet { save() }
    }
    @Published var aiModels: [String: String] {
        didSet { save() }
    }
    @Published var aiVoiceModels: [String: String] {
        didSet { save() }
    }
    @Published var aiCustomBase: String {
        didSet { save() }
    }
    @Published var aiCustomVoiceBase: String {
        didSet { save() }
    }
    @Published var aiCustomVoice: String {
        didSet { save() }
    }
    @Published var aiCustomHearModel: String {
        didSet { save() }
    }
    @Published var aiCustomHearBase: String {
        didSet { save() }
    }
    @Published var aiCustomRecognize: Bool {
        didSet { save() }
    }
    @Published var aiCustomNotesOwn: Bool {
        didSet { save() }
    }
    @Published var aiCustomNotesBase: String {
        didSet { save() }
    }
    @Published var aiCustomOnly: Bool {
        didSet { save() }
    }

    var provider: AIProvider { AIProvider.named(aiProvider) }

    var aiConfig: AIConfig {
        let p = provider
        switch p.id {
        case .ling:
            return AIConfig(provider: p, base: p.base, textModel: aiModel, voiceModel: p.voiceModels.first?.id, voiceBase: p.base)
        case .custom:
            let base = AIProvider.customBase(aiCustomBase)
            let voice = (aiVoiceModels["custom"] ?? "").trimmingCharacters(in: .whitespaces)
            let voiceBase = aiCustomVoiceBase.isEmpty ? base : AIProvider.customBase(aiCustomVoiceBase)
            let name = aiCustomVoice.trimmingCharacters(in: .whitespaces)
            let hear = aiCustomHearModel.trimmingCharacters(in: .whitespaces)
            let hearBase = aiCustomHearBase.isEmpty ? base : AIProvider.customBase(aiCustomHearBase)
            let recognizes = aiCustomRecognize && !hear.isEmpty
            let textModel = aiModels["custom"] ?? ""
            let notesModel = (aiModels["custom.notes"] ?? "").trimmingCharacters(in: .whitespaces)
            let notesAddress = aiCustomNotesOwn ? aiCustomNotesBase.trimmingCharacters(in: .whitespaces) : ""
            let notesBase = notesAddress.isEmpty ? nil : AIProvider.customBase(notesAddress)
            return AIConfig(provider: p, base: base, textModel: textModel, voiceModel: voice.isEmpty ? nil : voice,
                            voiceBase: voiceBase, customVoice: name.isEmpty ? nil : name,
                            hearModel: recognizes ? hear : nil, hearBase: recognizes ? hearBase : nil,
                            notesModel: notesModel.isEmpty || notesModel == textModel ? nil : notesModel,
                            notesBase: notesBase == base ? nil : notesBase, notesOwnService: aiCustomNotesOwn,
                            notesBadAddress: !notesAddress.isEmpty && notesBase == nil)
        default:
            return AIConfig(provider: p, base: p.base, textModel: aiModels[p.id.rawValue] ?? p.textModels.first?.id ?? "",
                            voiceModel: p.hasVoices ? aiVoiceModels[p.id.rawValue] ?? p.voiceModels.first?.id : nil, voiceBase: p.base)
        }
    }

    var textModel: String { aiConfig.textModel }

    @Published var showInDock: Bool {
        didSet { save() }
    }

    @Published var endWithApp: Bool {
        didSet { save() }
    }
    @Published var silenceEnd: String {
        didSet { save() }
    }
    @Published var silenceMinutes: Double {
        didSet { save() }
    }

    @Published var notesCapturable: Bool {
        didSet { save() }
    }

    @Published var speakerVoices: Bool {
        didSet { save() }
    }

    @Published var speakerEveryLine: Bool {
        didSet { save() }
    }

    @Published var speakerMemory: Bool {
        didSet { save() }
    }

    @Published var fixMisheard: Bool {
        didSet { save() }
    }

    @Published var askNames: Bool {
        didSet { save() }
    }

    @Published var listenSource: String {
        didSet { save() }
    }
    @Published var autoMicOnStart: Bool {
        didSet { save() }
    }
    @Published var roomMicUID: String {
        didSet { save() }
    }
    var listensToRoom: Bool { listenSource == "room" }
    var hearsRoom: Bool { listenSource != "system" }
    var hearsBoth: Bool { listenSource == "both" }

    @Published var diagnostics: Bool {
        didSet { save() }
    }

    var debug: Bool { defaults.bool(forKey: "debug") }

    init() {
        if let s = defaults.string(forKey: "sourceMode"), s != "auto",
           let lang = sourceLanguages.first(where: { $0.locale == s }) {
            sourceMode = .fixed(lang)
        } else {
            sourceMode = .auto
        }
        target = defaults.string(forKey: "target") ?? "system"
        subtitles = defaults.string(forKey: "subtitles") ?? "both"
        notesLanguage = defaults.string(forKey: "notesLanguage") ?? "mine"
        speakEnabled = defaults.bool(forKey: "speakEnabled")
        speakConfirmed = defaults.object(forKey: "speakConfirmed") as? Bool ?? defaults.bool(forKey: "speakEnabled")
        speakFrom = defaults.string(forKey: "speakFrom")
            ?? speakLocale(forLanguage: Cicada.myLanguage(systemLanguages: Locale.preferredLanguages))
        speakHandsFree = defaults.bool(forKey: "speakHandsFree")
        speakTo = defaults.string(forKey: "speakTo") ?? "room"
        speakOutput = defaults.string(forKey: "speakOutput") ?? ""
        autoSystemMic = defaults.object(forKey: "autoSystemMic") as? Bool ?? true
        speakMic = defaults.string(forKey: "speakMic") ?? ""
        savedSystemInput = defaults.string(forKey: "savedSystemInput") ?? ""
        recordAudio = defaults.object(forKey: "recordAudio") as? Bool ?? true
        exportOn = defaults.bool(forKey: "exportOn")
        exportFolder = defaults.string(forKey: "exportFolder") ?? ""
        importLanguage = defaults.string(forKey: "importLanguage") ?? "auto"
        importNotes = defaults.object(forKey: "importNotes") as? Bool ?? true
        overlayAuto = defaults.object(forKey: "overlayAuto") as? Bool ?? true
        overlayHideAfter = defaults.object(forKey: "overlayHideAfter") as? Double ?? 4
        talkKey = Shortcut(stored: defaults.string(forKey: "talkKey")) ?? .defaultTalk
        toggleKey = Shortcut(stored: defaults.string(forKey: "toggleKey")) ?? .defaultToggle
        aiModel = defaults.string(forKey: "aiModel") ?? "Ling-3.1-flash"
        aiProvider = defaults.string(forKey: "aiProvider") ?? "ling"
        aiModels = defaults.dictionary(forKey: "aiModels") as? [String: String] ?? [:]
        aiVoiceModels = defaults.dictionary(forKey: "aiVoiceModels") as? [String: String] ?? [:]
        aiCustomBase = defaults.string(forKey: "aiCustomBase") ?? ""
        aiCustomVoiceBase = defaults.string(forKey: "aiCustomVoiceBase") ?? ""
        aiCustomVoice = defaults.string(forKey: "aiCustomVoice") ?? ""
        aiCustomHearModel = defaults.string(forKey: "aiCustomHearModel") ?? ""
        aiCustomHearBase = defaults.string(forKey: "aiCustomHearBase") ?? ""
        aiCustomRecognize = defaults.bool(forKey: "aiCustomRecognize")
        aiCustomOnly = defaults.bool(forKey: "aiCustomOnly")
        aiCustomNotesOwn = defaults.bool(forKey: "aiCustomNotesOwn")
        aiCustomNotesBase = defaults.string(forKey: "aiCustomNotesBase") ?? ""
        displayMode = defaults.string(forKey: "displayMode") ?? "notes"
        speakVoices = defaults.dictionary(forKey: "speakVoices") as? [String: String] ?? [:]
        endWithApp = defaults.object(forKey: "endWithApp") as? Bool ?? true
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        silenceEnd = defaults.string(forKey: "silenceEnd") ?? "prompt"
        silenceMinutes = defaults.object(forKey: "silenceMinutes") as? Double ?? 10
        listenSource = ["room", "both"].contains(defaults.string(forKey: "listenSource")) ? defaults.string(forKey: "listenSource")! : "system"
        autoMicOnStart = defaults.bool(forKey: "autoMicOnStart")
        roomMicUID = defaults.string(forKey: "roomMicUID") ?? ""
        diagnostics = defaults.object(forKey: "diagnostics") as? Bool ?? DevBuild.isDev
        notesCapturable = defaults.bool(forKey: "notesCapturable")
        fixMisheard = defaults.object(forKey: "fixMisheard") as? Bool ?? true
        askNames = defaults.object(forKey: "askNames") as? Bool ?? true
        if defaults.bool(forKey: "speakerVoicesRegular") {
            speakerVoices = defaults.bool(forKey: "speakerVoices")
        } else {
            speakerVoices = true
            defaults.set(true, forKey: "speakerVoices")
            defaults.set(true, forKey: "speakerVoicesRegular")
        }
        speakerMemory = defaults.object(forKey: "speakerMemory") as? Bool ?? true
        speakerEveryLine = defaults.object(forKey: "speakerEveryLine") as? Bool ?? false
    }

    private func save() {
        switch sourceMode {
        case .auto: defaults.set("auto", forKey: "sourceMode")
        case .fixed(let lang): defaults.set(lang.locale, forKey: "sourceMode")
        }
        defaults.set(target, forKey: "target")
        defaults.set(subtitles, forKey: "subtitles")
        defaults.set(notesLanguage, forKey: "notesLanguage")
        defaults.set(speakEnabled, forKey: "speakEnabled")
        defaults.set(speakConfirmed, forKey: "speakConfirmed")
        defaults.set(speakFrom, forKey: "speakFrom")
        defaults.set(speakHandsFree, forKey: "speakHandsFree")
        defaults.set(speakTo, forKey: "speakTo")
        defaults.set(speakOutput, forKey: "speakOutput")
        defaults.set(autoSystemMic, forKey: "autoSystemMic")
        defaults.set(speakMic, forKey: "speakMic")
        defaults.set(savedSystemInput, forKey: "savedSystemInput")
        defaults.set(recordAudio, forKey: "recordAudio")
        defaults.set(exportOn, forKey: "exportOn")
        defaults.set(exportFolder, forKey: "exportFolder")
        defaults.set(importLanguage, forKey: "importLanguage")
        defaults.set(importNotes, forKey: "importNotes")
        defaults.set(overlayAuto, forKey: "overlayAuto")
        defaults.set(overlayHideAfter, forKey: "overlayHideAfter")
        defaults.set(talkKey.stored, forKey: "talkKey")
        defaults.set(toggleKey.stored, forKey: "toggleKey")
        defaults.set(aiModel, forKey: "aiModel")
        defaults.set(aiProvider, forKey: "aiProvider")
        defaults.set(aiModels, forKey: "aiModels")
        defaults.set(aiVoiceModels, forKey: "aiVoiceModels")
        defaults.set(aiCustomBase, forKey: "aiCustomBase")
        defaults.set(aiCustomVoiceBase, forKey: "aiCustomVoiceBase")
        defaults.set(aiCustomVoice, forKey: "aiCustomVoice")
        defaults.set(aiCustomHearModel, forKey: "aiCustomHearModel")
        defaults.set(aiCustomHearBase, forKey: "aiCustomHearBase")
        defaults.set(aiCustomRecognize, forKey: "aiCustomRecognize")
        defaults.set(aiCustomOnly, forKey: "aiCustomOnly")
        defaults.set(aiCustomNotesOwn, forKey: "aiCustomNotesOwn")
        defaults.set(aiCustomNotesBase, forKey: "aiCustomNotesBase")
        defaults.set(displayMode, forKey: "displayMode")
        defaults.set(speakVoices, forKey: "speakVoices")
        defaults.set(endWithApp, forKey: "endWithApp")
        defaults.set(showInDock, forKey: "showInDock")
        defaults.set(silenceEnd, forKey: "silenceEnd")
        defaults.set(silenceMinutes, forKey: "silenceMinutes")
        defaults.set(listenSource, forKey: "listenSource")
        defaults.set(autoMicOnStart, forKey: "autoMicOnStart")
        defaults.set(roomMicUID, forKey: "roomMicUID")
        defaults.set(diagnostics, forKey: "diagnostics")
        defaults.set(notesCapturable, forKey: "notesCapturable")
        defaults.set(speakerVoices, forKey: "speakerVoices")
        defaults.set(speakerEveryLine, forKey: "speakerEveryLine")
        defaults.set(speakerMemory, forKey: "speakerMemory")
        defaults.set(fixMisheard, forKey: "fixMisheard")
        defaults.set(askNames, forKey: "askNames")
    }

    func resolvedTarget(source: String?) -> String {
        target == "system" ? followSystemTarget(source: source, systemLanguages: Locale.preferredLanguages) : target
    }

    var myLanguage: String {
        target == "system" ? Cicada.myLanguage(systemLanguages: Locale.preferredLanguages) : target
    }

    func systemTargetDescription() -> String {
        let prefs = Locale.preferredLanguages
        let mine = Cicada.myLanguage(systemLanguages: prefs)
        return [mine, followSystemTarget(source: mine, systemLanguages: prefs)].map(targetName).joined(separator: " / ")
    }

    var speakFromLang: Lang {
        sourceLanguages.first(where: { $0.locale == speakFrom }) ?? sourceLanguages[0]
    }
}

func debugLog(_ message: String) {
    if Thread.isMainThread, debugLogCapture != nil { debugLogCapture?.append(message) }
    let line = "\(Date()) \(message)\n"
    let path = DevBuild.logPath
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func contentLog(_ message: @autoclosure () -> String) {
    if UserDefaults.standard.bool(forKey: "debug") { debugLog(message()) }
}

extension AppSettings: FixSwitches {}

extension AppSettings: ImportSettings {}

extension AppSettings: FolderExportPrefs {}
