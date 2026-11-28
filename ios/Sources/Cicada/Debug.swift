import SwiftUI
import UIKit
import os

enum DebugChannel {
    static let name = "com.indaloop.cicada.debug" as CFString
    static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug-command")
    }

    @MainActor static func listen(_ model: AppModel) {
        guard DevBuild.isDev else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(model).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { DebugChannel.drain(model) } }
        }, name, nil, .deliverImmediately)
    }

    @MainActor static func drain(_ model: AppModel) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        for line in text.split(separator: "\n") where !line.isEmpty { model.debugCommand(String(line)) }
    }
}

extension AppModel {
    private var fixSession: String { store.liveID ?? selection ?? store.sessions.first?.id ?? "" }

    func debugCommand(_ cmd: String) {
        debugLog("debug command: \(cmd)")
        let (name, arg) = cmd.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        switch name {
        case "open":
            tab = .records
            selection = nil
        case "settings":
            tab = .settings
            showSettings = true
        case "closeSettings":
            showSettings = false
            tab = .records
        case "listen", "start":
            startListening()
        case "window":
            let s = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first ?? .zero
            let (short, long) = (min(s.width, s.height), max(s.width, s.height))
            switch arg {
            case "half": devWindow = CGSize(width: (short - 10) / 2, height: long)
            case "landscape": devWindow = CGSize(width: long, height: short)
            case "landscapeHalf": devWindow = CGSize(width: (long - 10) / 2, height: short)
            default: devWindow = nil
            }
            debugLog("window: \(arg) \(devWindow.map { "\($0)" } ?? "screen")")
        case "stop":
            stopListening()
        case "pause":
            room.setPaused(arg != "off")
        case "liveHidden":
            liveHidden = arg != "off"
        case "welcome":
            if arg == "done" { finishWelcome() } else { welcomeStep = Int(arg) ?? 0; showWelcome = true }
        case "samplePlay":
            welcomeStep = 1
            showWelcome = true
            playSample()
        case "sampleStop":
            stopSample()
        case "import":
            importFiles(arg.split(separator: "|").map {
                $0.hasPrefix("/") ? URL(fileURLWithPath: String($0)) : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String($0))
            })
        case "importStop":
            if let id = importer.current?.id { importer.cancel(id) }
        case "importRetry":
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            retranscribe(parts[0], lang: parts.count > 1 ? sourceLanguages.first { $0.locale == parts[1] } : nil)
        case "importExpire":
            importer.cancelAll()
        case "hear":
            UserDefaults.standard.set(arg == "speaker" ? "speaker" : "room", forKey: Pref.hear)
        case "interrupt":
            room.debugInterrupt(arg != "ended")
        case "quickStart":
            tab = .settings
            showSettings = true
            showQuickStart = arg != "off"
        case "intent":
            IntentHub.send(arg == "stop" ? .stop : arg == "pause" ? .togglePause : .start)
        case "pip":
            pip.start()
        case "livePage":
            livePage = arg == "notes" ? .notes : .subtitles
        case "source":
            UserDefaults.standard.set(arg, forKey: Pref.source)
        case "target":
            UserDefaults.standard.set(arg, forKey: Pref.target)
        case "focusSpeaker":
            focusSpeaker = Int(arg)
        case "play":
            NotificationCenter.default.post(name: .debugPlay, object: Double(arg) ?? 0)
        case "search":
            tab = .search
            searchPath = []
            query = arg
            logSearch()
        case "searchOpen":
            tab = .search
            let found = SearchView.matches(store.sessions, query)
            searchPath = [arg.isEmpty ? found.first?.id : arg].compactMap { $0 }
            logSearch()
        case "searchStep":
            if let s = store.session(searchPath.last ?? selection ?? store.sessions.first?.id) { stepSearch(Int(arg) ?? 1, in: s) }
            logSearch()
        case "mainShow":
            let parts = arg.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            tab = .records
            selection = parts.first.flatMap { id in store.sessions.contains(where: { $0.id == id }) ? id : nil }
                ?? store.sessions.first?.id
            if parts.count > 1 { recordPage = parts[1] == "notes" ? .notes : .transcript }
        case "back":
            selection = nil
            searchPath = []
            comingSoon = nil
        case "reload":
            store = SessionStore()
            notes = NotesEngine(ling: ling, store: store)
            wireNotes()
            fixes = makeFixes()
        case "generateNotes":
            generateNotes(arg.isEmpty ? (selection ?? store.sessions.first?.id ?? "") : arg)
        case "rename":
            let parts = arg.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            rename(parts[0], to: parts.count > 1 ? parts[1] : "")
        case "delete":
            deleteSession(arg)
        case "speakers":
            UserDefaults.standard.set(arg == "on", forKey: Pref.voices)
            TranscriptExport.voices = arg == "on"
            objectWillChange.send()
        case "notesLang":
            UserDefaults.standard.set(arg, forKey: Pref.notesLanguage)
        case "nameSpeaker":
            let p = arg.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if p.count == 3, let v = Int(p[1]) { renameSpeaker(session: p[0], voice: v, p[2]) }
        case "mergeSpeaker":
            let p = arg.split(separator: ",").map(String.init)
            if p.count == 3, let a = Int(p[1]), let b = Int(p[2]) { mergeSpeaker(session: p[0], a, into: b) }
        case "speakerPrompt":
            namingSpeaker = Int(arg)
        case "undoSpeaker":
            undoSpeakerEdit()
        case "fixes": UserDefaults.standard.set(arg != "off", forKey: Pref.fixMisheard)
        case "askNames": UserDefaults.standard.set(arg != "off", forKey: Pref.askNames)
        case "silentListen":
            RoomListen.silent = arg != "off"
        case "heard": room.debugHeard(arg)
        case "modelFail":
            RoomListen.simulatedModelFailure = arg.isEmpty ? nil : arg
        case "recordTrack":
            RoomListen.recordTrackOff = arg == "off"
        case "diag":
            debugLog("diag report:\n" + diagnosticsReport)
        case "switchToLing":
            switchToLing()
        case "startRetry":
            room.retry()
        case "aiCustomOnly":
            UserDefaults.standard.set(arg == "on", forKey: AIPrefs.customOnly)
            aiChanged()
        case "aiService":
            let p = arg.split(separator: ",", maxSplits: 1).map(String.init)
            if let k = p.first, !k.isEmpty {
                UserDefaults.standard.set(k, forKey: AIPrefs.provider)
                if p.count > 1 { AIPrefs.setModel(p[1], for: AIProvider.named(k)) }
                aiChanged()
            }
            tab = .settings
            showSettings = true
            showAIService = true
        case "exportTo":
            if arg == "off" { folderExport.turnOff() } else {
                let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(arg, isDirectory: true)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                if folderPrefs.remember(url) { folderExport.choose(url) }
            }
            tab = .settings
            showSettings = true
            showFolder = true
        case "exportAll": folderExport.writeAll()
        case "exportState":
            let x = folderExport
            debugLog("folder export: on=\(x.on) folder=\(x.folder?.lastPathComponent ?? "-") files=\(x.index.files.count) pending=\(x.index.pending.count) last=\(x.index.lastFile ?? "-") problem=\(x.problem.map { "\($0)" } ?? "-")")
        case "aiBase": UserDefaults.standard.set(arg, forKey: AIPrefs.customBase); aiChanged()
        case "voices":
            tab = .settings
            showSettings = true
            showVoices = arg != "off"
        case "voice":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { SpeakVoices.set(p[1], for: p[0]); objectWillChange.send() }
            debugLog("voices: \(SpeakVoices.all) own=\(VoiceReference.exists)")
        case "share":
            guard let s = store.session(selection ?? store.sessions.first?.id) else { break }
            Task {
                switch await ShareClient.shared.share(s, .init(scope: arg == "full" ? .full : .notes)) {
                case .shared(let r): debugLog("share: link \(r.url) expires \(r.expiresAt)")
                case .blocked(let hits, _): debugLog("share: blocked \(hits.count) hits")
                case .failed(let code, _): debugLog("share: failed \(code)")
                }
            }
        case "unshare":
            guard let id = selection ?? store.sessions.first?.id, let r = ShareStore.read(id) else { break }
            Task { debugLog("share: revoked \(await ShareClient.shared.revoke(r, sessionID: id))") }
        case "endTimes":
            let p = arg.split(separator: ",").compactMap { Double($0) }
            endTimesOverride = p.count == 2 ? (p[0], p[1]) : nil
            debugLog("meeting end: times \(String(describing: endTimesOverride))")
        case "endState":
            debugLog("meeting end: pending=\(ending.map { "\($0.reason)" } ?? "-") watching=\(endWatch != nil)")
        case "keepRecording": keepRecording()
        case "translateFail":
            translator.failNext = Int(arg) ?? 1
        case "googleDown":
            translator.simulateGoogleDown = arg != "off"
        case "aiHide":
            ling.hideKey = arg != "off"
            objectWillChange.send()
        case "heardT":
            let p = arg.split(separator: "|", maxSplits: 1).map(String.init)
            if p.count == 2 { room.debugHeard(p[0], translation: p[1]) }
        case "vocabAdd":
            let r = vocabulary.importText(arg.replacingOccurrences(of: "|", with: "\n"))
            debugLog("vocab: added=\(r.added) updated=\(r.updated) skipped=\(r.skipped)")
        case "vocabRemove": vocabulary.remove(arg)
        case "vocabState":
            debugLog("vocab: \(vocabulary.terms.count) terms")
            for t in vocabulary.terms { contentLog("VOCAB \(t.word) heard=\(t.heard) source=\(t.source) fixes=\(t.fixes)") }
        case "fixState":
            let id = arg.isEmpty ? fixSession : arg
            let lines = store.session(id)?.lines ?? []
            let all = lines.flatMap { $0.fixes ?? [] }
            debugLog("fix state \(id): lines=\(lines.filter { $0.fixes != nil }.count) applied=\(all.filter(\.applied).count) "
                     + "asked=\(all.filter { $0.ask == true }.count) off=\(all.filter { $0.off == true }.count) on=\(FixPrefs().fixMisheard)")
            for l in lines where l.fixes != nil {
                contentLog("FIXED \(l.id) \(l.fixes!.map { "\($0.from)→\($0.to)\($0.ask == true ? "?" : $0.off == true ? "✗" : "")" }) | \(l.shown)")
            }
        case "proposeFix":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let id = store.liveID, let l = store.session(id)?.lines.first(where: { $0.id == p[0] }) else { break }
            let edits = p[1].split(separator: "|").compactMap { e -> Correction.Edit? in
                let ft = e.split(separator: ">", maxSplits: 1).map(String.init)
                guard ft.count == 2 else { return nil }
                let tc = ft[1].split(separator: "@").map(String.init)
                return Correction.Edit(from: ft[0], to: tc[0], confidence: tc.count > 1 ? Double(tc[1]) ?? 0.9 : 0.9)
            }
            fixes.received(l.src, edits)
        case "fixAnswer":
            let parts = arg.split(separator: ",", maxSplits: 1).map(String.init)
            let id = parts.count > 1 ? parts[1] : fixSession
            if let first = fixes.asking(in: id) ?? fixes.pending(in: id).first.map({ ($0.line, $0.fix, 1, 1) }) {
                fixes.answer(first.fix, yes: parts.first == "yes", in: id)
            }
        case "resettle":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let id = store.liveID, let rec = store.session(id)?.lines.first(where: { $0.id == p[0] }) else { break }
            store.setSource(in: id, lineID: rec.id, p[1])
            fixes.applyKnown(lineID: rec.id, in: id)
            Task { [weak self] in
                guard let self, let out = await self.translator.translate(p[1], source: rec.srcLang, target: rec.dstLang, kind: .sentence) else { return }
                self.store.setTranslation(in: id, lineID: rec.id, out)
            }
        case "fixLater":
            let id = arg.isEmpty ? store.liveID ?? "" : arg
            if let a = fixes.asking(in: id) { fixes.later(a.fix, in: id) }
        case "fixUndo": fixes.undo()
        case "fixEdit":
            let (head, sid) = { () -> (String, String) in
                if let c = arg.lastIndex(of: ","), !arg[arg.index(after: c)...].contains("=") { return (String(arg[..<c]), String(arg[arg.index(after: c)...])) }
                return (arg, fixSession)
            }()
            let p = head.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { break }
            let opts = p[1].split(separator: "|").map(String.init)
            let n = fixes.edit(lineID: p[0], in: sid, to: opts[0], everywhere: !opts.contains("one"), remember: !opts.contains("keep0"))
            debugLog("fix edit changed \(n) lines")
        case "fixRevert":
            let parts = arg.split(separator: ",", maxSplits: 1).map(String.init)
            let id = parts.count > 1 ? parts[1] : fixSession
            if let l = store.session(id)?.lines.first(where: { $0.id == parts.first }), let f = l.fixes?.first(where: \.applied) {
                fixes.revert(f, lineID: l.id, in: id)
            }
        case "openLine": openLine = arg.isEmpty ? nil : arg
        case "scrollTo": NotificationCenter.default.post(name: .debugScroll, object: arg)
        case "fixEditor":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let sid = selection ?? fixSession
            if let l = store.session(sid)?.lines.first(where: { $0.id == p.first }) {
                editingLine = LineEdit(session: sid, line: l.id, start: p.count > 1 ? p[1] : l.shown)
            }
        case "closeEditor": editingLine = nil
        case "wordList":
            tab = .settings
            showSettings = true
            showWordList = arg != "off"
        case "wordImport": wordImport = arg == "off" ? nil : arg.replacingOccurrences(of: "|", with: "\n")
        case "wordEdit": editingWord = arg.isEmpty ? nil : arg
        case "wordHeard":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2, let t = vocabulary.terms.first(where: { $0.word == p[0] }) { addHeard(p[1], to: t) }
        case "wordDelete":
            if let t = vocabulary.terms.first(where: { $0.word == arg }) { deleteWord(t) }
        case "export":
            let id = selection ?? store.sessions.first?.id
            if !arg.isEmpty { UserDefaults.standard.set(arg, forKey: "iosExportFormat") }
            selection = id
            exporting = id
        case "exportFile":
            let p = arg.split(separator: ",").map(String.init)
            if let f = ExportFormat(rawValue: p.first ?? ""), let s = store.session(p.count > 1 ? p[1] : selection ?? store.sessions.first?.id) {
                debugLog("export file: \((try? f.file(s).path) ?? "failed")")
            }
        case "face": openFace()
        case "faceClose": closeFace()
        case "faceSay":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let side = FaceToFace.Side(rawValue: p[0]) else { break }
            face.debugText = p[1]
            face.press(side)
            face.release(side)
        case "faceTurn":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let q = p.count == 2 ? p[1].split(separator: "|", maxSplits: 1).map(String.init) : []
            if q.count == 2, let side = FaceToFace.Side(rawValue: p[0]) { face.debugTurn(side, said: q[0], translation: q[1]) }
        case "facePress":if let side = FaceToFace.Side(rawValue: arg) { face.press(side) }
        case "faceRelease": if let side = FaceToFace.Side(rawValue: arg) { face.release(side) }
        case "faceLangs":
            let p = arg.split(separator: ",").map(String.init)
            if p.count == 2, let m = FaceToFace.lang(p[0]), let t = FaceToFace.lang(p[1]) { face.setLanguages(mine: m, theirs: t) }
        case "faceHandsFree": face.setHandsFree(arg != "off")
        case "faceTurnTo": if let side = FaceToFace.Side(rawValue: arg) { face.giveTurn(side) }
        case "copyNotes":
            if let s = store.session(selection ?? store.sessions.first?.id) { copyNotes(s) }
        case "noteEdit":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let target: NoteEdit.Target = p.first == "summary" ? .summary : .item(Int(p.first ?? "") ?? 0)
            guard let id = selection ?? store.sessions.first?.id else { break }
            if p.count == 2 { saveNote(id, target, text: p[1]) } else { noteEdit = NoteEdit(session: id, target: target) }
        case "remember":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2, let v = Int(p[0]), let id = selection ?? store.sessions.first?.id { rememberSpeaker(session: id, voice: v, name: p[1]) }
        case "voiceState":
            if let s = store.session(selection ?? store.sessions.first?.id) {
                debugLog("voices: on=\(TranscriptExport.voices) numbers=\(SpeakerLabels.voiceNumbers(s)) names=\(SpeakerLabels.names(s)) lineVoices=\(s.lines.prefix(8).map { $0.voice.map(String.init) ?? "-" }) speakers=\(Set(s.lines.map(\.speaker)))")
            }
        case "people":
            tab = .settings
            showSettings = true
            showPeople = arg != "off"
            debugLog("voice profiles: \(profiles.all().map(\.name))")
        case "faceState":
            debugLog("face active=\(face.active) phase=\(face.phase) heard=\(face.heard.count) last=\(face.last.map { "\($0.side.rawValue) \($0.said.count)/\($0.translation.count)" } ?? "-") problem=\(face.problem)")
        case "importState":
            debugLog("import busy=\(importer.busy) phase=\(importer.phase) progress=\(String(format: "%.2f", importer.progress)) queue=\(importer.queue.count) current=\(importer.current?.id ?? "-")")
        case "state":
            debugLog("memory \(DeviceLoad.line)")
            debugLog("room problem=\(room.problem.map { "\($0)" } ?? "-") downloading=\(room.downloading?.name ?? "-")")
            debugLog("room running=\(room.isRunning) lines=\(room.lines.count) draft=\(room.draft.count) level=\(room.level) status=\(room.status) speaker=\(room.speakerMode) paused=\(room.paused) pip=\(pip.isActive) session=\(room.sessionID ?? "-")")
            debugLog("state tab=\(tab.rawValue) selection=\(selection ?? "-") page=\(recordPage) sessions=\(store.sessions.count) query=\(query) notesLang=\(notesLanguageCode(selection ?? store.sessions.first?.id ?? "")) undo=\(speakerUndo?.text ?? "-")")
        default:
            debugLog("debug command unknown: \(cmd)")
        }
    }

    private func logSearch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
            let found = SearchView.matches(store.sessions, query)
            let open = store.session(searchPath.last ?? (tab == .search ? nil : selection))
            let ms = open.map(searchMatches) ?? []
            let at = ms.isEmpty ? nil : ms[min(searchMatch, ms.count - 1)]
            let text = at.flatMap { id in open?.lines.first { $0.id == id } }.map { String($0.shown.prefix(40)) } ?? "-"
            debugLog("search: \"\(query)\" \(found.count) meetings, open \(open?.id ?? "-") page=\(recordPage) "
                     + "matches=\(ms.count) at=\(ms.isEmpty ? 0 : min(searchMatch, ms.count - 1) + 1)/\(ms.count) line=\(at ?? "-") \"\(text)\"")
        }
    }
}

struct DevWindow: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        if let size = model.devWindow {
            GeometryReader { geo in
                let scale = min(1, geo.size.width / size.width, geo.size.height / size.height)
                content
                    .environment(\.horizontalSizeClass, size.width >= 678 ? .regular : .compact)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .background(Color(white: 0.3).ignoresSafeArea())
        } else {
            content
        }
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}

enum DeviceLoad {
    static var footprintMB: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
    static var line: String {
        let thermal = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
        return "footprint=\(footprintMB)MB available=\(os_proc_available_memory() / 1_048_576)MB thermal=\(thermal)"
    }
}
