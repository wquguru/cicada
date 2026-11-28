import AppKit
import SwiftUI

// MARK: - Notes

struct NotesContentView: View {
    let notes: MeetingNotes
    var fresh: Set<String> = []
    var live = false
    var document = false
    var updating = false
    var summaryJustChanged = false
    var coveredUntil: Double?
    var endedAt: Double?
    var behind = 0
    var onJump: (Double) -> Void = { _ in }
    var fixTerms: AnyView? = nil
    var editing: NotesEditHooks? = nil

    var body: some View {
        if document {
            DocumentNotesView(notes: notes, fresh: fresh, live: live, updating: updating, endedAt: endedAt, onJump: onJump,
                              editing: editing)
        } else {
            cards
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: document ? 32 : 18) {
            if document && !notes.summary.isEmpty {
                Text(notes.summary).font(.system(size: 17)).lineSpacing(7).foregroundStyle(Palette.ink.opacity(0.9))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else if !notes.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("总结").font(.system(size: 15, weight: .bold))
                        if summaryJustChanged { Tag(L("刚更新"), live: true) }
                        Spacer()
                        if notes.final { Tag(L("完整版")) } else if live {
                            Tag(coveredUntil.map { L("速记版 · 到 \(NotesEngine.clock($0))") } ?? L("速记版"))
                        }
                    }
                    Text(notes.summary).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18).fill(Palette.raised))
            }

            if !notes.topics.isEmpty {
                VStack(alignment: .leading, spacing: document ? 0 : 14) {
                    title(L("议题"))
                    ForEach(Array(notes.topics.enumerated()), id: \.element.id) { i, topic in
                        if document { Divider() }
                        TopicView(topic: topic,
                                  end: i + 1 < notes.topics.count ? notes.topics[i + 1].start : (live ? nil : endedAt),
                                  current: live && i == notes.topics.count - 1, fresh: fresh, onJump: onJump)
                            .padding(.vertical, document ? 14 : 0)
                            .id(Self.topicID(topic))
                    }
                    if live, behind > 0, let coveredUntil {
                        NotesBehindRow(after: coveredUntil, lines: behind, onJump: onJump)
                    }
                }
            }

            if !notes.conclusions.isEmpty || !notes.todos.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    title(notes.todos.isEmpty ? L("结论") : L("结论和待办"))
                    if document {
                        VStack(alignment: .leading, spacing: 0) { items }
                    } else {
                        FramedList { items }
                    }
                }
            }

            if !notes.terms.isEmpty || fixTerms != nil {
                VStack(alignment: .leading, spacing: 10) {
                    title(L("人名和术语"))
                    if let fixTerms { fixTerms }
                    if !notes.terms.isEmpty { TermChips(terms: notes.terms, showHeard: true) }
                }
            }
        }
    }

    static func topicID(_ topic: NoteTopic) -> String { "topic-\(topic.id)" }

    @ViewBuilder
    private func title(_ text: String) -> some View {
        if document {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.secondary).padding(.bottom, 2)
        } else {
            SectionTitle(text)
        }
    }

    @ViewBuilder
    private var items: some View {
        let all = notes.conclusions + notes.todos
        ForEach(Array(all.enumerated()), id: \.offset) { i, item in
            let todo = i >= notes.conclusions.count
            if document && i > 0 { Divider() }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if todo {
                    Image(systemName: "circle").font(.system(size: document ? 13 : 11)).foregroundStyle(Palette.tertiary)
                } else if document {
                    Circle().fill(Palette.ink.opacity(0.55)).frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        .frame(width: 13)
                }
                Text(item.withOwner)
                    .font(.system(size: 14)).lineSpacing(2)
                    .foregroundStyle(item.support == 0 ? Palette.tertiary : Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.support == 0 {
                    Tag(L("依据较少"))
                } else if let t = item.t {
                    TimeLink(text: L("\(NotesEngine.clock(t)) · \(item.support) 句"), t: t, onJump: onJump)
                } else {
                    Tag(L("依据 \(item.support) 句"))
                }
            }
            .padding(.horizontal, document ? 0 : 16).padding(.vertical, 11)
            if !document && i < all.count - 1 { Divider() }
        }
    }
}

private struct DocumentNotesView: View {
    let notes: MeetingNotes
    let fresh: Set<String>
    let live: Bool
    let updating: Bool
    let endedAt: Double?
    let onJump: (Double) -> Void
    let editing: NotesEditHooks?
    @State private var hovered: NoteEdit.Target?
    @State private var draft = ""
    @State private var draftOwner = ""
    @State private var shownOwner = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            let items = notes.conclusions + notes.todos
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(notes.todos.isEmpty ? L("结论") : L("结论和待办"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                        .padding(.bottom, 2)
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        let todo = i >= notes.conclusions.count
                        if editing?.current == .item(i) {
                            itemEditor(index: i + 1, todo: todo)
                        } else {
                            editable(.item(i), inset: 8) { conclusion(item, index: i + 1, todo: todo) }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.raised))
            }

            if editing?.current == .summary {
                summaryEditor
            } else if !notes.summary.isEmpty {
                if editing == nil {
                    summaryText.textSelection(.enabled)
                } else {
                    editable(.summary, inset: 10, hoverFill: Palette.raised) { summaryText }
                }
            }

