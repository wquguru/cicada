import SwiftUI

struct HomeTitle: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    var logo: CGFloat = 52
    var titleSize: CGFloat = 28
    var trailing: AnyView? = nil
    var liveTrailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            Logo(size: logo)
            VStack(alignment: .leading, spacing: 1) {
                if room.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 6) {
                            if room.paused { Circle().fill(Ink.secondary).frame(width: 8, height: 8) } else { LiveDot() }
                            Text(room.paused ? L("已暂停") : L("正在听 · \(TranscriptExport.clock(room.elapsed))"))
                        }
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(room.paused ? Ink.secondary : Ink.accentText)
                    }
                    let pair = Pref.pairText(room.languagePair.source, room.languagePair.target)
                    Text(room.cast ? (pair.isEmpty ? L("手机里的声音") : L("手机里的声音 · \(pair)"))
                         : pair.isEmpty ? (room.speakerMode ? L("外放") : L("会议室"))
                         : (room.speakerMode ? L("外放 · \(pair)") : L("会议室 · \(pair)")))
                        .font(.system(size: titleSize - 4, weight: .bold)).foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text(dateText(Date(), "MMMdEEEE")).font(.footnote).foregroundStyle(Ink.secondary)
                    Text("会议记录").font(.system(size: titleSize, weight: .bold)).foregroundStyle(Ink.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 0)
            if let trailing, !room.isRunning { trailing }
            if let liveTrailing, room.isRunning { liveTrailing }
        }
        .padding(.horizontal, 4)
    }
}

struct LiveDot: View {
    @State private var on = false

    var body: some View {
        Circle().fill(Ink.accent).frame(width: 8, height: 8)
            .shadow(color: Ink.accent.opacity(on ? 0 : 0.45), radius: on ? 6 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { on = true } }
            .accessibilityHidden(true)
    }
}

struct ListenBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @AppStorage(Pref.source) private var source = "auto"
    @AppStorage(Pref.target) private var target = "system"
    @AppStorage(Pref.hear) private var hear = "room"
    var onGlass = false

    var body: some View {
        HStack(spacing: 10) {
            if room.isRunning { live } else { idle }
        }
        .frame(height: 58)
        .background {
            if onGlass {
                Capsule().fill(Color.white).shadow(color: Ink.ink.opacity(0.08), radius: 2, y: 1)
            }
        }
        .modifier(GlassCapsule(on: !onGlass))
        .animation(.snappy(duration: 0.25), value: room.isRunning)
    }

    private var idle: some View {
        Group {
            Text("开始听").font(.headline).foregroundStyle(Ink.ink).lineLimit(1).fixedSize().padding(.leading, 18)
            Rectangle().fill(Ink.line).frame(width: 1, height: 20)
            Menu {
                Section {
                    Picker(selection: $hear) {
                        Text("会议室").tag("room")
                        Text("手机外放").tag("speaker")
                        if CastLink.available { Text("手机里的声音").tag("cast") }
                    } label: { Text("声音来源") }
                    .pickerStyle(.inline)
                    Text(hear == "speaker" ? L("别戴耳机，字幕会浮在小窗里")
                         : hear == "cast" && CastLink.available ? L("X Space、播客、视频 · 听不到你自己说的话")
                         : CastLink.available ? L("别的 app 里的声音，选“手机里的声音”") : L("听不到其他 app 的声音，线上会议请用电脑版"))
                }
                Picker(selection: $source) {
                    Text("自动识别").tag("auto")
                    ForEach(sourceLanguages, id: \.locale) { Text(Pref.name(of: $0)).tag($0.locale) }
                } label: { Text("对方说") }
                Picker(selection: $target) {
                    Text("跟随系统").tag("system")
                    ForEach(targetLanguages, id: \.code) { Text($0.name).tag($0.code) }
                } label: { Text("翻译成") }
            } label: {
                Text(verbatim: (hear == "speaker" ? L("外放") + " · " : hear == "cast" && CastLink.available ? L("手机里的声音") + " · " : "") + "\(Pref.sourceName) → \(targetName(Pref.target(for: Pref.sourceCode)))")
                    .font(.subheadline).foregroundStyle(Ink.secondary).lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("对方说和翻译成"))
            Button { model.startListening() } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Ink.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(Text("开始听"))
        }
    }

    private var live: some View {
        Group {
            Button { model.liveHidden = false } label: {
                HStack(spacing: 10) {
                    Wave(level: room.level)
                    let people = room.speakerCount
                    Text(people >= 2 ? L("\(people) 人在说") : (room.status.isEmpty ? L("正在听") : room.status))
                        .font(.subheadline).foregroundStyle(Ink.secondary).lineLimit(1)
                    if model.liveHidden {
                        Image(systemName: "chevron.up").font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary)
                    }
                }
                .padding(.leading, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.liveHidden)
            Button { room.setPaused(!room.paused) } label: {
                Image(systemName: room.paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Ink.ink)
                    .frame(width: 46, height: 46)
                    .background(Ink.ground, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(room.paused ? Text("继续") : Text("暂停"))
            Button { model.stopListening() } label: {
                Text("结束").font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 46)
                    .background(Ink.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

private struct GlassCapsule: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.glassEffect(.regular, in: Capsule()) } else { content }
    }
}

struct Wave: View {
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08)) { t in
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let phase = sin(t.date.timeIntervalSinceReferenceDate * 7 + Double(i) * 1.3)
                    let h = 5 + CGFloat(level) * 16 * CGFloat(0.55 + 0.45 * phase)
                    Capsule().fill(Ink.accent).frame(width: 3, height: max(5, h))
                }
            }
            .frame(height: 22)
        }
        .accessibilityHidden(true)
    }
}

