//
//  TabNavigator.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Switches the open notch's tab with a sideways slide: the new page comes
//  in from the side it sits on in the tab bar.
//

import AppKit
import SwiftUI

@MainActor
final class TabTransitionState: ObservableObject {
    static let shared = TabTransitionState()

    /// True when moving to a tab further right in the tab bar.
    @Published private(set) var forward = true
    private init() {}

    /// Slide in from the right when going forward, from the left when going back.
    var transition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    static let animation: Animation = .smooth(duration: 0.38)

    /// Selects `view`, sliding in the direction of travel.
    func select(_ view: NotchViews) {
        let coordinator = BoringViewCoordinator.shared
        guard view != coordinator.currentView else { return }
        let order = tabs.map(\.view)
        let from = order.firstIndex(of: coordinator.currentView) ?? 0
        let to = order.firstIndex(of: view) ?? 0
        let goingForward = to > from

        let change = {
            withAnimation(Self.animation) { coordinator.currentView = view }
        }

        if goingForward != forward {
            // The outgoing page takes its exit transition from its last render,
            // so the direction has to land one update before the page changes.
            forward = goingForward
            DispatchQueue.main.async(execute: change)
        } else {
            change()
        }
    }
}

/// Two-finger horizontal swipes on the trackpad switch tabs: one tab per
/// touch. Momentum after the fingers lift is ignored, and the next touch is
/// ready straight away — no waiting between swipes.
struct TabSwipeMonitor: NSViewRepresentable {
    /// Distance (in scroll points) the fingers travel before the tab changes.
    var threshold: CGFloat = 50
    /// +1 for the next tab (fingers moving left), -1 for the previous one.
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSwipe = onSwipe
        context.coordinator.threshold = threshold
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(threshold: threshold, onSwipe: onSwipe)
    }

    @MainActor
    final class Coordinator {
        var threshold: CGFloat
        var onSwipe: (Int) -> Void
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var firedThisTouch = false
        /// The touch began over something that scrolls sideways itself (the calendar's
        /// days, the Shelf): that scrolling is meant for it, not for switching tabs.
        private var blockedByScroller = false

        init(threshold: CGFloat, onSwipe: @escaping (Int) -> Void) {
            self.threshold = threshold
            self.onSwipe = onSwipe
        }

        /// Whether the view under `point` (window coordinates) sits inside an
        /// `NSScrollView` whose content is wider than what it shows.
        static func isOverHorizontalScroller(in window: NSWindow, at point: NSPoint) -> Bool {
            guard let content = window.contentView else { return false }
            let local = content.superview?.convert(point, from: nil) ?? point
            var view = content.hitTest(local)
            while let current = view {
                if let scroll = current as? NSScrollView,
                   let document = scroll.documentView,
                   document.frame.width > scroll.contentView.bounds.width + 1 {
                    return true
                }
                view = current.superview
            }
            return false
        }

        func install(on view: NSView) {
            remove()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
                guard let self, event.window === view?.window else { return event }
                self.handle(event)
                return event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            // Momentum is the gesture coasting after the fingers lifted — never a new swipe.
            guard event.momentumPhase.isEmpty else { return }

            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                accumulated = 0
                firedThisTouch = false
                if let window = event.window {
                    blockedByScroller = Self.isOverHorizontalScroller(in: window, at: event.locationInWindow)
                }
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                accumulated = 0
                firedThisTouch = false
                blockedByScroller = false
                return
            }
            guard event.phase.contains(.changed), !firedThisTouch, !blockedByScroller else { return }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard abs(dx) >= 1.5 * abs(dy) else { return }

            // Follow the fingers, whatever the natural-scrolling setting.
            let fingerDX = event.isDirectionInvertedFromDevice ? dx : -dx
            accumulated += fingerDX
            guard abs(accumulated) >= threshold else { return }

            firedThisTouch = true
            onSwipe(accumulated < 0 ? 1 : -1)
        }
    }
}
