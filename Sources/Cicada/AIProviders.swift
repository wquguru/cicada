import Foundation

struct AIProvider: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case ling, openrouter, zenmux, openai, custom
        var id: String { rawValue }
    }

    struct Model: Equatable {
        let id: String
        let note: String
    }

    let id: Kind
    let name: String
    let base: URL?
    let site: URL?
    let textModels: [Model]
    let voiceModels: [Model]
    let voices: [CloudVoice]
    let clones: Bool
    let hearsAudio: Bool
    let spacing: TimeInterval

    var hasVoices: Bool { !voiceModels.isEmpty }

    static let ling = AIProvider(
        id: .ling, name: "Ling", base: URL(string: "https://api.ant-ling.com/v1/"),
        site: URL(string: "https://chat.ant-ling.com/platform/api"),
        textModels: [Model(id: "Ling-3.1-flash", note: L("更准")), Model(id: "Ling-3.0-flash", note: L("更快、更省"))],
        voiceModels: [Model(id: "Ming-3.0-tts-0.5B", note: "")], voices: [],
        clones: true, hearsAudio: true, spacing: 0.6)

    static let gemini: [CloudVoice] = [
        CloudVoice(id: "Kore", gender: L("女")), CloudVoice(id: "Aoede", gender: L("女")),
        CloudVoice(id: "Charon", gender: L("男")), CloudVoice(id: "Puck", gender: L("男")),
    ]

    static let openrouter = AIProvider(
        id: .openrouter, name: "OpenRouter", base: URL(string: "https://openrouter.ai/api/v1/"),
        site: URL(string: "https://openrouter.ai/settings/keys"),
        textModels: [Model(id: "inclusionai/ling-3.1-flash", note: L("和 Ling 同款")),
                     Model(id: "qwen/qwen3.8-flash", note: L("中文好"))],
        voiceModels: [Model(id: "google/gemini-3.8-flash-tts", note: L("效果和价格最均衡")),
                      Model(id: "google/gemini-3.8-flash-lite-tts", note: L("更省"))],
        voices: gemini, clones: false, hearsAudio: false, spacing: 0.1)

    static let zenmux = AIProvider(
        id: .zenmux, name: "ZenMux", base: URL(string: "https://zenmux.ai/api/v1/"),
        site: URL(string: "https://zenmux.ai/settings/keys"),
        textModels: [Model(id: "inclusionai/ling-3.0-flash", note: L("和 Ling 同款")),
                     Model(id: "qwen/qwen3.8-flash", note: L("中文好"))],
        voiceModels: [Model(id: "google/gemini-3.8-flash-tts", note: L("效果和价格最均衡")),
                      Model(id: "google/gemini-3.8-flash-lite-tts", note: L("更省"))],
        voices: gemini, clones: false, hearsAudio: false, spacing: 0.1)

    static let openai = AIProvider(
        id: .openai, name: "OpenAI", base: URL(string: "https://api.openai.com/v1/"),
        site: URL(string: "https://platform.openai.com/api-keys"),
        textModels: [Model(id: "gpt-5.4-nano", note: L("够用、更省"))],
        voiceModels: [], voices: [], clones: false, hearsAudio: false, spacing: 0.1)

    static let custom = AIProvider(
        id: .custom, name: L("自定义服务"), base: nil, site: nil,
        textModels: [], voiceModels: [], voices: [], clones: false, hearsAudio: false, spacing: 0.1)

    static let all: [AIProvider] = [.ling, .openrouter, .zenmux, .openai, .custom]

    static func named(_ raw: String) -> AIProvider { all.first { $0.id.rawValue == raw } ?? .ling }

    static func customBase(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = (isNearby(s) ? "http://" : "https://") + s }
        if !s.hasSuffix("/") { s += "/" }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        if url.scheme == "https" { return url }
        return url.scheme == "http" && isNearby(host) ? url : nil
    }

    static func isLocal(_ hostOrURL: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host(of: hostOrURL))
    }

    static func isNearby(_ hostOrURL: String) -> Bool {
        let h = host(of: hostOrURL).lowercased()
        if isLocal(h) || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, h.split(separator: ".").count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        if h.contains(":") { return h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80") }
        return false
    }

    private static func host(of hostOrURL: String) -> String {
        let s = hostOrURL.trimmingCharacters(in: .whitespaces)
        let url = URL(string: s.contains("://") ? s : "http://" + s)
        return (url?.host ?? s).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
}

struct CloudVoice: Equatable {
    let id: String
    let gender: String
}

struct AIConfig: Equatable {
    var provider: AIProvider
    var base: URL?
    var textModel: String
    var voiceModel: String?
    var voiceBase: URL?
    var customVoice: String?
    var hearModel: String? = nil
    var hearBase: URL? = nil
    var notesModel: String? = nil
    var notesBase: URL? = nil
    var notesOwnService = false
    var notesBadAddress = false

    var hasVoices: Bool { voiceModel != nil && voiceBase != nil }
    var transcribes: Bool { provider.id == .custom && hearModel != nil && hearBase != nil }

    var notesApart: Bool { provider.id == .custom && (notesModel != nil || notesBase != nil || notesOwnService) }

    var forNotes: AIConfig {
        guard notesApart else { return self }
        var c = self
        if let notesModel { c.textModel = notesModel }
        if let notesBase { c.base = notesBase }
        return c
    }

    var voices: [CloudVoice] {
        guard hasVoices else { return [] }
        if provider.id == .custom { return customVoice.map { [CloudVoice(id: $0, gender: "")] } ?? [] }
        return provider.voices
    }

    func shape(_ body: inout [String: Any], maxTokens: Int, templateKwargs: Bool = true) {
        switch provider.id {
        case .ling:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.2
            body["thinking"] = ["type": "disabled"]
        case .openrouter, .zenmux:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.2
            body["reasoning"] = ["enabled": false]
        case .openai:
            body["max_completion_tokens"] = maxTokens
            body["reasoning_effort"] = "none"
        case .custom:
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.2
            if templateKwargs { body["chat_template_kwargs"] = ["enable_thinking": false] }
        }
    }

    static func thought(_ root: [String: Any]) -> Bool {
        let message = ((root["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
        for k in ["reasoning_content", "reasoning"] {
            if let r = message?[k] as? String, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        let details = (root["usage"] as? [String: Any])?["completion_tokens_details"] as? [String: Any]
        if let n = details?["reasoning_tokens"] as? Int, n > 0 { return true }
        return (message?["content"] as? String)?.contains("<think>") ?? false
    }

    static func textModels(fromCatalog data: Data, recommended: [String]) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return recommended }
        var ids: [String] = []
        for m in list {
            guard let id = m["id"] as? String, !id.hasSuffix(":batch") else { continue }
            let arch = m["architecture"] as? [String: Any]
            let out = (m["output_modalities"] ?? arch?["output_modalities"]) as? [String]
            if let out, out != ["text"], !out.contains("text") { continue }
            if out == nil, id.range(of: #"(embed|whisper|tts|asr|transcribe|dall-e|image|moderation|realtime|audio|sora|search)"#,
                                    options: .regularExpression) != nil { continue }
            ids.append(id)
        }
        let rest = ids.filter { !recommended.contains($0) }.sorted()
        return recommended + rest
    }
}