            if !notes.topics.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("议题").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.tertiary).padding(.bottom, 8)
                    ForEach(Array(notes.topics.enumerated()), id: \.element.id) { i, topic in
                        let current = live && i == notes.topics.count - 1
                        Rectangle().fill(MainWindowView.hairline).frame(height: 1)
                        DocumentTopicRow(index: i, topic: topic, current: current,
                                         updating: updating && current, fresh: fresh,
                                         startOpen: i == 0 || current, onJump: onJump)
                            .id(NotesContentView.topicID(topic))
                    }
                    Rectangle().fill(MainWindowView.hairline).frame(height: 1)
                }
            }

            if !notes.terms.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("人名和术语").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.tertiary)
                    TermChips(terms: notes.terms, showHeard: false)
                }
            }
        }
    }

    private var summaryText: some View {
        Text(notes.summary).font(.system(size: 15)).lineSpacing(9).foregroundStyle(Palette.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Editing in place

    @ViewBuilder
    private func editable<Content: View>(_ target: NoteEdit.Target, inset: CGFloat, hoverFill: Color = .white,
                                         @ViewBuilder content: () -> Content) -> some View {
        if let editing {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                content()
                Image(systemName: "pencil").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    .opacity(hovered == target ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.horizontal, inset).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovered == target ? hoverFill : .clear))
            .padding(.horizontal, -inset)
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? target : (hovered == target ? nil : hovered) }
            .onTapGesture { editing.open(target) }
            .help(L("点一下修改"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editing.open(target) }
        } else {
            content()
        }
    }

    private func fieldFrame<V: View>(_ field: V, radius: CGFloat = 9) -> some View {
        field
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(focused ? Palette.accent : Palette.line,
                                                                    lineWidth: focused ? 1.5 : 1))
    }

    private func itemEditor(index: Int, todo: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if todo { Image(systemName: "circle").font(.system(size: 11)) } else { Text("\(index)").font(.system(size: 12).monospacedDigit()) }
                }
                .fontWeight(.semibold).foregroundStyle(Palette.link).frame(width: 16, alignment: .leading)
                fieldFrame(TextField(todo ? L("待办") : L("结论"), text: $draft, axis: .vertical)
                    .font(.system(size: 15)).lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .onSubmit(commit))
                if todo {
                    TextField(L("负责人"), text: $draftOwner)
                        .textFieldStyle(.plain).focusEffectDisabled()
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).frame(width: 110, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1))
                        .onSubmit(commit)
                }
            }
            HStack(spacing: 14) {
                Text("⏎ 保存 · esc 取消").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Spacer()
                Button(L("删除这条")) { draft = ""; commit() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.accentInk)
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 2)
        .onAppear { load() }
        .onExitCommand { editing?.open(nil) }
    }

    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldFrame(TextEditor(text: $draft)
                .font(.system(size: 15)).lineSpacing(9)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: 72)
                .padding(.horizontal, 6).padding(.vertical, 8))
            HStack(spacing: 14) {
                Text("⌘⏎ 保存 · esc 取消").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                Spacer()
                Button(L("取消")) { editing?.open(nil) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Button(L("保存")) { commit() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentInk)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, -10)
        .onAppear { load() }
        .onExitCommand { editing?.open(nil) }
    }

    private func load() {
        guard let target = editing?.current else { return }
        switch target {
        case .summary:
            draft = notes.summary
            shownOwner = ""
        case .item(let i):
            let items = notes.conclusions + notes.todos
            guard items.indices.contains(i) else { return }
            draft = items[i].text
            shownOwner = items[i].ownerShown ?? ""
        }
        draftOwner = shownOwner
        hovered = nil
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard let editing, let target = editing.current else { return }
        let owner: String?? = draftOwner == shownOwner ? nil : .some(draftOwner)
        editing.save(target, draft, owner)
    }

    private func conclusion(_ item: NoteItem, index: Int, todo: Bool) -> some View {
        let weak = item.support == 0
        let text = item.withOwner
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if todo { Image(systemName: "circle").font(.system(size: 11)) } else { Text("\(index)").font(.system(size: 12).monospacedDigit()) }
            }
            .fontWeight(.semibold).foregroundStyle(weak ? Palette.secondary : Palette.link).frame(width: 16, alignment: .leading)
            Text(weak ? AttributedString(text) : Highlight.facts(text))
                .font(.system(size: 15)).lineSpacing(5)
                .foregroundStyle(weak ? Palette.secondary : Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if weak { Tag(L("依据较少")) }
            if let t = item.t, !weak { TimeLink(text: NotesEngine.clock(t), t: t, onJump: onJump) }
        }
        .padding(.vertical, 3)
    }
}

enum Highlight {
    private static let pattern = try! NSRegularExpression(pattern:
        "(\\d+\\s*月\\s*\\d+\\s*[日号])"
        + "|((下|本|这|上)?(周|星期|礼拜)[一二三四五六日天](早上|上午|中午|下午|晚上)?)"
        + "|(\\d[\\d,.]*\\s*(万|千|百|亿)?\\s*(元|块|美元|岁|人|个|次|天|周|个月|月|年|小时|分钟|点|号|%|％|k|K)?)"
        + "|((今天|明天|后天|昨天|月底|月初|年底)(早上|上午|中午|下午|晚上)?)")

    static func facts(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let ns = text as NSString
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let hit = ns.substring(with: m.range)
            if hit.count < 2 { continue }
            guard let r = Range(m.range, in: text),
                  let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].backgroundColor = Palette.mark
            out[lo..<hi].font = .system(size: 15, weight: .semibold)
        }
        return out
    }
}

private struct DocumentTopicRow: View {
    let index: Int
    let topic: NoteTopic
    let current: Bool
    let updating: Bool
    let fresh: Set<String>
    let onJump: (Double) -> Void
    @State private var open: Bool

