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

enum NotchAlert: Identifiable, Equatable {
    case reminder(ReminderItem)
    case countdownFinished(duration: TimeInterval)

    var id: String {
        switch self {
        case .reminder(let item): return "reminder-\(item.id)"
        case .countdownFinished: return "countdown"
        }
    }
}

@MainActor
final class NotchAlertCenter: ObservableObject {
    static let shared = NotchAlertCenter()

    /// Pending alerts, oldest first; only the first one is on screen.
    @Published private(set) var queue: [NotchAlert] = [] {
        didSet {
            if queue.first?.id != oldValue.first?.id { scheduleAutoHide() }
        }
    }

    var current: NotchAlert? { queue.first }

    private var autoHideTask: Task<Void, Never>?
    private var isHeld = false

    private init() {}

    func post(_ alert: NotchAlert) {
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
    /// seconds and the reminder stays in the Timers tab. A finished countdown
    /// waits for an answer.
    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard !isHeld, let alert = current, case .reminder = alert else { return }
        let seconds = max(3, Defaults[.reminderAlertSeconds])
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
        }
    }
}
