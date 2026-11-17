//
//  ScreenshotLauncher.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Screenshots straight to the clipboard: the whole screen, or a region the
//  user drags out. The notch and the selection overlay are left out of the picture.
//

import AppKit
import Defaults
import ScreenCaptureKit

enum ScreenshotLauncher {
    enum Mode {
        case region
        case fullScreen
    }

    /// Takes a screenshot of `screen` (the main screen by default) and copies it.
    @MainActor
    static func take(_ mode: Mode, on screen: NSScreen? = nil) {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        // Without Screen Recording permission macOS only returns the desktop
        // wallpaper; ask for it instead of copying a useless picture.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            NSSound.beep()
            debugReport("screenshot: Screen Recording permission missing")
            return
        }

        switch mode {
        case .fullScreen:
            // Give the notch a moment to finish closing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                await capture(screen: screen, region: nil)
            }
        case .region:
            RegionSelector.shared.select(on: screen) { region in
                guard let region else { return }
                Task { @MainActor in
                    // The overlay has to be gone before the shot.
                    try? await Task.sleep(for: .milliseconds(120))
                    await capture(screen: screen, region: region)
                }
            }
        }
    }

    /// - Parameter region: rectangle in points, relative to the screen's top-left corner.
    @MainActor
    static func capture(screen: NSScreen, region: CGRect?) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                Log.general.error("Screenshot: no display to capture")
                return
            }

            // Leave our own windows (the notch, the selection overlay) out of the shot.
            let ownApps = content.applications.filter { $0.bundleIdentifier == bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

            let scale = screen.backingScaleFactor
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            if let region {
                let bounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
                let clipped = region.intersection(bounds).integral
                guard clipped.width >= 2, clipped.height >= 2 else { return }
                configuration.sourceRect = clipped
                configuration.width = Int(clipped.width * scale)
                configuration.height = Int(clipped.height * scale)
            } else {
                configuration.width = Int(CGFloat(display.width) * scale)
                configuration.height = Int(CGFloat(display.height) * scale)
            }

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let png = copyToClipboard(image, pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
            playShutter()
            await finish(png: png, isRegion: region != nil)
        } catch {
            Log.general.error("Screenshot failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            debugReport("screenshot failed: \(error.localizedDescription)")
        }
    }

    /// Debug builds put failures on the clipboard, where scripts can read them.
    @MainActor
    private static func debugReport(_ message: String) {
        #if DEBUG
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message, forType: .string)
        #endif
    }

    /// Everything after the picture exists: the Shelf, the upload and the toast.
    @MainActor
    static func finish(png: Data?, isRegion: Bool) async {
        // One name for the Shelf copy and the upload, so they match.
        let name = screenshotName()
        let shelfItemID = await addToShelf(png, name: name)
        let shelved = shelfItemID != nil

        // The notch is closed by now; confirm under it. With an upload going on the
        // toast stays until it knows whether the file made it.
        let uploading = queueUpload(png, name: name, shelfItemID: shelfItemID) { outcome in
            switch outcome {
            case .uploaded:
                NotchAlertCenter.shared.post(.screenshotCopied(region: isRegion, addedToShelf: shelved, upload: .uploaded))
            case .failed:
                NotchAlertCenter.shared.post(.screenshotCopied(region: isRegion, addedToShelf: shelved, upload: .failed))
            case .cancelled:
                NotchAlertCenter.shared.withdraw(id: NotchAlert.screenshotCopied(region: isRegion, addedToShelf: shelved, upload: nil).id)
            }
        }
        NotchAlertCenter.shared.post(.screenshotCopied(
            region: isRegion, addedToShelf: shelved, upload: uploading ? .uploading : nil))
    }

    /// PNG for browsers and chat apps, TIFF for everything that asks for an image.
    /// Returns the PNG so the same picture can go onto the Shelf.
    @MainActor
    @discardableResult
    private static func copyToClipboard(_ image: CGImage, pointSize: CGSize) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = pointSize
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let png = representation.representation(using: .png, properties: [:])
        if let png {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = representation.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        return png
    }

    private static func screenshotName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: .now)).png"
    }

    /// Hands the picture to the upload queue, which sends it to Cloudreve (now, or when back online).
    @MainActor
    private static func queueUpload(
        _ png: Data?, name: String, shelfItemID: UUID?, onOutcome: @escaping @MainActor (UploadOutcome) -> Void
    ) -> Bool {
        guard Defaults[.cloudreveEnabled], Defaults[.cloudreveUploadScreenshots],
              CloudreveConfig.current().isConfigured, let png else { return false }
        return UploadQueue.shared.enqueue(
            data: png, name: name, folder: Defaults[.cloudreveScreenshotFolder],
            kind: .screenshot, shelfItemID: shelfItemID, onOutcome: onOutcome)
    }

    /// Saves the picture as "Screenshot yyyy-MM-dd at HH.mm.ss.png" and puts it on the Shelf.
    @MainActor
    private static func addToShelf(_ png: Data?, name: String) async -> UUID? {
        guard Defaults[.screenshotAddToShelf], Defaults[.boringShelf], let png else { return nil }

        guard let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(png, suggestedName: name)),
              let bookmark = try? Bookmark(url: url) else {
            Log.shelf.error("Screenshot could not be saved for the Shelf")
            return nil
        }
        let item = ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)
        ShelfStateViewModel.shared.add([item])
        return item.id
    }

    private static func playShutter() {
        let shutter = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
        if let sound = NSSound(contentsOf: shutter, byReference: true) {
            sound.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }
}

// MARK: - Region selection

/// A dimmed overlay over one screen: drag to select, Esc or a plain click to cancel.
@MainActor
final class RegionSelector {
    static let shared = RegionSelector()

    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    /// A selection is on screen right now.
    var isActive: Bool { window != nil }

    private init() {}

    /// Calls `completion` with the selected rectangle in points relative to the
    /// screen's top-left corner, or nil when the selection was cancelled.
    func select(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        finish(nil)
        self.completion = completion

        let window = SelectionWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // The default open animation fades the window in from nothing and, in an
        // accessory app, can stall there with the window invisible but still
        // catching clicks.
        window.animationBehavior = .none
        window.alphaValue = 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(rect) }
        window.contentView = view
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(view)
        view.needsDisplay = true
        NSCursor.crosshair.push()
    }

    private func finish(_ rect: CGRect?) {
        guard window != nil || completion != nil else { return }
        if window != nil { NSCursor.pop() }
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        let done = completion
        completion = nil
        done?(rect)
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class SelectionView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()

        guard let selection, selection.width > 0, selection.height > 0 else { return }
        // Cut the selection out of the dimming.
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let label = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let badge = NSRect(
            x: selection.minX, y: max(selection.minY - size.height - 10, bounds.minY + 2),
            width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let selection, selection.width >= 4, selection.height >= 4 else {
            onFinish?(nil)
            return
        }
        // AppKit's origin is bottom-left; the capture wants top-left.
        onFinish?(CGRect(
            x: selection.minX, y: bounds.height - selection.maxY,
            width: selection.width, height: selection.height))
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