    init(index: Int, topic: NoteTopic, current: Bool, updating: Bool, fresh: Set<String>,
         startOpen: Bool, onJump: @escaping (Double) -> Void) {
        self.index = index; self.topic = topic; self.current = current; self.updating = updating
        self.fresh = fresh; self.onJump = onJump
        _open = State(initialValue: startOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%02d", index + 1)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Palette.link).frame(width: 28, alignment: .leading)
                        Text(topic.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                        if current { Tag(L("正在讲"), live: true) }
                        if fresh.contains(topic.title) && !current { Tag(L("新"), live: true) }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                TimeLink(text: NotesEngine.clock(topic.start), t: topic.start, onJump: onJump)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.secondary).rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.vertical, 15)

            if open {
                VStack(alignment: .leading, spacing: 7) {
                    if !topic.summary.isEmpty {
                        Text(topic.summary).font(.system(size: 14)).lineSpacing(6).foregroundStyle(Palette.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(topic.points.enumerated()), id: \.offset) { i, p in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("·").foregroundStyle(Palette.secondary)
                            Text(p).font(.system(size: 14)).lineSpacing(5).foregroundStyle(Palette.ink).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if fresh.contains(p) { Tag(L("新"), live: true) }
                        }
                        .help(topic.pointTime(i).map { NotesEngine.clock($0) } ?? "")
                        .modifier(FadeIn(active: fresh.contains(p)))
                    }
                    if let fish = topic.fishbone { FishboneView(fishbone: fish, onJump: onJump).padding(.top, 4) }
                    if updating {
                        VStack(alignment: .leading, spacing: 7) {
                            SkeletonBar(fraction: 0.82, height: 10, warm: true)
                            SkeletonBar(fraction: 0.56, height: 10, warm: true)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.leading, 36).padding(.bottom, 20)
                .transition(.opacity)
            }
        }
        .onChange(of: current) { _, now in if now { open = true } }
    }
}

private struct TopicView: View {
    let topic: NoteTopic
    let end: Double?
    let current: Bool
    let fresh: Set<String>
    let onJump: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topic.title).font(.system(size: 15, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                if current { Tag(L("正在讲"), live: true) }
                if fresh.contains(topic.title) && !current { Tag(L("新"), live: true) }
                Spacer(minLength: 8)
                Button { onJump(topic.start) } label: {
                    Text(range)
                        .font(.system(size: 12, weight: current ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(current ? Palette.accentInk : Palette.tertiary)
                        .fixedSize()
                }
                .buttonStyle(.plain).help("看原话")
            }
            if !topic.summary.isEmpty {
                Text(topic.summary).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(topic.points.enumerated()), id: \.offset) { i, p in
                VStack(alignment: .leading, spacing: 3) {
                    if topic.pointTime(i) != nil || fresh.contains(p) {
                        HStack(spacing: 6) {
                            if let t = topic.pointTime(i) { TimeLink(text: NotesEngine.clock(t), t: t, onJump: onJump) }
                            if fresh.contains(p) { Tag(L("新"), live: true) }
                        }
                    }
                    Text(p).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .modifier(FadeIn(active: fresh.contains(p)))
            }
            if let fish = topic.fishbone { FishboneView(fishbone: fish, onJump: onJump).padding(.top, 4) }
        }
        .padding(.vertical, current ? 12 : 0).padding(.horizontal, current ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 14).fill(current ? Palette.accentWash : .clear))
    }

    private var range: String {
        let from = NotesEngine.clock(topic.start)
        guard let end, end > topic.start + 1 else { return current ? L("\(from) 起") : from }
        return "\(from)–\(NotesEngine.clock(end))"
    }
}

struct NotesBehindRow: View {
    let after: Double
    let lines: Int
    let onJump: (Double) -> Void

