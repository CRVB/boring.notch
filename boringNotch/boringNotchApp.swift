//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

@MainActor
enum LegacyAppBundleMigration {
    static let legacyBundleName = BoringNotchAppBundleNames.legacy
    static let currentBundleName = BoringNotchAppBundleNames.current
    static var isRelaunching = false

    enum MigrationError: Swift.Error {
        case destinationExists(URL)
    }

    static func destinationURL(for bundleURL: URL) -> URL? {
        guard bundleURL.lastPathComponent == legacyBundleName else { return nil }
        return bundleURL.deletingLastPathComponent()
            .appendingPathComponent(currentBundleName, isDirectory: true)
    }

    @discardableResult
    static func migrateIfNeeded(
        at bundleURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let destinationURL = destinationURL(for: bundleURL) else { return nil }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw MigrationError.destinationExists(destinationURL)
        }

        try fileManager.moveItem(at: bundleURL, to: destinationURL)
        return destinationURL
    }
}

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    private let sparkleUpdaterDelegate: BoringSparkleUpdaterDelegate
    let updaterController: SPUStandardUpdaterController

    init() {
        #if DEBUG
        OTPDetector.runSelfCheck()
        #endif
        let sparkleUpdaterDelegate = BoringSparkleUpdaterDelegate()
        self.sparkleUpdaterDelegate = sparkleUpdaterDelegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: sparkleUpdaterDelegate, userDriverDelegate: nil)
        SoftwareUpdateStore.updater = updaterController.updater

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)

        let updaterController = self.updaterController
        Task { @MainActor in
            let sourceURL = Bundle.main.bundleURL
            if let destinationURL = LegacyAppBundleMigration.destinationURL(for: sourceURL) {
                let migrated = await XPCHelperClient.shared.migrateLegacyAppBundle(
                    from: sourceURL,
                    to: destinationURL
                )
                if migrated {
                    ApplicationRelauncher.restart(at: destinationURL) {
                        LegacyAppBundleMigration.isRelaunching = true
                    }
                    return
                }
                NSLog("Failed to migrate legacy Boring Notch app bundle at %@", sourceURL.path)
            }
            // Little Boring Notch: automatic updates are disabled until this fork
            // ships its own signed appcast. Upstream feeds would replace this build.
            if softwareUpdatesEnabled {
                updaterController.startUpdater()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Little Boring Notch", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Button("Restart Little Boring Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

@MainActor
enum SoftwareUpdateStore {
    static var updater: SPUUpdater?
}

@MainActor
final class BoringSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    @objc func feedURLString(for updater: SPUUpdater) -> String? {
        Defaults[.updateChannel].feedURLString
    }

    @objc func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Defaults[.updateChannel].allowedSparkleChannels
    }
}

