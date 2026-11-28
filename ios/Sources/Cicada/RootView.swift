import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                PadRoot(store: model.store)
            } else {
                PhoneRoot()
            }
        }
        .tint(Ink.accent)
        .preferredColorScheme(.light)
        .fullScreenCover(isPresented: $model.showFace, onDismiss: { model.closeFace() }) {
            FaceView(face: model.face).environmentObject(model)
        }
        .fullScreenCover(isPresented: $model.showWelcome) { Welcome().environmentObject(model).environmentObject(model.ling).environmentObject(model.room) }
        .alert(Text(model.importProblem ?? ""), isPresented: Binding(get: { model.importProblem != nil },
                                                                     set: { if !$0 { model.importProblem = nil } })) {
            Button("好") { model.importProblem = nil }
        }
        .alert(Text(model.comingSoon ?? ""), isPresented: Binding(get: { model.comingSoon != nil },
                                                                 set: { if !$0 { model.comingSoon = nil } })) {
            Button("好") { model.comingSoon = nil }
        } message: {
            Text("下一版就能用")
        }
    }
}

struct PhoneRoot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            RecordsSplit(store: model.store).opacity(model.tab == .records ? 1 : 0)
                .allowsHitTesting(model.tab == .records)
            SettingsView().opacity(model.tab == .settings ? 1 : 0)
                .allowsHitTesting(model.tab == .settings)
            if model.tab == .search { SearchView(store: model.store) }
        }
        .overlay(alignment: .bottom) {
            if barShown { TabBar().transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.25), value: barShown)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var barShown: Bool {
        switch model.tab {
        case .records: model.selection == nil && (!model.room.isRunning || model.liveHidden)
        case .settings: true
        case .search: model.searchPath.isEmpty
        }
    }
}

struct TabBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    item(.records, "会议记录", "list.bullet")
                    item(.settings, "设置", "gearshape")
                }
                .padding(.horizontal, 5)
                .frame(height: 62)
                .glassEffect(.regular, in: Capsule())

                Button { pick(.search) } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(model.tab == .search ? Ink.accentText : Ink.ink)
                        .frame(width: 62, height: 62)
                        .background(model.tab == .search ? Ink.accentWash : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(Text("搜索"))
                .accessibilityAddTraits(model.tab == .search ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func item(_ tab: AppTab, _ title: LocalizedStringKey, _ icon: String) -> some View {
        let on = model.tab == tab
        return Button { pick(tab) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium)).frame(height: 24)
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? Ink.accentText : Ink.secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(on ? Ink.accentWash : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pick(_ tab: AppTab) {
        if model.tab == tab {
            if tab == .records { model.selection = nil }
            if tab == .search { model.searchPath = [] }
        }
        model.tab = tab
    }
}