struct LivePhone: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @EnvironmentObject var notes: NotesEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HomeTitle(liveTrailing: AnyView(
                    Button { model.liveHidden = true } label: { GlassIcon(systemName: "chevron.down") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("收起"))))
                ListenBar()
                CastCard()
                PillSwitch(selection: $model.livePage, options: [(.notes, notesTitle), (.subtitles, "字幕")])
                EndingStrip()
                ModelWaitCard()
                TranslateDownCard()
                NotesStatusLine()
                if let id = room.sessionID { FixAskCard(fixes: model.fixes, session: id) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            switch model.livePage {
            case .subtitles: LiveLines().padding(.top, 12)
            case .notes:
                ScrollView { NotesPage(notes: notes.notes).padding(20) }
                    .safeAreaInset(edge: .bottom) { SayingNow().padding(.horizontal, 16).padding(.bottom, 8) }
            }
        }
        .background(alignment: .topLeading) { PiPHost(pip: model.pip).frame(width: 4, height: 4) }
        .background(Ink.ground)
        .overlay(alignment: .bottom) { FixToast(fixes: model.fixes).padding(.horizontal, 16).padding(.bottom, 8) }
        .animation(.snappy(duration: 0.2), value: model.fixes.toast)
        .animation(.snappy(duration: 0.2), value: model.translationDown)
        .animation(.snappy(duration: 0.2), value: model.ending)
    }

    private var notesTitle: LocalizedStringKey {
        notes.fresh.isEmpty ? "纪要" : "纪要 · \(notes.fresh.count) 条新"
    }
}

enum LivePage: String { case subtitles, notes }

struct SayingNow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen

    var body: some View {
        let live = !room.draft.isEmpty
        let last = room.lines.last
        if live || last != nil {
            Button { withAnimation(.snappy(duration: 0.2)) { model.livePage = .subtitles } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(live ? L("正在说") : L("刚才")).font(.caption.weight(.semibold)).foregroundStyle(live ? Ink.accentText : Ink.secondary)
                        Spacer()
                        Text("点开看字幕").font(.caption).foregroundStyle(Ink.secondary)
                    }
                    Text(verbatim: live ? room.draft : last?.src ?? "").font(.footnote).foregroundStyle(Ink.secondary).lineLimit(1)
                    let dst = live ? room.draftTranslation : last?.dst ?? ""
                    if !dst.isEmpty { Text(verbatim: dst).font(.callout).foregroundStyle(Ink.ink).lineLimit(2) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.accent.opacity(live ? 0.35 : 0), lineWidth: 1.5) }
            }
            .buttonStyle(.plain)
        }
    }
}

