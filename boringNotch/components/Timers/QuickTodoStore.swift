//
//  QuickTodoStore.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Quick Todo: small projects, each with its own checklist. Stored locally
//  as JSON in Application Support — nothing leaves this Mac.
//

import Defaults
import Foundation

enum TodoStatus: String, Codable, CaseIterable, Identifiable {
    case backlog
    case planned
    case inProgress
    case completed
    case canceled

    var id: Self { self }

    var title: String {
        switch self {
        case .backlog: String(localized: "Backlog")
        case .planned: String(localized: "Planned")
        case .inProgress: String(localized: "In Progress")
        case .completed: String(localized: "Completed")
        case .canceled: String(localized: "Canceled")
        }
    }

    /// Finished one way or the other — shown struck through at the bottom.
    var isClosed: Bool { self == .completed || self == .canceled }

    /// Order in the list: work in motion first, closed items last.
    var sortRank: Int {
        switch self {
        case .inProgress: 0
        case .planned: 1
        case .backlog: 2
        case .completed: 3
        case .canceled: 4
        }
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    /// Kept for files written before statuses existed; mirrors `.completed`.
    var isDone = false
    var createdAt = Date.now
    var completedAt: Date?
    /// nil in older files — see `state`.
    var status: TodoStatus?

    var state: TodoStatus {
        status ?? (isDone ? .completed : .backlog)
    }
}

struct TodoProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date.now
    var items: [TodoItem] = []

    var doneCount: Int { items.filter { $0.state == .completed }.count }

    /// Items that count toward progress — canceled ones don't.
    var countedItems: Int { items.filter { $0.state != .canceled }.count }

    var progress: Double {
        countedItems == 0 ? 0 : Double(doneCount) / Double(countedItems)
    }

    /// In progress, planned, backlog (each in the order added), then completed
    /// and canceled (most recently closed first).
    var sortedItems: [TodoItem] {
        items.sorted { lhs, rhs in
            if lhs.state.sortRank != rhs.state.sortRank {
                return lhs.state.sortRank < rhs.state.sortRank
            }
            if lhs.state.isClosed {
                return (lhs.completedAt ?? .distantPast) > (rhs.completedAt ?? .distantPast)
            }
            return lhs.createdAt < rhs.createdAt
        }
    }
}

@MainActor
final class QuickTodoStore: ObservableObject {
    static let shared = QuickTodoStore()

    @Published private(set) var projects: [TodoProject] = []
    @Published var selectedProjectID: UUID? {
        didSet { Defaults[.quickTodoSelectedProject] = selectedProjectID?.uuidString ?? "" }
    }

    var selectedProject: TodoProject? {
        projects.first { $0.id == selectedProjectID }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = support.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("QuickTodo.json")
        load()
        let savedID = UUID(uuidString: Defaults[.quickTodoSelectedProject])
        selectedProjectID = projects.contains { $0.id == savedID } ? savedID : projects.first?.id
    }

    // MARK: - Projects

    @discardableResult
    func addProject(named name: String) -> TodoProject? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = TodoProject(name: trimmed)
        projects.append(project)
        selectedProjectID = project.id
        save()
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    func deleteProject(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects.remove(at: index)
        if selectedProjectID == id {
            let neighbour = min(index, projects.count - 1)
            selectedProjectID = projects.indices.contains(neighbour) ? projects[neighbour].id : nil
        }
        save()
    }

    // MARK: - Items

    func addItem(_ title: String, to projectID: UUID) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(projectID) { $0.items.append(TodoItem(title: trimmed)) }
    }

    func setStatus(_ status: TodoStatus, for itemID: UUID, in projectID: UUID) {
        update(projectID) { project in
            guard let index = project.items.firstIndex(where: { $0.id == itemID }) else { return }
            project.items[index].status = status
            project.items[index].isDone = status == .completed
            project.items[index].completedAt = status.isClosed ? .now : nil
        }
    }

    func deleteItem(_ itemID: UUID, in projectID: UUID) {
        update(projectID) { $0.items.removeAll { $0.id == itemID } }
    }

    func clearCompleted(in projectID: UUID) {
        update(projectID) { $0.items.removeAll { $0.state.isClosed } }
    }

    // MARK: - Persistence

    private func update(_ id: UUID, _ change: (inout TodoProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[index])
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            projects = try decoder.decode([TodoProject].self, from: data)
        } catch {
            Log.timers.error("Quick Todo file could not be read: \(error.localizedDescription, privacy: .public)")
            // Keep the unreadable file instead of overwriting it on the next save.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    /// Coalesces bursts of edits into one write.
    private func save() {
        saveTask?.cancel()
        let snapshot = projects
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                Log.timers.error("Saving Quick Todo failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
