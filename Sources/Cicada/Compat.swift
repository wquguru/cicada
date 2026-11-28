import AppKit
import SwiftUI

extension View {
    @ViewBuilder func linkPointer() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
    }

    @ViewBuilder func onScrollEdgeChange(_ action: @escaping (ScrollEdge, ScrollEdge) -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: ScrollEdge.self) { g in
                ScrollEdge(distance: g.contentSize.height - g.contentOffset.y - g.containerSize.height,
                           height: g.contentSize.height, container: g.containerSize.height)
            } action: { old, new in action(old, new) }
        } else {
            self
        }
    }

    @ViewBuilder func onUserScroll(ownSince: @escaping () -> Date, _ action: @escaping () -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: action()
                case .animating where Date().timeIntervalSince(ownSince()) > 0.3: action()
                default: break
                }
            }
        } else {
            self
        }
    }

    @ViewBuilder func onScrolled(_ action: @escaping () -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in action() }
        } else {
            self
        }
    }
}

extension View {
    @ViewBuilder func onLegacyBottomDistance(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15, *) {
            self
        } else {
            coordinateSpace(name: LegacyScrollEdge.space)
                .background(GeometryReader { g in
                    Color.clear.preference(key: LegacyScrollEdge.Container.self, value: g.size.height)
                })
                .onPreferenceChange(LegacyScrollEdge.Container.self) { LegacyScrollEdge.container = $0 }
                .onPreferenceChange(LegacyScrollEdge.Bottom.self) { y in
                    action(y < 0 ? .greatestFiniteMagnitude : y - LegacyScrollEdge.container)
                }
        }
    }

    @ViewBuilder func bottomMarker() -> some View {
        if #available(macOS 15, *) {
            self
        } else {
            background(GeometryReader { g in
                Color.clear.preference(key: LegacyScrollEdge.Bottom.self,
                                       value: g.frame(in: .named(LegacyScrollEdge.space)).maxY)
            })
        }
    }
}

enum LegacyScrollEdge {
    static let space = "cicada.scroll"
    nonisolated(unsafe) static var container: CGFloat = 0
    struct Container: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    struct Bottom: PreferenceKey {
        static let defaultValue: CGFloat = -1
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

struct ScrollEdge: Equatable {
    var distance: CGFloat
    var height: CGFloat
    var container: CGFloat
}
