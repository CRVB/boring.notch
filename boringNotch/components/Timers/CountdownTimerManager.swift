//
//  CountdownTimerManager.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A single countdown timer shared by every notch window. The timer is
//  modelled as an end date (while running) or a remaining interval (while
//  paused), so it never drifts and survives the notch closing.
//

import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

@MainActor
final class CountdownTimerManager: ObservableObject {
    static let shared = CountdownTimerManager()

    enum State: Equatable {
        case idle
        case running(endDate: Date)
        case paused(remaining: TimeInterval)
        case finished
    }

    /// Longest countdown the UI lets you dial in.
    static let maximumDuration: TimeInterval = 24 * 60 * 60

    @Published private(set) var state: State = .idle
    /// Duration the dial is set to while idle, and the length of the current run otherwise.
    @Published private(set) var duration: TimeInterval

    /// Whether the countdown row under the closed notch should be showing right now.
    @Published private(set) var peekVisible = false

    private var finishTask: Task<Void, Never>?
    /// Re-evaluates the peek and backs up the finish deadline while a countdown is active.
    private var ticker: Task<Void, Never>?
    /// Keeps App Nap from stretching the deadline while the app sits in the background.
    private var activity: NSObjectProtocol?
    /// Last start / pause / resume / adjust — each one briefly shows the peek.
    private var lastEventDate = Date.distantPast

    /// How long the peek stays up after an interaction, and around the one-minute mark.
    private static let eventPeekDuration: TimeInterval = 4
    private static let finalPeekSeconds: TimeInterval = 10
    /// Shared by the countdown row and the "Time's up" alert, so one hands over to the other smoothly.
    static let peekAnimation: Animation = .smooth(duration: 0.45)

    private init() {
        duration = TimeInterval(max(60, Defaults[.countdownLastDuration]))
    }

    // MARK: - Derived values

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    var isActive: Bool {
        switch state {
        case .running, .paused: return true
        case .idle, .finished: return false
        }
    }

    func remaining(at date: Date = .now) -> TimeInterval {
        switch state {
        case .idle: return duration
        case .running(let endDate): return max(0, endDate.timeIntervalSince(date))
        case .paused(let remaining): return remaining
        case .finished: return 0
        }
    }

    /// Fraction of the run left, 1 → 0.
    func progress(at date: Date = .now) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, remaining(at: date) / duration))
    }

    // MARK: - Controls

    func setDuration(_ newValue: TimeInterval) {
        guard !isActive else { return }
        duration = min(Self.maximumDuration, max(60, newValue.rounded()))
        state = .idle
        Defaults[.countdownLastDuration] = Int(duration)
    }

    /// Adds (or with a negative value removes) time; works in every state.
    func adjust(by delta: TimeInterval) {
        switch state {
        case .idle, .finished:
            setDuration(duration + delta)
        case .running(let endDate):
            let remaining = endDate.timeIntervalSinceNow + delta
            guard remaining > 1 else { return }
            duration = max(duration + delta, remaining)
            schedule(endDate: endDate.addingTimeInterval(delta))
            noteEvent()
        case .paused(let remaining):
            let newRemaining = remaining + delta
            guard newRemaining > 1 else { return }
            duration = max(duration + delta, newRemaining)
            state = .paused(remaining: newRemaining)
            noteEvent()
        }
    }

    func start(duration newDuration: TimeInterval? = nil) {
        if let newDuration {
            duration = min(Self.maximumDuration, max(1, newDuration))
            Defaults[.countdownLastDuration] = Int(max(60, duration))
        }
        schedule(endDate: Date.now.addingTimeInterval(duration))
        noteEvent()
        Log.timers.debug("Countdown started for \(self.duration, privacy: .public)s")
    }

    func pause() {
        guard case .running(let endDate) = state else { return }
        finishTask?.cancel()
        state = .paused(remaining: max(0, endDate.timeIntervalSinceNow))
        noteEvent()
    }

    func resume() {
        guard case .paused(let remaining) = state else { return }
        schedule(endDate: Date.now.addingTimeInterval(remaining))
        noteEvent()
    }

    func toggle() {
        switch state {
        case .idle, .finished: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    func reset() {
        finishTask?.cancel()
        NotchAlertCenter.shared.withdraw(id: "countdown")
        state = .idle
        stopTicking()
    }

    // MARK: - Private

    private func schedule(endDate: Date) {
        finishTask?.cancel()
        NotchAlertCenter.shared.withdraw(id: "countdown")
        state = .running(endDate: endDate)
        finishTask = Task { [weak self] in
            // A tight tolerance: the default lets long sleeps run seconds late.
            let clock = ContinuousClock()
            let delay = max(0, endDate.timeIntervalSinceNow)
            try? await clock.sleep(until: clock.now.advanced(by: .seconds(delay)), tolerance: .milliseconds(20))
            guard !Task.isCancelled else { return }
            self?.finishIfDue()
        }
        startTicking()
    }

    private func finishIfDue(at now: Date = .now) {
        guard case .running(let endDate) = state, endDate <= now.addingTimeInterval(0.05) else { return }
        finish()
    }

    private func noteEvent() {
        lastEventDate = .now
        updatePeek()
    }

    private func startTicking() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Countdown timer running")
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                self.finishIfDue()
                self.updatePeek()
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        updatePeek()
    }

    /// Key-moment mode shows the row right after an interaction, for a few
    /// seconds at the one-minute mark, and through the final ten seconds.
    private func updatePeek(at now: Date = .now) {
        let visible: Bool
        if !isActive {
            visible = false
        } else {
            switch Defaults[.countdownPeekMode] {
            case .always:
                visible = true
            case .never:
                visible = false
            case .keyMoments:
                let left = remaining(at: now)
                let afterEvent = now.timeIntervalSince(lastEventDate) < Self.eventPeekDuration
                let oneMinuteMark = isRunning && duration > 75
                    && left <= 60 && left > 60 - Self.eventPeekDuration
                let finalSeconds = isRunning && left <= Self.finalPeekSeconds
                visible = afterEvent || oneMinuteMark || finalSeconds
            }
        }
        if visible != peekVisible {
            // Animated both ways, so the row slides away as smoothly as it arrives.
            withAnimation(Self.peekAnimation) {
                peekVisible = visible
            }
        }
    }

    private func finish() {
        finishTask?.cancel()
        // One animated transaction: the countdown row hands over to "Time's up".
        withAnimation(Self.peekAnimation) {
            finishNow()
        }
    }

    private func finishNow() {
        state = .finished
        stopTicking()
        Log.timers.debug("Countdown finished")
        if Defaults[.countdownPlaySound] {
            NSSound(named: "Glass")?.play()
        }
        if Defaults[.notchAlertsEnabled] {
            NotchAlertCenter.shared.post(.countdownFinished(duration: duration))
        }
    }
}

extension TimeInterval {
    /// "4:05", "1:02:09" — the countdown's clock face.
    var countdownString: String {
        let total = Int(self.rounded(.up))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
