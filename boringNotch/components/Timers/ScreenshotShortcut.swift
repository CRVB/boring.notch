//
//  ScreenshotShortcut.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Double-pressing a modifier key (⌘ by default) starts a region screenshot,
//  from any app. Watching keys across apps needs macOS's "Input Monitoring"
//  permission; without it the shortcut simply stays quiet.
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

@MainActor
final class ScreenshotShortcut {
    static let shared = ScreenshotShortcut()

    private var detector = DoubleTapDetector()
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
            return
        }
        let watched = Defaults[.screenshotShortcutKey].flag
        let held = flags.intersection(Self.modifierMask)
        let fired = detector.modifiersChanged(
            watchedDown: held.contains(watched),
            othersDown: !held.subtracting(watched).isEmpty,
            at: time)
        if fired { trigger() }
    }

    private func trigger() {
        // One selection at a time.
        guard !RegionSelector.shared.isActive else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        ScreenshotLauncher.take(.region, on: screen)
    }
}