    var body: some View {
        Button { onJump(after) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    LiveDot()
                    Text("\(NotesEngine.clock(after)) 之后的 \(lines) 句还在整理").font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("先看原话 →").font(.system(size: 12))
            }
            .foregroundStyle(Palette.accentInk)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TimeLink: View {
    let text: String
    let t: Double
    let onJump: (Double) -> Void
    @State private var hover = false

    var body: some View {
        Button { onJump(t) } label: {
            Text(text).font(.system(size: 12).monospacedDigit())
                .fontWeight(.medium)
                .foregroundStyle(Palette.link)
                .underline(hover)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("回到原话")
    }
}

struct FishboneView: View {
    let fishbone: Fishbone
    var onJump: (Double) -> Void = { _ in }
    var forPicture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                Text(fishbone.question.isEmpty ? L("为什么") : fishbone.question).font(.system(size: 13, weight: .bold))
                Spacer()
                Text("鱼骨图").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
            VStack(spacing: 6) {
                ForEach(Array(stride(from: 0, to: fishbone.branches.count, by: 2)), id: \.self) { i in
                    HStack(alignment: .center, spacing: 0) {
                        branch(fishbone.branches[i])
                        spine
                        if i + 1 < fishbone.branches.count {
                            branch(fishbone.branches[i + 1])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !forPicture {
                Text("点击分支跳回原话").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
        .contentShape(Rectangle())
        .contextMenu {
            if !forPicture {
                Button("复制为图片") { RichCopy.image(fishbone, caption: nil) }
                Button("复制为文字") { RichCopy.text(fishbone) }
            }
        }
    }

    private var spine: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0.84)).frame(width: 2)
            Circle().fill(Palette.ink).frame(width: 7, height: 7)
            Rectangle().fill(Color(white: 0.84)).frame(width: 2)
        }
        .frame(width: 18)
    }

    private func branch(_ b: FishboneBranch) -> some View {
        let weak = b.support == 0
        return Button { if let t = b.t { onJump(t) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(b.label).font(.system(size: 12, weight: .bold)).foregroundStyle(weak ? Palette.tertiary : Palette.ink)
                if !b.detail.isEmpty {
                    Text(b.detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(weak ? Color.clear : Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(weak ? Color(white: 0.8) : .clear, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(weak ? L("依据较少，仅供参考") : L("看原话"))
    }
}

// MARK: - Transcript

@MainActor
enum UserScroll {
    private static var last = Date.distantPast
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            last = Date()
            return event
        }
    }

    static var recent: Bool { Date().timeIntervalSince(last) < 0.6 }
}

struct TranscriptListView<Partial: View>: View, Equatable {
    let lines: [TranscriptLine]
    let topics: [NoteTopic]
    var terms: [String] = []
    var currentMatch: String?
    var bilingual = true
    var live = false
    var partialShown = false
    var jumpTo: Double?
    var speakers: [String: Int] = [:]
    var startedAt: Date?
    var identifying = false
    var voices: [Int: Int] = [:]
    var marked: Int?
    var places = false
    var settling: Set<String> = []
    var voicePending: Set<String> = []
    var onAssign: ((Set<String>, Int) -> Void)?
    var onRevert: ((String, LineFix) -> Void)?
    var revealFixes = false
    @ViewBuilder var partial: Partial

    @State private var assigning: String?
    @State private var hovered: String?

    @State private var following = true
    @State private var seenCount = 0
    @State private var followQueued = false

    static func == (a: Self, b: Self) -> Bool {
        a.lines == b.lines && a.topics == b.topics && a.terms == b.terms && a.currentMatch == b.currentMatch
            && a.bilingual == b.bilingual && a.live == b.live && a.partialShown == b.partialShown
            && a.jumpTo == b.jumpTo && a.speakers == b.speakers && a.startedAt == b.startedAt && a.voices == b.voices && a.marked == b.marked
            && a.identifying == b.identifying && a.places == b.places && a.settling == b.settling
            && a.voicePending == b.voicePending
    }

    private var searching: Bool { !terms.isEmpty }

    private var groups: [(title: String, start: Double, lines: [TranscriptLine])] {
        guard !topics.isEmpty else { return [("", 0, lines)] }
        var out: [(String, Double, [TranscriptLine])] = []
        for (i, t) in topics.enumerated() {
            let end = i + 1 < topics.count ? topics[i + 1].start : .infinity
            let first = i == 0 ? -Double.infinity : t.start
            let ls = lines.filter { $0.t >= first && $0.t < end }
            if !ls.isEmpty { out.append((t.title, t.start, ls)) }
        }
        return out
    }

    private enum Item: Identifiable {
        case header(title: String, start: Double, gap: Bool)
        case paragraph([TranscriptLine], label: Bool)
        var id: String {
            switch self {
            case .header(_, let start, _): "group-\(start)"
            case .paragraph(let ls, _): ls[0].id
            }
        }
    }

    private var items: [Item] {
        let gs = groups
        let starts = SpeakerLabels.runStarts(lines, speakers)
        var out: [Item] = []
        for (gi, g) in gs.enumerated() {
            if !g.title.isEmpty { out.append(.header(title: g.title, start: g.start, gap: gi > 0)) }
            for (i, p) in TranscriptParagraphs.group(g.lines, speakers, pending: voicePending).enumerated() {
                out.append(.paragraph(p, label: speakers.isEmpty || !voices.isEmpty || i == 0 || starts.contains(p[0].id)))
            }
        }
        return out
    }

    private func target(_ line: TranscriptLine) -> String {
        for item in items { if case .paragraph(let ls, _) = item, ls.contains(where: { $0.id == line.id }) { return item.id } }
        return line.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            switch item {
                            case .header(let title, let start, let gap):
                                Text("\(NotesEngine.clock(start)) · \(title)")
                                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.secondary)
                                    .padding(.top, gap ? 16 : 6).padding(.bottom, 10)
                            case .paragraph(let ls, let label):
                                row(ls, label: label).padding(.bottom, 4)
                            }
                        }
                        if partialShown {
                            partial.id("partial")
                        }
                        if lines.isEmpty && !partialShown {
                            if live {
                                TranscriptWaitingView(startedAt: startedAt, identifying: identifying)
                            } else {
                                Text("说话的内容会出现在这里").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
                                    .frame(maxWidth: .infinity).padding(.top, 40)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom").bottomMarker()
                    }
                    .padding(.top, 8).padding(.bottom, 12)
                }
                .onLegacyBottomDistance { distance in
                    if UserScroll.recent {
                        if distance < 40 { if !following { following = true } }
                        else if following, distance > 60 { following = false; seenCount = lines.count }
                    } else if following, distance > 1 {
                        follow(proxy)
                    }
                }
                .topFade()
                .onScrollEdgeChange { old, new in
                    if new.height != old.height || new.container != old.container {
                        if new.distance > 1 { follow(proxy) }
                    } else if new.distance < 40 {
                        if !following { following = true }
                    } else if following, new.distance > 60, UserScroll.recent {
                        following = false
                        seenCount = lines.count
                    }
                }
                .onChange(of: lines.count) { _, _ in follow(proxy) }
                .onChange(of: partialShown) { _, _ in follow(proxy) }
                .onChange(of: currentMatch) { _, id in
                    guard let id, let line = lines.first(where: { $0.id == id }) else { return }
                    reveal(line, anchor: .center, proxy)
                }
                .onChange(of: jumpTo) { _, t in
                    guard let t, let target = lines.first(where: { $0.t >= t - 1 }) ?? lines.last else { return }
                    following = false
                    seenCount = lines.count
                    reveal(target, anchor: .top, proxy)
                }
                .onAppear {
                    UserScroll.install()
                    seenCount = lines.count
                    if let t = jumpTo, let target = lines.first(where: { $0.t >= t - 1 }) {
                        following = false
                        reveal(target, anchor: .top, proxy)
                    } else if live {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                if live, !following, !searching, lines.count > seenCount {
                    newLinesButton { following = true; proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    private func reveal(_ line: TranscriptLine, anchor: UnitPoint, _ proxy: ScrollViewProxy) {
        let id = target(line)
        proxy.scrollTo(id, anchor: anchor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard live, following, !searching, !followQueued else { return }
        followQueued = true
        DispatchQueue.main.async {
            followQueued = false
            guard following, !searching else { return }
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func newLinesButton(_ action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom).frame(height: 40)
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold))
                    Text("\(lines.count - seenCount) 句新内容").font(.system(size: 13, weight: .semibold))
                    if let last = lines.last {
                        Text(last.shown).font(.system(size: 13)).foregroundStyle(Color(white: 0.74)).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding(.leading, 14).padding(.trailing, 18).frame(height: 40)
                .background(Capsule().fill(Palette.ink).shadow(color: .black.opacity(0.18), radius: 12, y: 6))
                .frame(maxWidth: 380)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .background(Color.white)
        }
        .transition(.opacity)
    }

    private func matches(_ l: TranscriptLine) -> Bool { TranscriptSearch.matches(l, terms) }

    private func highlighted(_ text: String, current: Bool) -> AttributedString {
        TranscriptSearch.highlighted(AttributedString(text), terms, current: current)
    }

    private func highlighted(_ base: AttributedString, current: Bool) -> AttributedString {
        TranscriptSearch.highlighted(base, terms, current: current)
    }

    private func row(_ ls: [TranscriptLine], label: Bool = true) -> some View {
        let l = ls[0]
        let isMatch = ls.contains { $0.id == currentMatch }
        let latest = live && ls.last?.id == lines.last?.id
        let dim = searching && !ls.contains(where: matches)
        let src = TranscriptParagraphs.joinFixed(ls)
        let dst = TranscriptParagraphs.join(ls.compactMap { $0.dst != $0.src && $0.dst != $0.shown ? $0.dst : nil })
        let fixed = ls.flatMap { l in (l.fixes ?? []).filter(\.applied).map { (l.id, $0) } }
        return HStack(alignment: .top, spacing: 12) {
            Text(NotesEngine.clock(l.t)).font(.system(size: 12, weight: isMatch ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(latest || isMatch ? Palette.accentInk : Palette.tertiary)
                .frame(width: l.t >= 3600 ? 56 : 40, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !label {
                    } else if l.speaker == "me" { MeTag() }
                    else if onAssign != nil, !voices.isEmpty {
                        Button { assigning = assigning == l.id ? nil : l.id } label: {
                            HStack(spacing: 4) {
                                if let n = speakers[l.id] { SpeakerTag(number: n) } else { UnknownSpeakerTag() }
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.tertiary)
                            }
                            .padding(.horizontal, assigning == l.id ? 6 : 0).frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 6).fill(assigning == l.id ? Color.white : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(ls.count > 1 ? L("这段是谁说的") : L("这句是谁说的"))
                    }
                    else if let n = speakers[l.id] { SpeakerTag(number: n) }
                    else if !speakers.isEmpty { UnknownSpeakerTag() }
                    if places, label, l.speaker != "me" { PlaceTag(line: l) }
                    if live, ls.contains(where: { settling.contains($0.id) }) {
                        Spacer(minLength: 4)
                        Text("校准中").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                            .help(L("文字稍后会再校准一次，字幕不受影响"))
                    }
                }
                Text(highlighted(src, current: isMatch)).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                if bilingual, !dst.isEmpty {
                    Text(highlighted(dst, current: isMatch)).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .lineSpacing(2).textSelection(.enabled)
                }
                if hovered == l.id || revealFixes || latest, !fixed.isEmpty, let onRevert {
                    FixedWords(fixes: fixed, onRevert: onRevert).padding(.top, 2)
                }
                if assigning == l.id, let onAssign {
                    LineSpeakerPicker(voices: voices, current: l.voice.flatMap { voices[$0] != nil ? $0 : nil },
                                      nearby: nearby(ls), several: ls.count > 1) { v in
                        assigning = nil
                        onAssign(Set(ls.map(\.id)), v)
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(
            assigning == l.id ? Palette.fill
            : latest || isMatch ? Palette.accentWash
            : marked != nil && ls.contains(where: { $0.voice == marked }) ? SpeakerColor.ink(voices[marked!] ?? 1).opacity(0.07)
            : Color.clear))
        .opacity(dim ? 0.5 : 1)
        .onHover { inside in
            if inside { hovered = l.id } else if hovered == l.id { hovered = nil }
        }
    }

}

extension TranscriptListView {
    func nearby(_ ls: [TranscriptLine]) -> [Int] {
        guard let i = lines.firstIndex(where: { $0.id == ls[0].id }) else { return [] }
        let j = i + ls.count
        var out: [Int] = []
        for k in [i - 1, j, i - 2, j + 1] where lines.indices.contains(k) {
            if let v = lines[k].voice, voices[v] != nil, !out.contains(v), !ls.contains(where: { $0.voice == v }) { out.append(v) }
        }
        return out
    }
}

enum TranscriptParagraphs {
    static let span: Double = 30
    static let full = (cjk: 80, words: 40)

    static func isFull(_ lines: [TranscriptLine]) -> Bool {
        let text = lines.map(\.src).joined(separator: " ")
        let cjk = text.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
        return cjk ? text.filter(\.isLetter).count >= full.cjk : text.split(whereSeparator: \.isWhitespace).count >= full.words
    }

    static func group(_ lines: [TranscriptLine], _ speakers: [String: Int], pending: Set<String> = []) -> [[TranscriptLine]] {
        var out: [[TranscriptLine]] = []
        var key: String?
        var voice: Int?
        let noVoice = -1
        for l in lines {
            let k = (l.speaker == "me" ? "me" : speakers[l.id].map { "n\($0)" } ?? "?") + (l.via ?? "")
            let heard = l.voice.map { SpeakerLabels.substantive(l.src) ? $0 : nil } ?? (pending.contains(l.id) ? nil : noVoice)
            let v = speakers.isEmpty && l.speaker == "them" ? heard : nil
            if k == key, let p = out.last, let first = p.first, l.t - first.t <= span, !isFull(p),
               voice == nil || v == nil || v == voice {
                out[out.count - 1].append(l)
                voice = voice ?? v
            } else {
                out.append([l])
                voice = v
            }
            key = k
        }
        return out
    }

    static func joinFixed(_ lines: [TranscriptLine]) -> AttributedString {
        var out = AttributedString()
        var plain = ""
        for l in lines {
            let (text, marks) = Correction.apply(l.fixes ?? [], to: l.src)
            let p = text.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            if let last = plain.unicodeScalars.last, !(last.properties.isIdeographic || "。！？，、；：”）".unicodeScalars.contains(last)) {
                out += AttributedString(" ")
                plain += " "
            }
            var a = AttributedString(text)
            for m in marks {
                guard let lo = AttributedString.Index(m.lowerBound, within: a), let hi = AttributedString.Index(m.upperBound, within: a) else { continue }
                a[lo..<hi].underlineStyle = Text.LineStyle(pattern: .dot, color: Palette.tertiary)
            }
            for f in l.fixes ?? [] where f.ask == true {
                if let r = a.range(of: f.from) { a[r].backgroundColor = Palette.accentPale }
            }
            out += a
            plain += text
        }
        return out
    }

    static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
            if let last = out.unicodeScalars.last, !(last.properties.isIdeographic || "。！？，、；：”）".unicodeScalars.contains(last)) {
                out += " "
            }
            out += p
        }
        return out
    }
}

enum TranscriptPartial {
    static func shows(_ partial: String, live: Bool, after last: String?) -> Bool {
        let p = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard live, p.rangeOfCharacter(from: .alphanumerics) != nil else { return false }
        guard let last else { return true }
        return !last.contains(p) && !p.contains(last)
    }
}

struct LivePartialRow: View {
    @ObservedObject var model: AppModel
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let time = startedAt.map { max(0, ctx.date.timeIntervalSince($0)) }
            HStack(alignment: .top, spacing: 12) {
                Text(time.map(NotesEngine.clock) ?? "").font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.accentInk)
                    .frame(width: (time ?? 0) >= 3600 ? 56 : 40, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text(model.liveSource).font(.system(size: 14)).foregroundStyle(Palette.secondary).lineSpacing(2)
                        AnimatedDots().font(.system(size: 14)).foregroundStyle(Palette.secondary)
                    }
                    Text("正在说").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }
}

extension View {
    func topFade(_ height: CGFloat = 24) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: height)
                Color.black
            }
        }
    }

}

struct TranscriptWaitingView: View {
    var startedAt: Date?
    var identifying = false

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let startedAt { Text(Self.time.string(from: startedAt)).monospacedDigit() }
                Rectangle().fill(MainWindowView.hairline).frame(height: 1)
                Text("从这里开始听")
            }
            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
            .padding(.bottom, 14)
            FramedList {
                skeletonRow(0.7, 0.88)
                Divider()
                skeletonRow(0.54, 0.66).opacity(0.55)
            }
            HStack(spacing: 16) {
                legend(Palette.placeholder.opacity(0.6), L("原话"))
                legend(Palette.ink, L("译文"))
            }
            .padding(.top, 10).padding(.leading, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("此刻").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accentInk)
                HStack(spacing: 3) {
                    Text(identifying ? L("正在识别语言…") : L("等有人开口")).font(.system(size: 15)).foregroundStyle(Palette.tertiary)
                    BlinkingCaret()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.raised))
            .padding(.top, 28)
        }
        .padding(.top, 8)
    }

    private func skeletonRow(_ a: CGFloat, _ b: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBar(fraction: a, height: 9)
            SkeletonBar(fraction: b, height: 11)
        }
        .padding(14)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(title)
        }
        .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
    }
}

struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            Rectangle().fill(Palette.accent).frame(width: 2, height: 17)
                .opacity(Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Small parts

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.secondary)
    }
}

