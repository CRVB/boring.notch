//
//  ScreenshotShortcut.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Pressing a modifier key (⌘ by default) twice takes one kind of screenshot,
//  three times the other kind — from any app. Which is which is a setting.
//  Watching keys across apps needs macOS's "Input Monitoring" permission;
//  without it the shortcut simply stays quiet.
//

import AppKit
import Combine
import Defaults

enum ShortcutModifier: String, CaseIterable, Identifiable, Defaults.Serializable {
    case command
    case option
    case control

    var id: Self { self }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .option: .option
        case .control: .control
        }
    }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        }
    }

    var name: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        }
    }
}

/// What a screenshot shortcut takes.
enum ShortcutScreenshotMode: String, CaseIterable, Identifiable, Defaults.Serializable {
    case region
    case fullScreen

    var id: Self { self }

    var opposite: ShortcutScreenshotMode { self == .region ? .fullScreen : .region }

    var launcherMode: ScreenshotLauncher.Mode { self == .region ? .region : .fullScreen }
}

@MainActor
final class ScreenshotShortcut {
    static let shared = ScreenshotShortcut()

    private var detector = TapSequenceDetector()
    /// Waits out the pause in which a third press could still arrive.
    private var pendingDouble: Task<Void, Never>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private static let watchedEvents: NSEvent.EventTypeMask = [
        .flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    private static let modifierMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    private init() {}

    /// Whether macOS lets this app watch the keyboard while other apps are in front.
    static var hasInputMonitoringAccess: Bool { CGPreflightListenEventAccess() }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts (or stops) watching, and keeps doing so as the settings change.
    func start() {
        guard cancellables.isEmpty else { return }
        Defaults.publisher(.screenshotShortcutEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in Task { @MainActor in self?.apply(enabled: enabled) } }
            .store(in: &cancellables)
        Defaults.publisher(.screenshotShortcutKey)
            .sink { [weak self] _ in Task { @MainActor in self?.detector.reset() } }
            .store(in: &cancellables)
    }

    private func apply(enabled: Bool) {
        removeMonitors()
        guard enabled else { return }

        // Ask once, politely; after that the settings page offers the button.
        if !Self.hasInputMonitoringAccess, !Defaults[.screenshotShortcutAskedPermission] {
            Defaults[.screenshotShortcutAskedPermission] = true
            CGRequestListenEventAccess()
        }

        detector.reset()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.watchedEvents) { [weak self] event in
            let kind = event.type
            let flags = event.modifierFlags
            let time = event.timestamp
            Task { @MainActor in self?.handle(kind: kind, flags: flags, time: time) }
        }
        // Global monitors never see our own windows; this covers the notch and Settings.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.watchedEvents) { [weak self] event in
            let kind = event.type
            let flags = event.modifierFlags
            let time = event.timestamp
            Task { @MainActor in self?.handle(kind: kind, flags: flags, time: time) }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(kind: NSEvent.EventType, flags: NSEvent.ModifierFlags, time: TimeInterval) {
        guard kind == .flagsChanged else {
            detector.otherInput()
            pendingDouble?.cancel()
            return
        }
        let watched = Defaults[.screenshotShortcutKey].flag
        let held = flags.intersection(Self.modifierMask)
        let outcome = detector.modifiersChanged(
            watchedDown: held.contains(watched),
            othersDown: !held.subtracting(watched).isEmpty,
            at: time)
        switch outcome {
        case .none:
            break
        case .doublePending:
            // Two presses might still turn into three: wait before acting.
            pendingDouble?.cancel()
            let wait = detector.maxGap + 0.03
            pendingDouble = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, self.detector.confirmDouble() else { return }
                self.trigger(Defaults[.screenshotShortcutTwoPresses])
            }
        case .triple:
            pendingDouble?.cancel()
            trigger(Defaults[.screenshotShortcutTwoPresses].opposite)
        }
    }

    private func trigger(_ mode: ShortcutScreenshotMode) {
        // One selection at a time.
        guard !RegionSelector.shared.isActive else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        ScreenshotLauncher.take(mode.launcherMode, on: screen)
    }
}
