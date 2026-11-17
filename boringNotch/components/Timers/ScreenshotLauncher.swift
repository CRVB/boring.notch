//
//  ScreenshotLauncher.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Takes a screenshot of the screen under the notch right away and puts it
//  on the clipboard. The notch itself is left out of the picture.
//

import AppKit
import ScreenCaptureKit

enum ScreenshotLauncher {
    @MainActor
    static func open(on screen: NSScreen? = nil) {
        Task { @MainActor in
            await capture(screen: screen ?? NSScreen.main)
        }
    }

    @MainActor
    private static func capture(screen: NSScreen?) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                Log.general.error("Screenshot: no display to capture")
                return
            }

            // Leave our own windows (the notch) out of the shot.
            let ownApps = content.applications.filter { $0.bundleIdentifier == bundleIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

            let scale = screen?.backingScaleFactor ?? 2
            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let nsImage = NSImage(cgImage: image, size: NSSize(width: display.width, height: display.height))

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
            playShutter()
        } catch {
            // The first try asks for Screen Recording permission; until it's granted this fails.
            Log.general.error("Screenshot failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
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