/// App-lifecycle glue: shortcuts, onboarding, termination, observer wiring.
/// All notch-window / per-screen view-model / drag-detector lifecycle lives
/// in `NotchWindowManager` (see managers/NotchWindowManager.swift).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let camera = CameraModel()
    var statusItem: NSStatusItem?
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var closeNotchTask: Task<Void, Never>?
    private lazy var windowManager = NotchWindowManager(camera: camera)
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var observers: [Any] = []
    private var activeDisplayObserver: NSObjectProtocol?
    private var displayModeTask: Task<Void, Never>?
    private var observedDisplayMode: DisplayMode?

    /// Kept for existing internal readers; the state itself moved to the manager.
    var windows: [String: NSWindow] { windowManager.windows }
    var viewModels: [String: BoringViewModel] { windowManager.viewModels }
    var window: NSWindow? { windowManager.window }
    var vm: BoringViewModel { windowManager.primaryViewModel }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        SettingsWindowController.shared.showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if LegacyAppBundleMigration.isRelaunching { return }

        // Flush debounced shelf persistence to avoid losing recent changes
        ShelfStateViewModel.shared.flushSync()

        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MainActor.assumeIsolated {
            MusicManager.shared.destroy()
            windowManager.cleanup()
        }
        BetterDisplayManager.shared.stopObserving()
        LunarManager.shared.stopListening()
        LunarManager.shared.configureLunarOSD(hide: false)
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        displayModeTask?.cancel()
        MainActor.assumeIsolated { setActiveDisplayObserver(enabled: false, reposition: false) }
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        windowManager.screenLocked()
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        windowManager.screenUnlocked()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsWindowController.shared.setCamera(camera)
        migrateDisplayModeIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition(changeAlpha: true)
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition()
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.setupDragDetectors()
            }
        })

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
                KeyboardShortcuts.onKeyUp(for: .toggleSneakPeek) {
                    self.coordinator.toggleSneakPeek(
                        status: !self.coordinator.isAnySneakPeekShowing,
                        type: .music
                    )
                }
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.isAnySneakPeekShowing,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        // Load the upload queue now, so waiting files go out as soon as the Mac is online.
        _ = UploadQueue.shared

        // Double-press ⌘ (or ⌥ / ⌃) for a region screenshot.
        ScreenshotShortcut.shared.start()

        // Start watching Reminders now, so due alerts fire even if the Timers tab never opened.
        if Defaults[.timersEnabled] {
            _ = ReminderManager.shared
        }

        #if DEBUG
        // Debug-only hook so the notch can be driven from a script while testing:
        //   post "com.crvb.littleboringnotch.debug.showTab" with object home|shelf|timers|close
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("\(bundleIdentifier).debug.showTab"),
            object: nil, queue: .main) { [weak self] notification in
                let tab = notification.object as? String
                Task { @MainActor in
                    guard let self else { return }
                    if tab == "close" {
                        self.vm.close()
                        return
                    }
                    if tab == "shelf:list" {
                        let names = ShelfStateViewModel.shared.items.map { $0.displayName + ($0.isTemporary ? "*" : "") }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
                        return
                    }
                    if let tab, tab.hasPrefix("shelf:removeNamed:") {
                        let name = String(tab.dropFirst("shelf:removeNamed:".count))
                        let shelf = ShelfStateViewModel.shared
                        for item in shelf.items where item.isTemporary && item.displayName == name { shelf.remove(item) }
                        return
                    }
                    if let tab, tab.hasPrefix("shelf:fakeItems:"), let count = Int(tab.dropFirst("shelf:fakeItems:".count)) {
                        // Extra Shelf items (never queued for upload) so the Shelf has something to scroll;
                        // remove them again with shelf:removeProbeItems.
                        Task {
                            for n in 1...max(1, count) {
                                if let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(Data("x".utf8), suggestedName: "__PROBE__ \(n).txt")),
                                   let bookmark = try? Bookmark(url: url) {
                                    ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)])
                                }
                            }
                        }
                        return
                    }
                    if tab == "shelf:removeProbeItems" {
                        let shelf = ShelfStateViewModel.shared
                        for item in shelf.items where item.isTemporary && item.displayName.hasPrefix("__PROBE__") { shelf.remove(item) }
                        return
                    }
                    if tab == "scroll:probe" {
                        // '#' = a two-finger swipe starting there scrolls something sideways (tab swipe is ignored)
                        guard let window = NSApp.windows.first(where: { $0 is BoringNotchSkyLightWindow }) else { return }
                        let step: CGFloat = 20
                        var rows: [String] = []
                        var y = window.frame.height - 2
                        while y > 0 {
                            var row = ""
                            var x: CGFloat = 2
                            while x < window.frame.width {
                                row += TabSwipeMonitor.Coordinator.isOverHorizontalScroller(in: window, at: NSPoint(x: x, y: y)) ? "#" : "."
                                x += step
                            }
                            rows.append(row)
                            y -= step
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rows.joined(separator: "\n"), forType: .string)
                        return
                    }
                    if tab == "settingsWindow:tall" {
                        // Stretches the Settings window so a long page can be photographed whole.
                        SettingsWindowController.shared.window?.setContentSize(NSSize(width: 700, height: 1250))
                        return
                    }
                    if let tab, tab.hasPrefix("settings:") {
                        // settings:<tab raw name> — opens the Settings window on that tab
                        SettingsWindowController.shared.showWindow()
                        let raw = String(tab.dropFirst("settings:".count))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NotificationCenter.default.post(name: Notification.Name("debug.settingsTab"), object: raw)
                        }
                        return
                    }
                    if tab == "cloud:off" {
                        Defaults[.cloudreveEnabled] = false
                        QuickShareService.shared.refreshCloudreveProvider()
                        return
                    }
                    if tab == "cloud:retry" {
                        UploadQueue.shared.retryNow()
                        return
                    }
                    if let tab, tab.hasPrefix("cloud:testConfig:"), bundleIdentifier.hasSuffix(".test") {
                        // Only in the separate test copy of the app (its own bundle id, preferences and
                        // keychain item): cloud:testConfig:<url>|<user>|<password>|<screenshotFolder>
                        let parts = tab.dropFirst("cloud:testConfig:".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        if parts.count == 4 {
                            Defaults[.cloudreveServerURL] = parts[0]
                            Defaults[.cloudreveUsername] = parts[1]
                            KeychainPassword.save(parts[2], account: parts[1])
                            Defaults[.cloudreveScreenshotFolder] = parts[3]
                            Defaults[.cloudreveEnabled] = true
                            BoringViewCoordinator.shared.firstLaunch = false
                            UploadQueue.shared.configurationChanged()
                        }
                        return
                    }
                    if tab == "shot:fake" {
                        // A synthetic 400×200 picture through the normal after-capture path (no Screen Recording needed).
                        let size = NSSize(width: 400, height: 200)
                        let image = NSImage(size: size, flipped: false) { rect in
                            NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: rect, angle: 30)
                            return true
                        }
                        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            Task { await ScreenshotLauncher.finish(png: png, isRegion: true) }
                        }
                        return
                    }
                    if tab == "cloud:fakeJobs" {
                        // One file and two screenshots in the queue, with matching Shelf items,
                        // aimed at a folder no real server has. Remove them again with cloud:dropFakeJobs.
                        Task {
                            let q = UploadQueue.shared
                            q.enqueue(data: Data("x".utf8), name: "__TEST__ file.txt", folder: "/__lbn_test__", kind: .file)
                            for n in 1...2 {
                                let name = "Screenshot __TEST__ \(n).png"
                                if let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(Data("x".utf8), suggestedName: name)),
                                   let bookmark = try? Bookmark(url: url) {
                                    let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
                                    ShelfStateViewModel.shared.add([item])
                                    q.enqueue(data: Data("x".utf8), name: name, folder: "/__lbn_test__", kind: .screenshot, shelfItemID: item.id)
                                }
                            }
                        }
                        return
                    }
                    if tab == "cloud:cancelFirstFile" {
                        if let job = UploadQueue.shared.jobs(of: .file).first(where: { $0.fileName.contains("__TEST__") }) { UploadQueue.shared.cancel(job) }
                        return
                    }
                    if tab == "cloud:cancelFirstScreenshot" {
                        if let job = UploadQueue.shared.jobs(of: .screenshot).first { UploadQueue.shared.cancel(job) }
                        return
                    }
                    if tab == "cloud:dropFakeJobs" {
                        for job in UploadQueue.shared.jobs where job.fileName.contains("__TEST__") { UploadQueue.shared.cancel(job) }
                        return
                    }
                    if tab == "cloud:status" {
                        let q = UploadQueue.shared
                        let text = "configured=\(CloudreveConfig.current().isConfigured) files=\(q.jobs(of: .file).count) screenshots=\(q.jobs(of: .screenshot).count) failed=\(q.failedCount) online=\(q.isOnline) uploading=\(q.isUploading) errors=\(q.jobs.compactMap(\.lastError).joined(separator: ";"))"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        return
                    }
                    if tab == "cloud:shareTest" {
                        // Pushes a small text file through the Quick Share path, as a drop on the tile would.
                        Task {
                            if let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(Data("hello from the share tile".utf8), suggestedName: "share-test.txt")) {
                                await QuickShareService.shared.shareFilesOrText([url], using: .cloudreve, from: nil)
                            }
                        }
                        return
                    }
                    if tab == "shortcut:status" {
                        let text = "enabled=\(Defaults[.screenshotShortcutEnabled]) key=\(Defaults[.screenshotShortcutKey].rawValue) inputMonitoring=\(ScreenshotShortcut.hasInputMonitoringAccess)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        return
                    }
                    if tab == "shelf:showDelete" {
                        ShelfDebug.shared.toggleAlwaysShowDelete()
                        return
                    }
                    if tab == "shelf:removeNewestScreenshot" {
                        let shelf = ShelfStateViewModel.shared
                        if let item = shelf.items.last(where: { $0.isTemporary && $0.displayName.hasPrefix("Screenshot ") }) {
                            shelf.remove(item)
                        }
                        return
                    }
                    if tab == "shot:full" {
                        ScreenshotLauncher.take(.fullScreen, on: NSScreen.main)
                        return
                    }
                    if let tab, tab.hasPrefix("shot:region:") {
                        // shot:region:x,y,w,h in points from the top-left of the main screen
                        let v = tab.dropFirst("shot:region:".count).split(separator: ",").compactMap { Double($0) }
                        if v.count == 4, let screen = NSScreen.main {
                            Task { await ScreenshotLauncher.capture(screen: screen, region: CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) }
                        }
                        return
                    }
                    if tab == "shot:overlay" {
                        ScreenshotLauncher.take(.region, on: NSScreen.main)
                        return
                    }
                    if tab == "reminderAlert" {
                        NotchAlertCenter.shared.post(.reminder(ReminderItem(
                            id: "debug-\(UUID().uuidString)", title: "Test reminder", dueDate: .now,
                            hasTime: true, isCompleted: false, listTitle: "Debug", color: nil)))
                        return
                    }
                    if let tab, tab.hasPrefix("countdown:"), let seconds = Double(tab.dropFirst("countdown:".count)) {
                        CountdownTimerManager.shared.start(duration: seconds)
                        return
                    }
                    let target: NotchViews
                    switch tab {
                    case "home": target = .home
                    case "shelf": target = .shelf
                    case "todo": target = .todo
                    default: target = .timers
                    }
                    if self.vm.notchState == .open {
                        TabTransitionState.shared.select(target)
                    } else {
                        _ = self.vm.open()
                        self.coordinator.currentView = target
                    }
                }
        }
        #endif

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.displayMode] == .allDisplays {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    var didOpen = false
                    await MainActor.run {
                        didOpen = viewModel.open()
                    }
                    guard didOpen else { return }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        // Sync notch height with real value on app launch if mode is matchRealNotchSize
        syncNotchHeightIfNeeded()

        windowManager.prepareInitialWindows()

        displayModeTask = Task { @MainActor [weak self] in
            for await mode in Defaults.updates(.displayMode, initial: true) {
                guard let self else { return }

                let previousMode = self.observedDisplayMode
                self.observedDisplayMode = mode

                if let previousMode, (previousMode == .allDisplays) != (mode == .allDisplays) {
                    self.windowManager.cleanupWindows(shouldInvert: true)
                }

                self.setActiveDisplayObserver(enabled: mode == .activeDisplay, reposition: false)
                self.windowManager.adjustWindowPosition(changeAlpha: true)
                self.windowManager.setupDragDetectors()
            }
        }

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        }

        // make sure OSD subsystems are in the right state now that initial
        // notch windows have been created/cleaned up
        coordinator.applyOSDSources()
    }

    private func migrateDisplayModeIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "displayMode") == nil else { return }

        let mode: DisplayMode
        if Defaults[.showOnAllDisplays] {
            mode = .allDisplays
        } else if Defaults[.followActiveDisplay] {
            mode = .activeDisplay
        } else if Defaults[.automaticallySwitchDisplay] {
            mode = .fallbackIfPreferredUnavailable
        } else {
            mode = .preferredDisplay
        }

        Defaults[.displayMode] = mode
    }

    private static let activeDisplayDidChangeNotification =
        Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")

    @MainActor
    private func setActiveDisplayObserver(enabled: Bool, reposition: Bool = true) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        if enabled {
            guard activeDisplayObserver == nil else { return }

            activeDisplayObserver = workspaceCenter.addObserver(
                forName: Self.activeDisplayDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.windowManager.adjustWindowPosition(changeAlpha: true)
                    self.windowManager.setupDragDetectors()
                }
            }
        } else if let observer = activeDisplayObserver {
            workspaceCenter.removeObserver(observer)
            activeDisplayObserver = nil
        }

        guard reposition else { return }

        windowManager.adjustWindowPosition(changeAlpha: true)
        windowManager.setupDragDetectors()
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    @objc func screenConfigurationDidChange() {
        windowManager.screenConfigurationDidChange()
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = String(localized: "Onboarding")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.level = .floating
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    updater: SoftwareUpdateStore.updater,
                    onFinish: {
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: {
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.level = .floating
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}
