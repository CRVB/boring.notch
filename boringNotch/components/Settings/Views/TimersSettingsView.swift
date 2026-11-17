//
//  TimersSettingsView.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import EventKit
import SwiftUI

struct TimersSettingsView: View {
    @ObservedObject private var reminders = ReminderManager.shared
    @Default(.timersEnabled) private var timersEnabled
    @Default(.countdownPresets) private var presets
    @Default(.reminderTargetListID) private var targetListID
    @Default(.remindersShowUndated) private var showUndated
    @Default(.reminderSnoozeMinutes) private var snoozeMinutes
    @Default(.countdownPeekMode) private var peekMode
    @Default(.reminderAlertSeconds) private var alertSeconds

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .timersEnabled) {
                    Text("Show Timers tab")
                }
                Picker("Countdown under the closed notch", selection: $peekMode) {
                    Text("Key moments").tag(CountdownPeekMode.keyMoments)
                    Text("Always").tag(CountdownPeekMode.always)
                    Text("Never").tag(CountdownPeekMode.never)
                }
                Defaults.Toggle(key: .notchAlertsEnabled) {
                    Text("Show reminder and countdown alerts in the notch")
                }
                Defaults.Toggle(key: .tabSwipeEnabled) {
                    Text("Swipe with two fingers to switch tabs")
                }
                Defaults.Toggle(key: .screenshotButtonInNotch) {
                    Text("Show screenshot-to-clipboard button in the notch")
                }
            } footer: {
                Text("Adds a tab with a countdown timer and your Apple Reminders to the open notch. Key moments shows the countdown when it starts, at one minute left and during the last ten seconds.")
            }

            Section {
                Defaults.Toggle(key: .quickTodoEnabled) {
                    Text("Show Quick Todo tab")
                }
            } header: {
                Text("Quick Todo")
            } footer: {
                Text("Projects with their own checklists. Stored only on this Mac.")
            }

            Section {
                ForEach(0..<3, id: \.self) { index in
                    Stepper(value: presetBinding(index), in: 1...720) {
                        HStack {
                            Text("Preset \(index + 1)")
                            Spacer()
                            Text("\(presetBinding(index).wrappedValue) min")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                Defaults.Toggle(key: .countdownPlaySound) {
                    Text("Play a sound when the countdown ends")
                }
            } header: {
                Text("Countdown")
            }
            .disabled(!timersEnabled)

            Section {
                if reminders.hasAccess {
                    Picker("Add new reminders to", selection: $targetListID) {
                        Text("Default list").tag("")
                        ForEach(reminders.lists) { list in
                            Text(list.title).tag(list.id)
                        }
                    }
                    Stepper(value: $alertSeconds, in: 3...60) {
                        HStack {
                            Text("Show due reminders for")
                            Spacer()
                            Text("\(alertSeconds) s")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $snoozeMinutes, in: 1...120) {
                        HStack {
                            Text("Snooze for")
                            Spacer()
                            Text("\(snoozeMinutes) min")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Defaults.Toggle(key: .remindersAddAlarm) {
                        Text("Alert at the due time")
                    }
                    Defaults.Toggle(key: .remindersShowUndated) {
                        Text("Show reminders without a due date")
                    }
                } else if reminders.authorizationStatus == .notDetermined {
                    Button("Allow Reminders Access") {
                        Task { await reminders.requestAccess() }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reminder access is denied. Please enable it in System Settings.")
                            .foregroundStyle(.red)
                        Button("Open Reminder Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Reminders are read from and saved to the Reminders app, so they sync with your other devices.")
            }
            .disabled(!timersEnabled)
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Timers")
        .onAppear {
            Task { await reminders.reload() }
        }
        .onChange(of: showUndated) { _, _ in
            Task { await reminders.reload() }
        }
    }

    private func presetBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { presets.indices.contains(index) ? presets[index] : 5 },
            set: { newValue in
                var updated = presets
                while updated.count <= index { updated.append(5) }
                updated[index] = newValue
                presets = updated
            }
        )
    }
}