struct Tag: View {
    let text: String
    var live = false
    init(_ text: String, live: Bool = false) {
        self.text = text
        self.live = live
    }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(live ? Palette.accentInk : Palette.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(live ? Palette.accentPale : Palette.fill))
            .fixedSize()
    }
}

struct TermChips: View {
    static let shown = 8
    let terms: [NoteTerm]
    var showHeard = true
    @State private var all = false

    var body: some View {
        let list = NoteTerm.ordered(terms)
        let extra = list.count - Self.shown
        FlowLayout(spacing: 6) {
            ForEach(all || extra <= 0 ? list : Array(list.prefix(Self.shown))) { t in
                VStack(alignment: .leading, spacing: 1) {
                    (Text(t.name).bold() + Text(t.note.isEmpty ? "" : " \(t.note)"))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    if showHeard, !t.heard.isEmpty {
                        Text("原识别 \(t.heard.prefix(2).joined(separator: "、"))")
                            .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.fill))
            }
            if extra > 0 {
                Button(all ? L("收起") : L("展开全部 \(list.count) 个")) { all.toggle() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 5)
            }
        }
    }
}

struct FramedList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private func size(_ v: LayoutSubview, _ width: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        return ideal.width <= width ? ideal : v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = size(v, width)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = size(v, bounds.width)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

// MARK: - Motion (notes in progress)

func phase(_ date: Date, period: Double, delay: Double = 0) -> Double {
    let t = date.timeIntervalSinceReferenceDate - delay
    return (t.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period) / period
}

struct Spinner: View {
    var size: CGFloat = 16
    var track = Palette.accentPale

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            ZStack {
                Circle().stroke(track, lineWidth: 2)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(phase(ctx.date, period: 0.9) * 360))
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

struct AnimatedDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    Text(".").opacity(0.3 + 0.7 * (0.5 - 0.5 * cos(phase(ctx.date, period: 1.2, delay: Double(i) * 0.2) * 2 * .pi)))
                }
            }
        }
    }
}

