import Foundation

/// Disk-persistent snapshots of in-flight ``CaptureContext``s so
/// ``LiveCaptureService`` can rehydrate after app termination.
///
/// Storage is a single JSON file at
/// `<Application Support>/Captures/active-capture.json` holding an
/// **array** of contexts keyed by `captureSessionID`. Atomic writes go
/// through a tmp+rename so a crash mid-write leaves the previous good
/// snapshot intact. Same concurrency pattern as ``UploadQueueStore``.
///
/// **Why an array (multi-slot).** This file used to hold a single
/// context, so starting a second recording overwrote the first's
/// snapshot. The June-2 field session exposed the consequence: a
/// morning recording that was still finalizing got its context clobbered
/// by the afternoon recording, so on the next launch only the afternoon
/// session was recoverable and the morning one could never be driven to
/// `.completed`. Keying by `captureSessionID` lets every sequential
/// offline session be recovered independently. The legacy single-object
/// file is migrated transparently on first read.
///
/// Lifecycle invariants the service maintains around this store:
/// - **Save** (upsert) on every transition INTO `.recording` or
///   `.finalizing`, and whenever `pendingUploadIDs` changes during
///   `.finalizing`.
/// - **Clear** the *specific* session (`clear(captureSessionID:)`) on
///   every transition into a terminal state (`.completed`, `.cancelled`,
///   `.failed`) so a clean exit doesn't leave a stale snapshot — without
///   disturbing a concurrent session's snapshot.
public actor CaptureContextStore {

    private let fileURL: URL
    private let logger: AppLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        logger: AppLogger = AppLogger(category: .capture)
    ) {
        self.fileURL = fileURL
        self.logger = logger
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Convenience init that resolves the snapshot file under
    /// `Application Support/Captures/active-capture.json`, creating
    /// the directory if needed. Used in production wiring.
    public static func makeDefault(
        logger: AppLogger = AppLogger(category: .capture)
    ) throws -> CaptureContextStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dirToFlag = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirToFlag.setResourceValues(values)
        let url = dir.appendingPathComponent("active-capture.json", isDirectory: false)
        return CaptureContextStore(fileURL: url, logger: logger)
    }

    /// All persisted in-flight capture snapshots. Returns `[]` if the
    /// file is missing or corrupt (corrupt files log a warning and are
    /// treated as empty so a damaged sidecar never blocks app launch).
    /// Transparently migrates the legacy single-object file shape.
    public func loadAll() async -> [PersistedCaptureContext] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            // Current shape: an array.
            if let contexts = try? decoder.decode([PersistedCaptureContext].self, from: data) {
                return contexts
            }
            // Legacy shape (pre-multi-slot): a single object. Migrate by
            // wrapping it — the next save() rewrites the file as an array.
            let single = try decoder.decode(PersistedCaptureContext.self, from: data)
            return [single]
        } catch {
            await logger.warning(
                "capture.context.load_failed",
                metadata: [
                    "reason": .string(error.localizedDescription)
                ]
            )
            return []
        }
    }

    /// The most-recently-started in-flight snapshot, if any. Kept as a
    /// convenience for callers that only care about the foreground
    /// capture; recovery uses ``loadAll()`` to rehydrate every session.
    public func load() async -> PersistedCaptureContext? {
        await loadAll().max { $0.startedAt < $1.startedAt }
    }

    /// Upsert a snapshot by `captureSessionID` — replaces an existing
    /// entry for the same session, else appends. Atomic via tmp+rename
    /// so a crash mid-write leaves the previous snapshot intact.
    public func save(_ context: PersistedCaptureContext) async throws {
        var contexts = await loadAll()
        contexts.removeAll { $0.captureSessionID == context.captureSessionID }
        contexts.append(context)
        try await write(contexts)
    }

    /// Remove the snapshot for a single capture session. Leaves any
    /// other sessions' snapshots intact. No-op if absent.
    public func clear(captureSessionID: String) async {
        var contexts = await loadAll()
        let before = contexts.count
        contexts.removeAll { $0.captureSessionID == captureSessionID }
        guard contexts.count != before else { return }
        if contexts.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
        } else {
            try? await write(contexts)
        }
    }

    /// Delete every snapshot (e.g. sign-out / full reset). Always
    /// succeeds (treats "no file" as a clear).
    public func clear() async {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func write(_ contexts: [PersistedCaptureContext]) async throws {
        let data: Data
        do {
            data = try encoder.encode(contexts)
        } catch {
            throw CaptureContextStoreError.persistenceFailed(reason: "encode: \(error.localizedDescription)")
        }
        let tmpURL = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CaptureContextStoreError.persistenceFailed(reason: "write: \(error.localizedDescription)")
        }
    }
}

/// On-disk shape for an in-flight capture. Subset of
/// ``CaptureServiceState`` — only the two non-terminal cases that
/// would survive an app termination.
public struct PersistedCaptureContext: Sendable, Equatable, Hashable, Codable {

    public let captureSessionID: String
    public let projectID: String
    public let workspaceID: String
    public let startedAt: Date
    public let phase: Phase
    /// Ordered for stable on-disk byte representation; deduplication
    /// is the service's responsibility, not the store's.
    public let pendingUploadIDs: [String]

    public init(
        captureSessionID: String,
        projectID: String,
        workspaceID: String,
        startedAt: Date,
        phase: Phase,
        pendingUploadIDs: [String]
    ) {
        self.captureSessionID = captureSessionID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.startedAt = startedAt
        self.phase = phase
        self.pendingUploadIDs = pendingUploadIDs
    }

    public enum Phase: String, Sendable, Equatable, Hashable, Codable {
        /// Server-side capture session created, recorder started,
        /// no uploads enqueued yet. App death here orphans an audio
        /// file on disk and leaves the server session `.active`.
        case recording
        /// Recorder stopped, uploads enqueued. App death here is
        /// fully recoverable: the upload queue store rehydrates,
        /// the watcher re-attaches.
        case finalizing
    }
}

public enum CaptureContextStoreError: Error, Sendable, Equatable {
    case persistenceFailed(reason: String)
}
