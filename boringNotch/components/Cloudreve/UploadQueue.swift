//
//  UploadQueue.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A persistent upload queue. Every job owns a private copy of its file, so
//  deleting the item from the Shelf (or macOS clearing temporary files) never
//  loses an upload that is still waiting. Jobs survive quitting the app, wait
//  while the Mac is offline or the server is unreachable, and go out as soon
//  as the connection is back.
//

import AppKit
import Foundation
import Network

enum UploadKind: String, Codable {
    /// A file, folder, link or text sent through the Shelf's Quick Share tile.
    case file
    /// A screenshot taken with the notch's screenshot button.
    case screenshot
}

/// What came of the first attempt to send a job.
enum UploadOutcome {
    case uploaded
    case failed
    case cancelled
}

struct UploadJob: Codable, Identifiable, Equatable {
    let id: UUID
    let fileName: String
    /// Remote folder, e.g. "/Screenshots".
    let folder: String
    let size: Int64
    let createdAt: Date
    var kind: UploadKind
    /// The Shelf item a screenshot was put on, so cancelling can remove it too.
    var shelfItemID: UUID?
    var attempts = 0
    var nextAttempt = Date.distantPast
    var lastError: String?

    init(
        id: UUID = UUID(), fileName: String, folder: String, size: Int64 = 0, createdAt: Date = .now,
        kind: UploadKind = .file, shelfItemID: UUID? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.folder = folder
        self.size = size
        self.createdAt = createdAt
        self.kind = kind
        self.shelfItemID = shelfItemID
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, folder, size, createdAt, kind, shelfItemID, attempts, nextAttempt, lastError
    }

    /// Queue files written before screenshots had their own list have no `kind`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        folder = try container.decode(String.self, forKey: .folder)
        size = try container.decode(Int64.self, forKey: .size)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(UploadKind.self, forKey: .kind) ?? .file
        shelfItemID = try container.decodeIfPresent(UUID.self, forKey: .shelfItemID)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        nextAttempt = try container.decodeIfPresent(Date.self, forKey: .nextAttempt) ?? .distantPast
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// Lets the timer tell the worker that the attempt was cut short.
@MainActor
private final class TimeoutFlag {
    var fired = false
}

@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    @Published private(set) var jobs: [UploadJob] = []
    @Published private(set) var isUploading = false
    /// The job being sent right now.
    @Published private(set) var currentJobID: UUID?
    @Published private(set) var isOnline = true
    @Published private(set) var lastSuccess: Date?

    private let root: URL
    private var queueFile: URL { root.appendingPathComponent("queue.json") }
    private var worker: Task<Void, Never>?
    /// The transfer of `currentJobID`; cancelling it stops that upload.
    private var uploadTask: Task<Void, Error>?
    /// Who wants to hear how a job's first attempt went (the screenshot toast).
    private var outcomeHandlers: [UUID: @MainActor (UploadOutcome) -> Void] = [:]