struct CapturableMark: View {
    let on: Bool
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var since = Date()

    private static let off = Color(red: 0.663, green: 0.682, blue: 0.722)

    var body: some View {
        Group {
            if !on {
                Circle().strokeBorder(Self.off, lineWidth: 1.5)
            } else if reduceMotion {
                Circle().fill(Palette.accent).background(Circle().fill(Palette.accent).opacity(0.25).scaleEffect(1.6))
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    let age = ctx.date.timeIntervalSince(since)
                    let t = 0.5 - 0.5 * cos(phase(ctx.date, period: 2.4, delay: since.timeIntervalSinceReferenceDate) * 2 * .pi)
                    let first = min(1, age / 0.7)
                    ZStack {
                        Circle().fill(Palette.accent).scaleEffect(1 + 0.9 * t).opacity(0.5 * (1 - t))
                        if first < 1 {
                            Circle().stroke(Palette.accent, lineWidth: 1.5).scaleEffect(1 + 1.6 * first).opacity(0.7 * (1 - first))
                        }
                        Circle().fill(Palette.accent)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .onChange(of: on) { _, now in if now { since = Date() } }
    }
}

struct LiveDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
            Circle().fill(Palette.accent).frame(width: 7, height: 7)
                .opacity(0.35 + 0.65 * (0.5 + 0.5 * cos(phase(ctx.date, period: 1.4) * 2 * .pi)))
        }
    }
}

