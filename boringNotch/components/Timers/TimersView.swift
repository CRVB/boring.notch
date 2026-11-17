//
//  TimersView.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Timers tab: a countdown on the left, Apple Reminders on the right.
//

import Defaults
import SwiftUI

struct TimersView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CountdownPanel()
                .frame(width: 250)
            RemindersPanel()
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Countdown

private struct CountdownPanel: View {
    @ObservedObject private var timer = CountdownTimerManager.shared
    @Default(.countdownPresets) private var presets

    var body: some View {
        TimelineView(.periodic(from: .now, by: timer.isRunning ? 0.25 : 60)) { context in
            HStack(spacing: 14) {
                ring(at: context.date)
                VStack(alignment: .leading, spacing: 8) {
                    presetRow
                    controls
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func ring(at date: Date) -> some View {
        let progress = timer.state == .idle ? 1 : timer.progress(at: date)
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            VStack(spacing: 0) {
                Text(timer.remaining(at: date).countdownString)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                Text(statusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.gray)
            }
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle())
        .onTapGesture { timer.toggle() }
        .help("Click to start or pause")
    }

    private var ringColor: Color {
        switch timer.state {
        case .finished: return .orange
        case .paused: return .gray
        default: return .effectiveAccent
        }
    }

    private var statusText: LocalizedStringKey {
        switch timer.state {
        case .idle: return "Ready"
        case .running: return "Running"
        case .paused: return "Paused"
        case .finished: return "Done"
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets.prefix(3), id: \.self) { minutes in
                Button {
                    timer.start(duration: TimeInterval(minutes * 60))
                } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(minWidth: 34, minHeight: 22)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            CircleIconButton(systemName: "minus", help: "Remove 1 minute") {
                timer.adjust(by: -60)
            }
            CircleIconButton(
                systemName: timer.isRunning ? "pause.fill" : "play.fill",
                prominent: true,
                help: timer.isRunning ? "Pause" : "Start"
            ) {
                timer.toggle()
            }
            CircleIconButton(systemName: "plus", help: "Add 1 minute") {
                timer.adjust(by: 60)
            }
            CircleIconButton(systemName: "arrow.counterclockwise", help: "Reset") {
                timer.reset()
            }
            .opacity(timer.state == .idle ? 0.35 : 1)
            .disabled(timer.state == .idle)
        }
    }
}

private struct CircleIconButton: View {
    let systemName: String
    var prominent = false
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: prominent ? 12 : 10, weight: .bold))
                .frame(width: prominent ? 30 : 24, height: prominent ? 30 : 24)
                .background(Circle().fill(prominent ? Color.effectiveAccent : Color.white.opacity(0.1)))
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Reminders

private enum QuickDue: String, CaseIterable, Identifiable {
    case none, in15Minutes, in1Hour, tonight, tomorrowMorning

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .none: "No date"
        case .in15Minutes: "In 15 minutes"
        case .in1Hour: "In 1 hour"
        case .tonight: "Tonight at 20:00"
        case .tomorrowMorning: "Tomorrow at 09:00"
        }
    }

    var icon: String {
        self == .none ? "calendar.badge.plus" : "alarm"
    }

    func date(from now: Date = .now) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .none: return nil
        case .in15Minutes: return now.addingTimeInterval(15 * 60)
        case .in1Hour: return now.addingTimeInterval(60 * 60)
        case .tonight:
            let tonight = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
            return tonight > now ? tonight : calendar.date(byAdding: .day, value: 1, to: tonight)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
    }
}

private struct RemindersPanel: View {
    @ObservedObject private var manager = ReminderManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if manager.hasAccess {
                list
                QuickAddField()
            } else {
                accessPrompt
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            Task { await manager.reload() }
        }
    }

    private var header: some View {
        HStack {
            Text("Reminders")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            if manager.hasAccess && !manager.reminders.isEmpty {
                Text("\(manager.reminders.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
            }
            Spacer()
            Button {
                manager.openInRemindersApp()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            .help("Open Reminders")
        }
    }

    @ViewBuilder
    private var list: some View {
        if manager.reminders.isEmpty {
            Text(manager.isLoading ? "Loading…" : "Nothing to do 🎉")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.reminders) { item in
                        ReminderRow(item: item) {
                            withAnimation(.smooth) {
                                manager.setCompleted(item)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var accessPrompt: some View {
        VStack(spacing: 6) {
            Text("Allow access to show and add reminders.")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            Button("Allow Reminders Access") {
                Task { await manager.requestAccess() }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReminderRow: View {
    let item: ReminderItem
    let onComplete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onComplete) {
                Image(systemName: isHovering ? "checkmark.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(listColor)
            }
            .buttonStyle(.plain)
            .help("Mark as completed")

            Text(item.title)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let due = item.dueDate {
                Text(dueText(due))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(item.isOverdue ? Color.red : Color.gray)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var listColor: Color {
        item.color.map { Color(cgColor: $0) } ?? .gray
    }

    private func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = item.hasTime ? date.formatted(date: .omitted, time: .shortened) : nil
        if calendar.isDateInToday(date) {
            return time ?? String(localized: "Today")
        }
        if calendar.isDateInTomorrow(date) {
            let tomorrow = String(localized: "Tomorrow")
            return time.map { "\(tomorrow) \($0)" } ?? tomorrow
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Text field for new reminders, with a quick due-date menu.
private struct QuickAddField: View {
    @ObservedObject private var manager = ReminderManager.shared
    @State private var text = ""
    @State private var due: QuickDue = .none

    var body: some View {
        NotchTextInput(placeholder: "New reminder", text: $text, onSubmit: submit) {
            Menu {
                Picker("Due", selection: $due) {
                    ForEach(QuickDue.allCases) { option in
                        Label(option.title, systemImage: option.icon).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: due.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(due == .none ? Color.gray : Color.effectiveAccent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Due date")
        }
    }

    private func submit() {
        if manager.addReminder(title: text, dueDate: due.date()) {
            text = ""
            due = .none
        }
    }
}
