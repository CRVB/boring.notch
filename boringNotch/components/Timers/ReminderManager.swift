//
//  ReminderManager.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Reads and writes Apple Reminders for the Timers tab. Reminders created
//  here live in the Reminders app, so they sync to the user's other devices.
//

@preconcurrency import AppKit
import Defaults
@preconcurrency import EventKit
import Foundation

struct ReminderItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let dueDate: Date?
    let hasTime: Bool
    let isCompleted: Bool
    let listTitle: String
    let color: CGColor?

    var isOverdue: Bool {
        guard let dueDate, !isCompleted else { return false }
        return dueDate < .now
    }
}

struct ReminderListItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let color: CGColor?
}

@MainActor
final class ReminderManager: ObservableObject {
    static let shared = ReminderManager()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var reminders: [ReminderItem] = []
    @Published private(set) var lists: [ReminderListItem] = []
    @Published private(set) var isLoading = false

    /// How many open reminders the notch shows at most.
    static let displayLimit = 30

    private let store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    /// Every open reminder, unlimited — the due-date watcher needs all of them.
    private var allItems: [ReminderItem] = []
    /// Reminders that came due before this moment have already been handled
    /// (or were overdue before the app started), so they never alert again.
    private var dueCheckedUntil = Date.now
    private var dueTask: Task<Void, Never>?

    var hasAccess: Bool {
        authorizationStatus == .fullAccess
    }

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
        if hasAccess {
            Task { await reload() }
        }
    }

    // MARK: - Access

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            Log.timers.error("Reminder access request failed: \(error.localizedDescription, privacy: .public)")
        }
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        await reload()
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - Reading

    func reload() async {
        refreshAuthorizationStatus()
        guard hasAccess else {
            reminders = []
            lists = []
            return
        }
        isLoading = true
        defer { isLoading = false }

        let calendars = store.calendars(for: .reminder)
        lists = calendars
            .map { ReminderListItem(id: $0.calendarIdentifier, title: $0.title, color: $0.cgColor) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let showUndated = Defaults[.remindersShowUndated]
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: calendars)
        let items: [ReminderItem] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).compactMap { reminder -> ReminderItem? in
                    let components = reminder.dueDateComponents
                    let due = components.flatMap { Calendar.current.date(from: $0) }
                    if due == nil && !showUndated { return nil }
                    return ReminderItem(
                        id: reminder.calendarItemIdentifier,
                        title: reminder.title ?? "",
                        dueDate: due,
                        hasTime: components?.hour != nil,
                        isCompleted: reminder.isCompleted,
                        listTitle: reminder.calendar?.title ?? "",
                        color: reminder.calendar?.cgColor
                    )
                }
                continuation.resume(returning: mapped)
            }
        }

        allItems = items
        // A reminder completed or deleted elsewhere shouldn't keep asking for "Done".
        let openIDs = Set(items.map(\.id))
        for case .reminder(let item) in NotchAlertCenter.shared.queue where !openIDs.contains(item.id) {
            NotchAlertCenter.shared.withdraw(id: NotchAlert.reminder(item).id)
        }
        reminders = Array(items.sorted(by: Self.displayOrder).prefix(Self.displayLimit))
        scheduleDueCheck()
    }

    // MARK: - Due alerts

    /// Sleeps until the next timed reminder comes due, then raises a notch alert.
    private func scheduleDueCheck() {
        dueTask?.cancel()
        guard Defaults[.notchAlertsEnabled] else { return }
        let next = allItems
            .filter { $0.hasTime }
            .compactMap(\.dueDate)
            .filter { $0 > dueCheckedUntil }
            .min()
        guard let next else { return }
        dueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.raiseDueAlerts()
        }
    }

    private func raiseDueAlerts() {
        let now = Date.now
        let due = allItems.filter { item in
            guard item.hasTime, let date = item.dueDate else { return false }
            return date > dueCheckedUntil && date <= now
        }
        dueCheckedUntil = now
        for item in due.sorted(by: Self.displayOrder) {
            NotchAlertCenter.shared.post(.reminder(item))
        }
        scheduleDueCheck()
    }

    /// Dated reminders first (soonest first), then undated ones alphabetically.
    private nonisolated static func displayOrder(_ lhs: ReminderItem, _ rhs: ReminderItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (l?, r?): return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: - Writing

    @discardableResult
    func addReminder(title: String, dueDate: Date?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAccess, !trimmed.isEmpty else { return false }
        guard let calendar = targetCalendar() else {
            Log.timers.error("No Reminders list available for new reminder")
            return false
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = trimmed
        reminder.calendar = calendar
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
            if Defaults[.remindersAddAlarm] {
                reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            }
        }

        do {
            try store.save(reminder, commit: true)
            scheduleReload()
            return true
        } catch {
            Log.timers.error("Saving reminder failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setCompleted(_ item: ReminderItem, completed: Bool = true) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
            // Drop it right away so the row doesn't linger until the store notifies us.
            if completed {
                reminders.removeAll { $0.id == item.id }
            }
            scheduleReload()
        } catch {
            Log.timers.error("Updating reminder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pushes the due date (and alarm) forward so the reminder comes back later.
    func snooze(_ item: ReminderItem, minutes: Int) {
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        let newDue = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: newDue)
        reminder.alarms?.forEach { reminder.removeAlarm($0) }
        if Defaults[.remindersAddAlarm] {
            reminder.addAlarm(EKAlarm(absoluteDate: newDue))
        }
        do {
            try store.save(reminder, commit: true)
            scheduleReload()
        } catch {
            Log.timers.error("Snoozing reminder failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openInRemindersApp() {
        if let url = URL(string: "x-apple-reminderkit://") {
            NSWorkspace.shared.open(url)
        }
    }

    private func targetCalendar() -> EKCalendar? {
        let targetID = Defaults[.reminderTargetListID]
        if !targetID.isEmpty, let calendar = store.calendar(withIdentifier: targetID) {
            return calendar
        }
        return store.defaultCalendarForNewReminders()
    }
}
