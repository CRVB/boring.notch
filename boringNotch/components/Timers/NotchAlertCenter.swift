//
//  NotchAlertCenter.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Alerts that drop down under the closed notch and stay until the user
//  answers them: a reminder coming due, or the countdown running out.
//

import Defaults
import Foundation
import SwiftUI

/// How the Cloudreve upload of a just-taken screenshot is going.
enum ScreenshotUploadState: Equatable {
    case uploading
    case uploaded
    case failed
}

enum NotchAlert: Identifiable, Equatable {
    case reminder(ReminderItem)
    case countdownFinished(duration: TimeInterval)
    /// A screenshot was copied to the clipboard; `region` tells a region from the whole screen.
    case screenshotCopied(region: Bool, addedToShelf: Bool, upload: ScreenshotUploadState?)
    /// A file reached the Cloudreve server.
    case cloudUploaded(target: String)

    var id: String {
        switch self {
        case .reminder(let item): return "reminder-\(item.id)"
        case .countdownFinished: return "countdown"
        case .screenshotCopied: return "screenshot"
        case .cloudUploaded: return "cloud-upload"
        }
    }

    /// Confirmations that need no answer: they jump the queue and leave by themselves.
    var isTransient: Bool {
        switch self {
        case .screenshotCopied, .cloudUploaded: return true
        case .reminder, .countdownFinished: return false
        }
    }
}

@MainActor
final class NotchAlertCenter: ObservableObject {
    static let shared = NotchAlertCenter()

    /// Pending alerts, oldest first; only the first one is on screen.
    @Published private(set) var queue: [NotchAlert] = [] {
        didSet {
            // Also when the front alert changes in place (an upload finishing).
            if queue.first != oldValue.first { scheduleAutoHide() }
        }
    }

    var current: NotchAlert? { queue.first }

    private var autoHideTask: Task<Void, Never>?
    private var isHeld = false

    private init() {}

    func post(_ alert: NotchAlert) {
        if alert.isTransient {
            // A confirmation is about what just happened: it jumps the queue,
            // replaces an older one, and whatever it interrupted comes back after.
            withAnimation(CountdownTimerManager.peekAnimation) {
                queue.removeAll { $0.id == alert.id }
                queue.insert(alert, at: 0)
            }
            return
        }
        guard !queue.contains(where: { $0.id == alert.id }) else { return }
        withAnimation(CountdownTimerManager.peekAnimation) {
            queue.append(alert)
        }
    }

    /// Removes an alert without acting on it, e.g. when its source went away.
    func withdraw(id: String) {
        guard queue.contains(where: { $0.id == id }) else { return }
        withAnimation(CountdownTimerManager.peekAnimation) {
            queue.removeAll { $0.id == id }
        }
    }

    /// Keeps the current alert up while the pointer is on it.
    func hold() {
        isHeld = true
        autoHideTask?.cancel()
    }

    func release() {
        isHeld = false
        scheduleAutoHide()
    }

    /// A reminder alert is a heads-up: it slides away on its own after a few
    /// seconds and the reminder stays in the Timers tab. A screenshot
    /// confirmation goes even sooner. A finished countdown waits for an answer.
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard !isHeld, let alert = current else { return }
        let seconds: Double
        switch alert {
        case .reminder: seconds = Double(max(3, Defaults[.reminderAlertSeconds]))
        case .screenshotCopied(_, _, let upload):
            switch upload {
            case .uploading?: seconds = 20 // safety net; the upload reports back long before
            case .failed?: seconds = 3.5
            default: seconds = 2.2
            }
        case .cloudUploaded: seconds = 2.2
        case .countdownFinished: return
        }
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.current?.id == alert.id else { return }
            withAnimation(CountdownTimerManager.peekAnimation) {
                _ = self.queue.removeFirst()
            }
        }
    }

    /// "Tamam": a reminder is marked completed, a finished countdown is cleared.
    func confirm() {
        guard let alert = current else { return }
        withAnimation(CountdownTimerManager.peekAnimation) {
            _ = queue.removeFirst()
        }
        switch alert {
        case .reminder(let item):
            ReminderManager.shared.setCompleted(item)
        case .countdownFinished:
            CountdownTimerManager.shared.reset()
        case .screenshotCopied, .cloudUploaded:
            break
        }
    }

    /// Secondary action: snooze a reminder, or run the countdown again.
    func secondary() {
        guard let alert = current else { return }
        withAnimation(CountdownTimerManager.peekAnimation) {
            _ = queue.removeFirst()
        }
        switch alert {
        case .reminder(let item):
            let minutes = max(1, Defaults[.reminderSnoozeMinutes])
            ReminderManager.shared.snooze(item, minutes: minutes)
        case .countdownFinished(let duration):
            CountdownTimerManager.shared.start(duration: duration)
        case .screenshotCopied, .cloudUploaded:
            break
        }
    }
}
