import BackgroundTasks
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ImportPrefs: ImportSettings {
    var importLanguage: String { Pref.sourceAuto ? "auto" : Pref.sourceLang.locale }
    var speakerVoices: Bool { UserDefaults.standard.bool(forKey: Pref.voices) }
    func resolvedTarget(source: String?) -> String { Pref.target(for: source ?? Pref.sourceLang.code) }
}

enum ImportFiles {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(DevBuild.supportFolder).appendingPathComponent("Imports")
    }

    static func copy(_ url: URL) -> URL? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dir = folder.appendingPathComponent(UUID().uuidString)
        let out = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: out)
            return out
        } catch {
            debugLog("import: can't copy the file: \(error)")
            return nil
        }
    }

    static func remove(_ path: String?) {
        guard let path, path.hasPrefix(folder.path) else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent())
    }
}

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            guard let copy = ImportFiles.copy(received.file) else { throw CocoaError(.fileWriteUnknown) }
            return PickedMovie(url: copy)
        }
    }
}

@MainActor
enum ImportBackground {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "com.indaloop.cicada") + ".import" }
    private static var task: BGContinuedProcessingTask?
    private static var ticker: Timer?
    static weak var importer: FileImporter?

    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { t in
            MainActor.assumeIsolated { run(t) }
        }
        debugLog("import: background task registered=\(ok)")
    }

    static func begin(_ title: String) {
        guard task == nil else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L("正在导入"), subtitle: title)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugLog("import: background task not submitted: \(error)")
        }
    }

    private static func run(_ t: BGTask) {
        guard let t = t as? BGContinuedProcessingTask else { t.setTaskCompleted(success: false); return }
        task = t
        t.progress.totalUnitCount = 1000
        t.expirationHandler = {
            MainActor.assumeIsolated {
                debugLog("import: background time expired")
                importer?.cancelAll()
                finish(success: false)
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let importer, let task else { return }
                if !importer.busy { finish(success: true); return }
                task.progress.completedUnitCount = Int64(importer.progress * 1000)
                if let id = importer.current?.id, let s = importer.store.session(id) {
                    task.updateTitle(L("正在导入"), subtitle: s.displayTitle)
                }
            }
        }
        debugLog("import: running in the background")
    }

    private static func finish(success: Bool) {
        ticker?.invalidate()
        ticker = nil
        task?.setTaskCompleted(success: success)
        task = nil
    }
}

extension AppModel {
    func importFiles(_ urls: [URL], copied: Bool = false) {
        let files = urls.filter(FileImporter.importable).compactMap { copied ? $0 : ImportFiles.copy($0) }
        guard !files.isEmpty else {
            if !urls.isEmpty { importProblem = L("只能导入录音或带声音的视频") }
            return
        }
        Task {
            let ids = await importer.add(files)
            debugLog("import: added \(ids.count) files")
            ImportBackground.begin(files[0].deletingPathExtension().lastPathComponent)
        }
    }

    func openedFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        importFiles([url])
        try? FileManager.default.removeItem(at: url)
        return true
    }
}

struct ImportMenu<Label: View>: View {
    @EnvironmentObject var model: AppModel
    @State private var files = false
    @State private var photo: PhotosPickerItem?
    @State private var photos = false
    @ViewBuilder var label: Label

    var body: some View {
        Menu {
            Button { files = true } label: { SwiftUI.Label("从文件导入", systemImage: "folder") }
            Button { photos = true } label: { SwiftUI.Label("从相册导入视频", systemImage: "photo.on.rectangle") }
        } label: { label }
        .accessibilityLabel(Text("导入录音或视频"))
        .fileImporter(isPresented: $files, allowedContentTypes: [.audio, .movie, .audiovisualContent], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .photosPicker(isPresented: $photos, selection: $photo, matching: .videos)
        .onChange(of: photo) {
            guard let item = photo else { return }
            photo = nil
            Task {
                do {
                    if let movie = try await item.loadTransferable(type: PickedMovie.self) { model.importFiles([movie.url], copied: true) }
                } catch {
                    debugLog("import: Photos video failed: \(error)")
                    model.importProblem = L("这个视频读不出来")
                }
            }
        }
    }
}

struct ImportCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var importer: FileImporter