struct TranslateDownCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.translationHealth.googleOff, model.translationHealth.sentencesUntranslated {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hourglass").foregroundStyle(Ink.secondary).padding(.top, 2)
                Text(L("译文等 \(model.ling.serviceLabel) 恢复 · 字幕先显示原文"))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if model.translationDown {
            Button { if !model.ling.hasKey { model.tab = .settings; model.showSettings = true } } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("连不上翻译，新字幕暂时只有原文").font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                        Text(model.ling.hasKey ? L("网络连不上，连上后会自动继续")
                             : model.ling.provider.id == .ling ? L("填 Ling key 后不用代理也能翻译，还会整理出纪要。")
                             : L("填好 \(model.ling.provider.name) 的 key 后用它翻译，还会整理出纪要。"))
                            .font(.footnote).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !model.ling.hasKey { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Ink.tertiary).padding(.top, 3) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

struct LiveLines: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @ScaledMetric(relativeTo: .subheadline) private var srcSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var dstSize: CGFloat = 17

    var body: some View {
        let session = model.store.session(room.sessionID)
        let numbers = session.map(TranscriptExport.speakerNumbers) ?? [:]
        let names = session.map(SpeakerLabels.names) ?? [:]
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if room.lines.isEmpty && room.draft.isEmpty {
                        Text(room.status.isEmpty ? L("开始说话后，字幕会出现在这里") : room.status)
                            .font(.subheadline).foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(room.lines) { l in
                        let rec = session?.lines.first { $0.id == l.id }
                        card(who: numbers[l.id].map { SpeakerLabels.label($0, names) }, time: l.t,
                             src: rec.map(FixedText.attributed) ?? AttributedString(l.src), dst: l.dst, live: false)
                            .id(l.id)
                    }
                    if !room.draft.isEmpty {
                        card(who: nil, time: nil, src: AttributedString(room.draft), dst: room.draftTranslation.isEmpty ? nil : room.draftTranslation, live: true)
                            .id("draft")
                    }
                    Color.clear.frame(height: 40).id("end")
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: room.lines.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: room.draft) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func card(who: String?, time: Double?, src: AttributedString, dst: String?, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(live ? L("正在说") : [who, time.map(TranscriptExport.clock)].compactMap { $0 }.joined(separator: " · "))
                .font(.caption.weight(.semibold)).foregroundStyle(live ? Ink.accentText : Ink.ink)
            Text(src).font(.system(size: srcSize)).foregroundStyle(Ink.secondary).lineSpacing(2)
            if let dst { Text(dst).font(.system(size: dstSize)).foregroundStyle(live ? Ink.secondary : Ink.ink).lineSpacing(4) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if live { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.accent.opacity(0.35), lineWidth: 1.5) }
        }
    }
}

struct LivePad: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @EnvironmentObject var notes: NotesEngine