struct SkeletonBar: View {
    var fraction: CGFloat = 1
    var height: CGFloat = 12
    var warm = false

    var body: some View {
        let base = warm ? Color(red: 0.965, green: 0.89, blue: 0.86) : Color(red: 0.933, green: 0.941, blue: 0.953)
        let light = warm ? Color(red: 0.992, green: 0.953, blue: 0.933) : Color(red: 0.969, green: 0.973, blue: 0.98)
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                let x = phase(ctx.date, period: 1.4) * 2 - 0.5
                RoundedRectangle(cornerRadius: min(6, height / 2))
                    .fill(LinearGradient(stops: [.init(color: base, location: 0), .init(color: light, location: 0.5),
                                                 .init(color: base, location: 1)],
                                         startPoint: UnitPoint(x: x - 0.6, y: 0.5), endPoint: UnitPoint(x: x + 0.6, y: 0.5)))
                    .frame(width: g.size.width * fraction)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct NotesListeningView: View {
    var heard = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                SoundBars()
                Text("有人开口后，约半分钟出第一版").font(.system(size: 13)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                if heard > 0 {
                    Text("已听到 \(heard) 句").font(.system(size: 12)).foregroundStyle(Palette.tertiary).fixedSize()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentPale.opacity(0.7)))
            VStack(alignment: .leading, spacing: 10) {
                Text("总结").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                SkeletonBar(fraction: 0.94, height: 10)
                SkeletonBar(fraction: 0.8, height: 10)
                SkeletonBar(fraction: 0.56, height: 10)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("议题").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                topicSlot(time: "00:00", lines: [0.52, 0.88, 0.7])
                topicSlot(time: "--:--", lines: [0.4, 0.76]).opacity(0.6)
            }
            FlowLayout(spacing: 6) {
                Text("会整理出").font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.vertical, 4)
                ForEach([L("结论"), L("待办"), L("人名和术语"), L("鱼骨图")], id: \.self) { t in
                    Text(t).font(.system(size: 12)).foregroundStyle(Palette.secondary).fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Palette.fill))
                }
            }
            .padding(.top, 4)
        }
    }

    private func topicSlot(time: String, lines: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(time).font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.placeholder)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, f in
                    SkeletonBar(fraction: f, height: i == 0 ? 11 : 8)
                }
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }
}