    /// A screenshot's first attempt gives up after this many seconds; the job then
    /// stays queued and is retried later.
    private static let firstAttemptTimeout: TimeInterval = 10
    /// If a job's turn doesn't even come this soon (another upload in the way), report failure too.
    private static let outcomeDeadline: TimeInterval = 14
    private var wakeTask: Task<Void, Never>?
    /// Remote folders already confirmed this session.
    private var ensuredFolders: Set<String> = []
    private let monitor = NWPathMonitor()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = support.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("CloudreveQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()

        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "littleboringnotch.uploadqueue.network", qos: .utility))
        kick()
    }

    // MARK: - Public

    var pendingCount: Int { jobs.count }
    var failedCount: Int { jobs.filter { $0.lastError != nil }.count }

    /// Adds a copy of `fileURL` to the queue.
    @discardableResult
    func enqueue(fileURL: URL, name: String? = nil, folder: String) -> Bool {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        return add(name: name ?? fileURL.lastPathComponent, folder: folder, kind: .file, shelfItemID: nil, onOutcome: nil) { destination in
            try FileManager.default.copyItem(at: fileURL, to: destination)
        }
    }

    @discardableResult
    func enqueue(
        data: Data, name: String, folder: String, kind: UploadKind = .file, shelfItemID: UUID? = nil,
        onOutcome: (@MainActor (UploadOutcome) -> Void)? = nil
    ) -> Bool {
        add(name: name, folder: folder, kind: kind, shelfItemID: shelfItemID, onOutcome: onOutcome) { destination in
            try data.write(to: destination, options: .atomic)
        }
    }

    func jobs(of kind: UploadKind) -> [UploadJob] {
        jobs.filter { $0.kind == kind }
    }

    /// Tries everything again right now.
    func retryNow() {
        for index in jobs.indices { jobs[index].nextAttempt = .distantPast }
        save()
        kick()
    }

    /// Call after the server, user or password changed.
    func configurationChanged() {
        ensuredFolders.removeAll()
        retryNow()
    }

    /// Cancels a waiting or running upload. The queue's copy of the file is deleted;
    /// for a screenshot that also removes it from the Shelf, so nothing of it is left on this Mac
    /// (the clipboard copy stays — it isn't ours to take back).
    func cancel(_ job: UploadJob) {
        guard let queued = jobs.first(where: { $0.id == job.id }) else { return }
        if currentJobID == queued.id { uploadTask?.cancel() }
        discard(queued)
        save()
        report(queued.id, .cancelled)
        if queued.kind == .screenshot, let shelfID = queued.shelfItemID,
           let item = ShelfStateViewModel.shared.items.first(where: { $0.id == shelfID }) {
            ShelfActionService.remove(item)
        }
    }

    // MARK: - Queue storage

    private func directory(for job: UploadJob) -> URL {
        root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(job.id.uuidString, isDirectory: true)
    }

    private func fileURL(for job: UploadJob) -> URL {
        directory(for: job).appendingPathComponent(job.fileName)
    }

    private func add(
        name: String, folder: String, kind: UploadKind, shelfItemID: UUID?,
        onOutcome: (@MainActor (UploadOutcome) -> Void)?, store: (URL) throws -> Void
    ) -> Bool {
        let fileName = Self.sanitized(name)
        let job = UploadJob(
            fileName: fileName, folder: Self.normalizedFolder(folder), kind: kind, shelfItemID: shelfItemID)
        let directory = directory(for: job)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try store(directory.appendingPathComponent(fileName))
        } catch {
            Log.shelf.error("Upload queue could not store \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: directory)
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(fileName).path)[.size] as? Int64) ?? 0
        jobs.append(UploadJob(
            id: job.id, fileName: fileName, folder: job.folder, size: size ?? 0, createdAt: job.createdAt,
            kind: kind, shelfItemID: shelfItemID))
        save()
        if let onOutcome {
            watch(job.id, onOutcome)
        }
        kick()
        return true
    }

    /// Reports how the first attempt at `id` went — success, failure, or cancelled.
    /// Offline, or a turn that doesn't come in time, counts as a failure right away
    /// (the job itself stays queued and goes out later).
    private func watch(_ id: UUID, _ handler: @escaping @MainActor (UploadOutcome) -> Void) {
        outcomeHandlers[id] = handler
        if !isOnline {
            Task { @MainActor in self.report(id, .failed) }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.outcomeDeadline))
            self.report(id, .failed)
        }
    }

    private func report(_ id: UUID, _ outcome: UploadOutcome) {
        outcomeHandlers.removeValue(forKey: id)?(outcome)
    }

    private func discard(_ job: UploadJob) {
        try? FileManager.default.removeItem(at: directory(for: job))
        jobs.removeAll { $0.id == job.id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: queueFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([UploadJob].self, from: data) else {
            // Keep an unreadable queue file instead of overwriting it.
            try? FileManager.default.moveItem(at: queueFile, to: root.appendingPathComponent("queue.broken.json"))
            return
        }
        // A job whose file is gone can't be uploaded any more.
        jobs = stored.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(jobs).write(to: queueFile, options: .atomic)
        } catch {
            Log.shelf.error("Upload queue could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Worker

    private func networkChanged(online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack {
            // Back online: don't make jobs wait out their backoff.
            for index in jobs.indices { jobs[index].nextAttempt = .distantPast }
            save()
        }
        if online { kick() }
    }

    private func kick() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.run()
            self?.worker = nil
        }
    }

    private func run() async {
        wakeTask?.cancel()
        while !Task.isCancelled {
            guard isOnline else { return }
            let config = CloudreveConfig.current()
            guard config.isConfigured, let client = config.client else { return }

            guard let job = jobs.first(where: { $0.nextAttempt <= .now }) else {
                scheduleWake()
                return
            }

            isUploading = true
            currentJobID = job.id
            let transfer = Task { try await self.upload(job, with: client) }
            uploadTask = transfer

            // A screenshot's first attempt is on a short leash: the toast is waiting for it.
            let timeout = TimeoutFlag()
            let limiter: Task<Void, Never>? = (job.kind == .screenshot && job.attempts == 0)
                ? Task {
                    try? await Task.sleep(for: .seconds(Self.firstAttemptTimeout))
                    guard !Task.isCancelled else { return }
                    timeout.fired = true
                    transfer.cancel()
                }
                : nil
            do {
                try await transfer.value
                limiter?.cancel()
                if jobs.contains(where: { $0.id == job.id }) {
                    discard(job)
                    lastSuccess = .now
                    save()
                    if outcomeHandlers[job.id] != nil {
                        // The waiting toast says it itself.
                        report(job.id, .uploaded)
                    } else {
                        NotchAlertCenter.shared.post(.cloudUploaded(target: config.displayName))
                    }
                }
            } catch {
                limiter?.cancel()
                // A cancelled job is already gone from the queue; fail() ignores it.
                fail(job, error: timeout.fired ? WebDAVClient.Failure.timeout : error)
                if jobs.contains(where: { $0.id == job.id }) { report(job.id, .failed) }
            }
            uploadTask = nil
            currentJobID = nil
            isUploading = false
        }
    }

    private func upload(_ job: UploadJob, with client: WebDAVClient) async throws {
        let local = fileURL(for: job)
        guard FileManager.default.fileExists(atPath: local.path) else {
            // Nothing left to send.
            throw CancellationError()
        }
        if !ensuredFolders.contains(job.folder) {
            try await client.ensureFolder(job.folder)
            ensuredFolders.insert(job.folder)
        }
        let remoteName = try await freeName(for: job.fileName, in: job.folder, client: client)
        try await client.upload(file: local, to: "\(job.folder)/\(remoteName)")
    }

    /// "photo.png" → "photo (2).png" when the name is taken, so nothing gets overwritten.
    private func freeName(for name: String, in folder: String, client: WebDAVClient) async throws -> String {
        if try await !client.exists("\(folder)/\(name)") { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 2...99 {
            let candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            if try await !client.exists("\(folder)/\(candidate)") { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    private func fail(_ job: UploadJob, error: Error) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        if error is CancellationError {
            discard(job)
            save()
            return
        }
        jobs[index].attempts += 1
        jobs[index].lastError = error.localizedDescription
        let authentication = (error as? WebDAVClient.Failure)?.isAuthentication ?? false
        let delay = authentication ? 600 : min(900.0, 5 * pow(2, Double(jobs[index].attempts - 1)))
        jobs[index].nextAttempt = Date.now.addingTimeInterval(delay)
        Log.shelf.error("Upload of \(job.fileName, privacy: .public) failed (attempt \(self.jobs[index].attempts)): \(error.localizedDescription, privacy: .public)")
        save()
    }

    /// Wakes the worker when the earliest waiting job is due.
    private func scheduleWake() {
        guard let next = jobs.map(\.nextAttempt).min() else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.kick()
        }
    }

    // MARK: - Names

    static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "file" : cleaned
    }

    static func normalizedFolder(_ folder: String) -> String {
        let parts = folder.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return "/" + parts.joined(separator: "/")
    }
}