    var body: some View {
        if let job = importer.current {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: L("正在导入"))
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: job.url.pathExtension.lowercased().isVideo ? "film" : "waveform")
                                .font(.system(size: 18)).foregroundStyle(Ink.ink).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: job.url.lastPathComponent).font(.body.weight(.semibold)).foregroundStyle(Ink.ink).lineLimit(1)
                                Text(phase).font(.footnote).foregroundStyle(Ink.secondary).lineLimit(1).monospacedDigit()
                            }
                            Spacer(minLength: 8)
                            Button { importer.cancel(job.id) } label: {
                                Text("停止").font(.subheadline).foregroundStyle(Ink.ink)
                                    .padding(.horizontal, 12).frame(minHeight: 32)
                                    .background(Ink.ground, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                        }
                        ProgressView(value: importer.progress).tint(Ink.ink)
                        Text(importer.queue.isEmpty ? L("切到别的 app 也会继续") : L("还有 \(importer.queue.count) 个文件在排队"))
                            .font(.footnote).foregroundStyle(Ink.tertiary)
                    }
                    .padding(16)
                }
            }
        }
    }

    private var phase: String {
        switch importer.phase {
        case .preparing: L("正在读取文件…")
        case .detecting: L("正在听是哪种语言…")
        case .downloading(let name): L("正在下载 \(name) 语音模型…")
        case .transcribing: L("文字记录已转到 \(TranscriptExport.clock(importer.heard)) / \(TranscriptExport.clock(importer.duration))")
        case .translating:
            model.translationDown ? L("连不上翻译，\(importer.untranslated) 句等连上后再翻") : L("还有 \(importer.untranslated) 句在翻译")
        }
    }
}

private extension String {
    var isVideo: Bool { UTType(filenameExtension: self)?.conforms(to: .movie) ?? false }
}

extension AppModel {
    func retranscribe(_ id: String, lang: Lang? = nil) {
        importer.retry(id, lang: lang)
        guard importer.current?.id == id || importer.queue.contains(where: { $0.id == id }) else { return }
        ImportBackground.begin(store.session(id)?.displayTitle ?? "")
    }

    func canRetranscribe(_ s: Session) -> Bool {
        if let path = s.sourcePath, FileManager.default.fileExists(atPath: path) { return true }
        return [store.systemAudioURL(s.id), store.micAudioURL(s.id), store.roomAudioURL(s.id)]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct RetranscribeMenu: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var importer: FileImporter
    let session: Session

    var body: some View {
        if session.id != model.store.liveID, importer.status(of: session) == nil || importer.status(of: session) == .unfinished,
           model.canRetranscribe(session) {
            Menu {
                ForEach(sourceLanguages, id: \.locale) { lang in
                    Button(lang.name) { model.retranscribe(session.id, lang: lang) }
                }
            } label: { Label("重新转写", systemImage: "waveform.badge.magnifyingglass") }
        }
    }
}

struct ImportStatusStrip: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var importer: FileImporter
    let session: Session

    var body: some View {
        if let status = importer.status(of: session) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(title(status)).font(.subheadline).foregroundStyle(Ink.ink)
                    Spacer(minLength: 8)
                    if status == .running, importer.phase == .transcribing || importer.phase == .translating {
                        Text(verbatim: "\(Int(importer.progress * 100))%").font(.subheadline.monospacedDigit()).foregroundStyle(Ink.secondary)
                    } else if status == .unfinished, model.canRetranscribe(session) {
                        Button { model.retranscribe(session.id) } label: {
                            Text("重新转写").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(minHeight: 32)
                                .background(Ink.ink, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                    }
                }
                if status == .running {
                    ProgressView(value: importer.phase == .transcribing || importer.phase == .translating ? importer.progress : 0).tint(Ink.ink)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func title(_ status: FileImporter.Status) -> String {
        switch status {
        case .queued(let ahead): ahead > 0 ? L("排队中，前面还有 \(ahead) 个文件") : L("排队中")
        case .unfinished: model.canRetranscribe(session) ? L("没转完") : L("没转完，原文件已不在原来的位置")
        case .running:
            switch importer.phase {
            case .preparing: L("正在读取文件…")
            case .detecting: L("正在听是哪种语言…")
            case .downloading(let name): L("正在下载 \(name) 语音模型…")
            case .transcribing: L("文字记录已转到 \(TranscriptExport.clock(importer.heard)) / \(TranscriptExport.clock(importer.duration))")
            case .translating: L("还有 \(importer.untranslated) 句在翻译")
            }
        }
    }
}

struct ImportRowTag: View {
    @ObservedObject var importer: FileImporter
    let session: Session

    var body: some View {
        if let status = importer.status(of: session) {
            Text(tag(status)).font(.footnote.weight(.semibold))
                .foregroundStyle(status == .unfinished ? Ink.accentText : Ink.secondary).lineLimit(1)
        }
    }

    private func tag(_ status: FileImporter.Status) -> String {
        switch status {
        case .queued: L("排队中")
        case .unfinished: L("没转完")
        case .running:
            switch importer.phase {
            case .transcribing: L("转写中 \(Int(importer.progress * 100))%")
            case .translating: L("翻译中")
            default: L("准备中")
            }
        }
    }
}