    var body: some View {
        VStack(spacing: 0) {
            EndingStrip().frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 18)
            ModelWaitCard().frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 18)
            CastCard().frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 12)
            TranslateDownCard().frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 18)
            NotesStatusLine().frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 18)
            if let id = room.sessionID {
                FixAskCard(fixes: model.fixes, session: id).frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 18)
            }
        GeometryReader { g in
            if g.size.width >= 820 {
                HStack(alignment: .top, spacing: 22) {
                    column(notesTitle) {
                        ScrollView {
                            NotesPage(notes: notes.notes).padding(20)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                    }
                    column("字幕") { LiveLines().padding(.horizontal, -16) }
                        .frame(width: g.size.width * 0.42)
                }
                .padding(.horizontal, 20).padding(.top, 18)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    PillSwitch(selection: $model.livePage, options: [(.notes, notesTitle), (.subtitles, "字幕")]).frame(maxWidth: 320)
                    if model.livePage == .subtitles { LiveLines().padding(.horizontal, -16) } else {
                        ScrollView { NotesPage(notes: notes.notes).padding(20).background(Color.white, in: RoundedRectangle(cornerRadius: 22)) }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 18)
            }
        }
        }
        .background(alignment: .topLeading) { PiPHost(pip: model.pip).frame(width: 4, height: 4) }
        .background(Ink.ground)
        .overlay(alignment: .bottom) { FixToast(fixes: model.fixes).frame(maxWidth: 560).padding(.horizontal, 20).padding(.bottom, 12) }
        .animation(.snappy(duration: 0.2), value: model.fixes.toast)
        .animation(.snappy(duration: 0.2), value: model.fixes.asking(in: room.sessionID ?? "")?.fix)
    }

    private var notesTitle: LocalizedStringKey {
        notes.fresh.isEmpty ? "纪要" : "纪要 · \(notes.fresh.count) 条新"
    }

    private func column<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Ink.secondary).padding(.leading, 4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModelWaitCard: View {
    @EnvironmentObject var room: RoomListen

    var body: some View {
        if let d = room.downloading {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().tint(Ink.tertiary)
                    Text(L("正在下载 \(d.name) 语音模型")).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let s = max(0, Int(context.date.timeIntervalSince(d.since)))
                    Text(L("约 140 MB · 已等 \(String(format: "%d:%02d", s / 60, s % 60))"))
                        .font(.footnote).foregroundStyle(Ink.secondary).monospacedDigit()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

struct StartProblemCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen

    var body: some View {
        if !room.isRunning, let p = room.problem {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title(p)).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                        if let r = reason(p) {
                            Text(r).font(.footnote).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { room.dismissProblem() } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(Ink.tertiary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text("关闭"))
                }
                if let (label, act) = action(p) {
                    Button(action: act) {
                        Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(minHeight: 36)
                            .background(Ink.ink, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(.leading, 28)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func title(_ p: RoomListen.StartProblem) -> String {
        switch p {
        case .microphone: L("请在设置里允许知了使用麦克风")
        case .micBusy: L("别的 app 在用麦克风")
        case .model(let m): L("没能下载 \(m.lang.name) 语音模型")
        case .other(let message): message
        }
    }

    private func reason(_ p: RoomListen.StartProblem) -> String? {
        if p == .micBusy { return CastLink.available ? L("可以改听手机放出来的声音，接着出字幕。") : L("比如 X Space、电话") }
        guard case .model(let m) = p else { return nil }
        switch m.cause {
        case .offline: return L("网络连不上，连上后会自动继续")
        case .disk: return L("这台手机的存储空间不够了")
        case .limit: return L("这台手机上的语音模型已满 5 种")
        case .dictation(let message), .other(let message?): return message
        case .other(nil): return nil
        }
    }

    private func action(_ p: RoomListen.StartProblem) -> (String, () -> Void)? {
        let settings = { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        switch p {
        case .microphone: return (L("打开 iPhone 设置"), settings)
        case .micBusy where CastLink.available: return (L("改听手机里的声音"), { model.startListening(cast: true) })
        case .model(let m) where m.cause == .disk: return (L("打开 iPhone 设置"), settings)
        case .model(let m) where m.cause == .offline: return nil
        default: return (L("再试一次"), { room.retry() })
        }
    }
}

struct NotesStatusLine: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen
    @EnvironmentObject var notes: NotesEngine
    @EnvironmentObject var ling: LingClient

    var body: some View {
        if room.isRunning, let (text, needsYou, action) = line {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: needsYou ? "exclamationmark.triangle.fill" : "hourglass")
                    .foregroundStyle(needsYou ? Ink.accent : Ink.secondary).padding(.top, 2)
                Text(text).font(.subheadline).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let (label, act) = action {
                    Button(action: act) {
                        Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .background(Ink.ground, in: Capsule())
                    }
                    .buttonStyle(.plain).frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var lastCovered: Double {
        guard let s = model.store.session(room.sessionID), notes.notes.covered > 0, notes.notes.covered <= s.lines.count else { return 0 }
        return s.lines[notes.notes.covered - 1].t
    }

    private var line: (String, Bool, (String, () -> Void)?)? {
        let service = ling.serviceLabel
        let unreachable = ling.aiCheck.failure?.reason == .unreachable
        switch notes.state {
        case .invalidKey:
            return (lastCovered > 0 ? L("key 失效了 · 纪要停在 \(NotesEngine.clock(lastCovered))") : L("key 失效了 · 纪要等新的 key"), true,
                    (L("换 key"), { model.tab = .settings; model.showSettings = true }))
        case .rateLimited:
            return (L("\(service) 很忙 · 纪要稍后补上，字幕照常"), false, nil)
        case .unreachable where unreachable, .updating where unreachable:
            if model.translationHealth.googleOff, model.translationHealth.sentencesUntranslated { return nil }
            return (lastCovered > 0 ? L("纪要等 \(service) 恢复 · 停在 \(NotesEngine.clock(lastCovered))，字幕照常") : L("纪要等 \(service) 恢复 · 字幕照常"),
                    false, model.canSwitchToLing ? (L("改用 Ling"), { model.switchToLing() }) : nil)
        case .failed:
            return (L("这轮纪要没写好 · 下轮自动补上"), false, nil)
        default:
            return nil
        }
    }
}

struct CastCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var room: RoomListen

    var body: some View {
        Group {
            if room.isRunning, room.micBusy, !room.cast {
                card(icon: "mic.slash", title: L("别的 app 在用麦克风"), detail: L("比如 X Space、电话"),
                     body: L("可以改听手机放出来的声音，接着出字幕。"),
                     primary: (L("改听手机里的声音"), { room.switchToCast() }), secondary: (L("等它结束再听"), { room.dismissMicBusy() }),
                     foot: L("听不到你自己说的话"), accent: true)
            } else if room.isRunning, room.cast, room.castState == .waiting {
                card(icon: "record.circle", title: L("点“开始直播”后开始听"), detail: L("顶部亮红色就是在听"), body: nil,
                     primary: (L("打开直播"), { room.showPicker() }), secondary: nil, foot: nil, accent: true)
            } else if room.isRunning, room.cast, room.castSilent {
                card(icon: "speaker.slash", title: L("没录到声音"), detail: L("有些通话 app 不让别人录它的声音"),
                     body: L("换一台手机或电脑放在旁边，用“会议室”听。"),
                     primary: (L("结束"), { model.stopListening() }), secondary: (L("接着等"), { room.waitOutSilence() }),
                     foot: nil, accent: false)
            } else if room.isRunning, room.cast, room.castState == .connected {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.footnote).foregroundStyle(Ink.secondary)
                    Text("听不到你自己说的话 · 顶部红色结束后消失").font(.footnote).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.snappy(duration: 0.2), value: room.micBusy)
        .animation(.snappy(duration: 0.2), value: room.castState)
        .animation(.snappy(duration: 0.2), value: room.castSilent)
    }

    private func card(icon: String, title: String, detail: String, body: String?, primary: (String, () -> Void),
                      secondary: (String, (() -> Void)?)?, foot: String?, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(accent ? Ink.accentText : Ink.ink)
                    .frame(width: 44, height: 44)
                    .background(accent ? Ink.accentWash : Ink.ground, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Ink.ink)
                    Text(detail).font(.subheadline).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let body { Text(body).font(.subheadline).foregroundStyle(Ink.ink).fixedSize(horizontal: false, vertical: true) }
            Button(action: primary.1) {
                Text(primary.0).font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Ink.ink, in: Capsule())
            }
            .buttonStyle(.plain)
            if let secondary {
                Button { secondary.1?() } label: {
                    Text(secondary.0).font(.subheadline.weight(.semibold)).foregroundStyle(Ink.ink)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Ink.ground, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if let foot { Text(foot).font(.footnote).foregroundStyle(Ink.secondary) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.accent.opacity(accent ? 0.35 : 0), lineWidth: 1.5)
        }
    }
}