struct SoundBars: View {
    var height: CGFloat = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    let p = phase(ctx.date, period: 1.1, delay: Double(i) * 0.15)
                    Capsule().fill(Palette.accent).frame(width: 3, height: height)
                        .scaleEffect(x: 1, y: 0.3 + 0.7 * (0.5 - 0.5 * cos(p * 2 * .pi)))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct NotesGeneratingView: View {
    var heard: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Spinner()
                HStack(spacing: 0) {
                    Text("正在生成纪要")
                    AnimatedDots()
                }
                .font(.system(size: 15, weight: .bold))
                Spacer()
                if let heard, heard > 0 {
                    Text("已听到 \(heard) 句").font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("总结").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                SkeletonBar()
                SkeletonBar(fraction: 0.92)
                SkeletonBar(fraction: 0.64)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 14) {
                Text("议题").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.placeholder)
                topicRow(lines: [0.55, 0.88, 0.72])
                topicRow(lines: [0.42, 0.8]).opacity(0.6)
            }
        }
    }

    private func topicRow(lines: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SkeletonBar(height: 12).frame(width: 36)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, f in
                    SkeletonBar(fraction: f, height: i == 0 ? 14 : 10)
                }
            }
        }
    }
}

struct FadeIn: ViewModifier {
    let active: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!active || shown ? 1 : 0)
            .offset(y: !active || shown ? 0 : 4)
            .onAppear { if active { withAnimation(.easeOut(duration: 0.6)) { shown = true } } }
    }
}

struct MeetingEndingStrip: View {
    @ObservedObject var model: AppModel
    let pending: MeetingEndWatch.Pending
    var compact = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.endingTitle(pending)).font(.system(size: compact ? 13 : 14, weight: .bold)).lineLimit(2)
                Text(model.endingDetail(pending, now: now)).font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Palette.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                SoftButton(L("继续记录"), dark: true) { model.keepRecording() }
                SoftButton(L("现在结束")) { model.stop() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 12 : 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentPale))
        .onReceive(tick) { now = $0 }
    }
}


struct FixedWords: View {
    let fixes: [(line: String, fix: LineFix)]
    let onRevert: (String, LineFix) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(fixes.enumerated()), id: \.offset) { _, item in
                let c = Correction.label(item.fix)
                HStack(spacing: 6) {
                    (Text("听成").foregroundStyle(Palette.tertiary) + Text(" " + c.from) + Text(" → ").foregroundStyle(Palette.tertiary) + Text(c.to))
                        .font(.system(size: 11))
                    Button(L("改回")) { onRevert(item.line, item.fix) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.link)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.fill))
            }
        }
    }
}

struct FixConfirmCard: View {
    let line: TranscriptLine
    let fix: LineFix
    let count: Int
    let onAnswer: (Bool) -> Void
    var onLater: (() -> Void)? = nil

    var body: some View {
        let c = Correction.label(fix)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("这样改对吗？").font(.system(size: 13, weight: .semibold))
                Text("确认后整场一起改，以后也这样改").font(.system(size: 12)).foregroundStyle(Palette.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                if count > 1 { Text("1 / \(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Palette.tertiary) }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    (Text(c.from) + Text(" → ").foregroundStyle(Palette.tertiary) + Text(c.to).bold()).font(.system(size: 14))
                    Text("\(NotesEngine.clock(line.t)) · \(line.src)").font(.system(size: 11)).foregroundStyle(Palette.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { onAnswer(true) } label: {
                    Text("对").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Palette.ink))
                }.buttonStyle(.plain)
                Button { onAnswer(false) } label: {
                    Text("不对").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 14).frame(height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Palette.fill))
                }.buttonStyle(.plain)
                if let onLater {
                    Button(action: onLater) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.tertiary)
                            .frame(width: 26, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(L("稍后再看")).accessibilityLabel(L("稍后再看"))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

struct FixTermsView: View {
    @ObservedObject var fixes: LiveFixes
    let session: Session
    let onShow: (String) -> Void

    var body: some View {
        let words = Self.fixedWords(session)
        let waiting = fixes.pending(in: session.id)
        VStack(alignment: .leading, spacing: 8) {
            if !words.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(words, id: \.word) { w in
                        Button { onShow(w.word) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.word).font(.system(size: 12)).bold().foregroundStyle(Palette.ink)
                                Text("听成 \(w.heard.prefix(2).joined(separator: "、")) · 改了 \(w.count) 处")
                                    .font(.system(size: 11)).foregroundStyle(Palette.link)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.fill))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !waiting.isEmpty {
                Text("等你确认，还没改").font(.system(size: 12)).foregroundStyle(Palette.tertiary).padding(.top, 2)
                ForEach(Array(waiting.enumerated()), id: \.offset) { _, w in
                    let c = Correction.label(w.fix)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.to).font(.system(size: 13)).bold()
                            Text("听成 \(c.from)").font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                        }
                        Spacer(minLength: 4)
                        Button { fixes.answer(w.fix, yes: true, in: session.id) } label: {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Palette.ink))
                        }
                        .buttonStyle(.plain).accessibilityLabel(L("对"))
                        Button { fixes.answer(w.fix, yes: false, in: session.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
                                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(Palette.fill))
                        }
                        .buttonStyle(.plain).accessibilityLabel(L("不对"))
                    }
                    .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color(white: 0.8)))
                }
            }
        }
    }

    static func fixedWords(_ s: Session) -> [(word: String, heard: [String], count: Int)] {
        var out: [String: (heard: [String], count: Int)] = [:]
        for l in s.lines {
            for f in l.fixes ?? [] where f.applied {
                let c = Correction.label(f)
                let word = c.to.trimmingCharacters(in: .whitespaces)
                var e = out[word] ?? ([], 0)
                if !e.heard.contains(c.from) { e.heard.append(c.from) }
                e.count += 1
                out[word] = e
            }
        }
        return out.map { ($0.key, $0.value.heard, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
    }
}
