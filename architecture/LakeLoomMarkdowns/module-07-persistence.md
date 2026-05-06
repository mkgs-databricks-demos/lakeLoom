# Module 07 — Core Data Model + Persistence Stack

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** None (foundation module for persistence)
**Depended on by:** IngestService (Module 03 outbox), StorageService (Module 04 session records), future modules that need durable local state

---

## 1. Purpose

The Core Data persistence module is the unified durable storage layer for the iOS app. It owns:

- The Core Data stack itself (`NSPersistentContainer`, model, contexts)
- All entity definitions used by IngestService and StorageService (and future modules)
- Migration strategy across schema versions
- Background context management for write-heavy paths
- A small set of shared accessor protocols that other modules consume
- Database lifecycle: creation, opening, recovery from corruption, optional reset

This module exists for two reasons:

1. **Single Core Data stack.** IngestService's outbox and StorageService's session records share the same SQLite file. Two stacks pointing at the same file is forbidden — Core Data assumes single-stack ownership.
2. **Migration discipline.** Schema changes are coordinated across modules. A single source-of-truth model file plus explicit lightweight or heavyweight migrations prevents bugs where IngestService's entity changes break StorageService.

This module does **not** own domain logic — IngestService and StorageService still own their queries and state transitions. It owns the *plumbing*.

---

## 2. Design Principles

1. **One stack, one file, one model.** A single `NSPersistentContainer` named `LakeloomStore`. A single `.xcdatamodeld` bundle containing all entity versions. A single SQLite file at a known path.
2. **Background contexts for writes; main context for reads.** UI reads use the view context; service writes use task-scoped background contexts. No blocking the main thread on disk.
3. **WAL journaling.** SQLite Write-Ahead Logging is the default and what we want — durable, fast, crash-resistant.
4. **Lightweight migration first; heavyweight only when necessary.** Most schema changes can be expressed as additive lightweight migrations. We avoid breaking changes; when they're unavoidable, we write explicit mapping models.
5. **Schema versions are explicit and named.** `LakeloomStoreV1`, `LakeloomStoreV2`, etc. The current model identifier is checked at app launch.
6. **Corruption recovery is graceful.** A corrupt store triggers a clear error path; the user can choose "Reset local data" without losing Databricks-side data (because everything important is already there or about to be).
7. **No CloudKit sync.** Local-only. Sessions, outbox entries, and uploads are device-scoped. The Databricks side is the cloud.
8. **Tests use in-memory stores.** A `NSInMemoryStoreType` variant is provided for unit tests; the production app always uses SQLite.
9. **Concurrency model is clear.** All `NSManagedObject` instances are bound to a context. Cross-context references use `NSManagedObjectID`. Service actors hold contexts; they don't pass managed objects across actor boundaries.
10. **The model is the contract.** Other modules see the entities through a thin DTO layer when crossing actor boundaries; raw `NSManagedObject` types stay inside their owning store.

---

## 3. Public Surface

### 3.1 The Stack Type

```swift
@MainActor
final class CoreDataStack: Sendable {
    static let shared = CoreDataStack()

    /// The persistent container. Lazily initialized; safe to access after `initialize()`.
    private(set) var container: NSPersistentContainer!

    /// View context for read-only UI work. Bound to the main queue.
    var viewContext: NSManagedObjectContext { container.viewContext }

    /// Initialize the stack. Idempotent.
    /// Resolves model URL, configures store description, runs migrations,
    /// opens the store, applies post-load setup. Throws on unrecoverable errors.
    func initialize() async throws

    /// Tear down the stack. Used during sign-out-all and reset.
    func shutdown() async

    /// Reset the local store. Deletes the SQLite file and re-initializes.
    /// Surfaces from Settings → Diagnostics → "Reset local data".
    func reset() async throws

    /// Diagnostics for Settings.
    func diagnostics() async -> CoreDataStackDiagnostics

    /// Vend a fresh background context for writes.
    /// Each task should create its own; do not share across tasks.
    func newBackgroundContext() -> NSManagedObjectContext

    /// Convenience: perform a write on a background context with automatic save.
    func performWrite<T: Sendable>(
        _ block: @escaping (NSManagedObjectContext) throws -> T
    ) async throws -> T
}
```

### 3.2 Diagnostics Type

```swift
struct CoreDataStackDiagnostics: Sendable {
    let storeFileURL: URL
    let storeFileSizeBytes: Int64
    let walFileSizeBytes: Int64
    let modelVersion: String                    // e.g. "LakeloomStoreV1"
    let lastInitializedAt: Date
    let migrationOccurredAtLaunch: Bool
    let migrationDurationMs: Int64?
}
```

### 3.3 Errors

```swift
enum CoreDataStackError: Error, Sendable, Equatable {
    case modelNotFound(name: String)
    case storeFileURLUnresolvable
    case migrationFailed(reason: String)
    case openFailed(reason: String)
    case corruptStore(reason: String)
    case resetFailed(reason: String)
    case writeContextSaveFailed(reason: String)
    case unknownEntity(name: String)
}
```

---

## 4. The Model File

### 4.1 Layout

A single Xcode `.xcdatamodeld` named `LakeloomStore.xcdatamodeld` containing one or more `.xcdatamodel` versions:

```
LakeloomStore.xcdatamodeld/
├── LakeloomStore.xcdatamodel        (V1, current)
├── LakeloomStoreV2.xcdatamodel      (future)
└── ...
```

The "Current" model is set on the .xcdatamodeld bundle. Adding a new version is done in Xcode via Editor → Add Model Version.

### 4.2 Entities (V1)

Five entities for v1. Two come from IngestService (Module 03), three from StorageService (Module 04).

#### `OutboxRecord` (Module 03)

| Attribute | Type | Optional | Indexed | Notes |
|---|---|---|---|---|
| `recordUUID` | String | No | Yes (unique) | Primary key, UUIDv7 |
| `sessionID` | String | No | Yes | UUIDv7 |
| `workspaceID` | String | No | Yes | |
| `projectID` | String | No | No | |
| `sequenceNumber` | Integer 32 | No | No | |
| `eventType` | String | No | Yes | |
| `deviceTimestamp` | Date | No | No | |
| `chunkStartOffsetMs` | Integer 64 | No | No | |
| `chunkEndOffsetMs` | Integer 64 | No | No | |
| `captureMode` | String | No | No | |
| `schemaVersion` | String | No | No | |
| `headersJSON` | String | No | No | Allow large; not searched |
| `payloadJSON` | String | No | No | Allow large; not searched |
| `state` | String | No | Yes | `pending` / `inflight` / `sent` / `failed` / `dead_lettered` |
| `retryCount` | Integer 32 | No | No | |
| `lastError` | String | Yes | No | |
| `lastAttemptedAt` | Date | Yes | No | |
| `nextEligibleAt` | Date | No | Yes | For backoff scheduling |
| `createdAt` | Date | No | No | |
| `sentAt` | Date | Yes | No | |
| `deadLetteredAt` | Date | Yes | No | |

Composite indexes (set in entity inspector):
- `(state, nextEligibleAt)` — for the drainer's `nextBatch` query
- `(sessionID, sequenceNumber)` — for ordered drain and per-session UI
- `(workspaceID, state)` — for workspace-scoped diagnostics

#### `SessionRecord` (Module 04)

| Attribute | Type | Optional | Indexed | Notes |
|---|---|---|---|---|
| `sessionID` | String | No | Yes (unique) | UUIDv7 |
| `projectID` | String | No | Yes | |
| `workspaceID` | String | No | Yes | |
| `userUUID` | String | No | No | |
| `username` | String | No | No | |
| `captureMode` | String | No | No | `quick_capture` or `meeting` |
| `startedAt` | Date | No | Yes | |
| `endedAt` | Date | Yes | No | |
| `chunkCount` | Integer 32 | No | No | |
| `audioLocalRelativePath` | String | Yes | No | |
| `audioFormat` | String | Yes | No | |
| `audioSampleRate` | Integer 32 | Yes | No | |
| `audioBitrate` | Integer 32 | Yes | No | |
| `audioDurationMs` | Integer 64 | Yes | No | |
| `audioSizeBytes` | Integer 64 | Yes | No | |
| `audioSha256` | String | Yes | No | |
| `uploadState` | String | No | Yes | matches `UploadState` raw value |
| `uploadAttemptCount` | Integer 32 | No | No | |
| `uploadLastError` | String | Yes | No | |
| `uploadLastAttemptedAt` | Date | Yes | No | |
| `uploadStartedAt` | Date | Yes | No | |
| `uploadedAt` | Date | Yes | No | |
| `uploadBytesSent` | Integer 64 | No | No | |
| `uploadTaskIdentifier` | Integer 64 | Yes | No | URLSession task ID |
| `remoteVolumePath` | String | Yes | No | |
| `deleteAfter` | Date | Yes | Yes | For retention sweep |
| `purgedAt` | Date | Yes | No | |
| `deadLetteredAt` | Date | Yes | No | |

Composite indexes:
- `(uploadState, startedAt)` — for the upload coordinator's "next session to upload" query
- `(workspaceID, uploadState)` — for diagnostics

#### `OutboxStateChange` (audit, optional in v1 but designed-in)

A small audit table that records state transitions. Useful for debugging "why did this record get dead-lettered" and for the diagnostics screen. Bounded by retention.

| Attribute | Type | Optional | Indexed |
|---|---|---|---|
| `id` | String | No | Yes (unique, UUID) |
| `recordUUID` | String | No | Yes |
| `fromState` | String | No | No |
| `toState` | String | No | No |
| `reason` | String | Yes | No |
| `at` | Date | No | Yes |

> **Decision:** Implement `OutboxStateChange` in v1 with **bounded retention** (last 1000 entries per session, purged on session completion). Cost is negligible and debugging value is high.

#### `WorkspaceMetadataCache` (cache for workspace info beyond what AuthService stores)

AuthService keeps tokens and identity in Keychain. This entity caches non-sensitive metadata that's useful for offline rendering of the Sessions list (workspace name, region) without an extra Keychain read.

| Attribute | Type | Optional | Indexed |
|---|---|---|---|
| `workspaceID` | String | No | Yes (unique) |
| `workspaceURL` | String | No | No |
| `workspaceName` | String | No | No |
| `cloud` | String | No | No |
| `region` | String | Yes | No |
| `updatedAt` | Date | No | No |

#### `ProjectMetadataCache` (optional v1)

Mirror of recently seen project metadata, so the Sessions list can render project names without re-querying ProjectService. This exists as a denormalization, refreshed by ProjectService events.

| Attribute | Type | Optional | Indexed |
|---|---|---|---|
| `projectID` | String | No | Yes (unique) |
| `workspaceID` | String | No | Yes |
| `name` | String | No | No |
| `description` | String | Yes | No |
| `archived` | Boolean | No | No |
| `updatedAt` | Date | No | No |

> **Decision:** Implement `ProjectMetadataCache` in v1. The Sessions list shows project name per row; without this cache, every row would need a network roundtrip on first render.

### 4.3 Relationships

V1 has **no relationships**. All cross-entity references are by string ID (e.g., `OutboxRecord.sessionID` matches `SessionRecord.sessionID`). Reasoning:

- Relationships imply cascade delete semantics; we don't want a session deletion to cascade-delete outbox records (the outbox owns its own retention)
- String-keyed joins in fetch requests are clear and explicit
- Cross-entity invariants are managed by the owning service (IngestService for OutboxRecord, StorageService for SessionRecord)

If we add a relationship later (e.g., to navigate from a SessionRecord to its OutboxRecords for a debug view), we'll do it as an optional one-to-many with `Nullify` delete rule.

### 4.4 Generated Class Files

Use Codegen mode `Manual/None` for all entities, then write `NSManagedObject` subclasses by hand under `App/Persistence/Entities/`. This:

- Keeps the source of truth in version control (no Xcode-generated files in DerivedData)
- Lets us add convenience accessors and DTO conversion methods
- Lets us mark fields `@NSManaged public dynamic`/etc. as needed

Example:

```swift
@objc(OutboxRecord)
public final class OutboxRecord: NSManagedObject {
    @NSManaged public var recordUUID: String
    @NSManaged public var sessionID: String
    @NSManaged public var workspaceID: String
    // ... rest of attributes
}

extension OutboxRecord {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<OutboxRecord> {
        NSFetchRequest<OutboxRecord>(entityName: "OutboxRecord")
    }

    /// Convert to the Sendable DTO used outside the persistence layer.
    func toDTO() -> OutboxRecordDTO {
        OutboxRecordDTO(/* ... */)
    }
}
```

### 4.5 DTO Boundary

Managed objects live inside their owning store actor. They never cross to another actor or the SwiftUI view layer directly. The DTO layer:

```swift
struct OutboxRecordDTO: Sendable, Equatable {
    let recordUUID: String
    let sessionID: String
    // ... all fields, value semantics
}

struct SessionRecordDTO: Sendable, Equatable {
    // ...
}
```

All public store APIs return DTOs, take DTOs as inputs, and convert internally. This sidesteps Sendable issues with `NSManagedObject` and gives us clean unit-test types.

---

## 5. Stack Initialization

### 5.1 The Initialize Path

```swift
@MainActor
func initialize() async throws {
    if container != nil { return }   // idempotent

    let modelURL = try resolveModelURL()
    guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
        throw CoreDataStackError.modelNotFound(name: "LakeloomStore")
    }

    let container = NSPersistentContainer(name: "LakeloomStore", managedObjectModel: model)

    let storeURL = try resolveStoreURL()
    let description = NSPersistentStoreDescription(url: storeURL)
    description.type = NSSQLiteStoreType
    description.shouldMigrateStoreAutomatically = true
    description.shouldInferMappingModelAutomatically = true
    description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
    description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                         forKey: NSPersistentStoreFileProtectionKey)
    description.setValue("WAL" as NSString, forPragmaNamed: "journal_mode")
    description.setValue("NORMAL" as NSString, forPragmaNamed: "synchronous")
    container.persistentStoreDescriptions = [description]

    let migrationStart = Date()
    try await loadStore(container: container)
    let migrationDuration = Date().timeIntervalSince(migrationStart) * 1000

    container.viewContext.automaticallyMergesChangesFromParent = true
    container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

    self.container = container
    self.lastInitializedAt = Date()
    self.lastMigrationDurationMs = Int64(migrationDuration)
}
```

### 5.2 Store File Location

```swift
private func resolveStoreURL() throws -> URL {
    let appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let storeDir = appSupport.appendingPathComponent("Persistence", isDirectory: true)
    try FileManager.default.createDirectory(at: storeDir,
                                            withIntermediateDirectories: true,
                                            attributes: nil)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var dirURL = storeDir
    try? dirURL.setResourceValues(values)
    return storeDir.appendingPathComponent("LakeloomStore.sqlite")
}
```

The Persistence directory is excluded from iCloud backup because the data is reconstructible from Databricks. It also avoids bloating user backups with dozens of MB of outbox + session data.

### 5.3 Pragma Choices

- **`journal_mode = WAL`** — concurrent reads while writing; the standard choice for Core Data
- **`synchronous = NORMAL`** — full WAL durability without `FULL` fsync overhead. SQLite WAL with NORMAL is durable across process crashes; only OS-level crashes can lose the last commit, which is acceptable for our use case (the silver pipeline dedupes anyway)

### 5.4 File Protection

`completeUntilFirstUserAuthentication` matches the Keychain accessibility used for tokens. The store is encrypted at rest, accessible after first device unlock following reboot. This is the right level for background URLSession launches — they need to read the store to find the next pending upload.

`.complete` would prevent background launches from accessing the store while the device is locked, which would break the upload pipeline. Avoided.

### 5.5 Persistent History Tracking

Enabled via `NSPersistentHistoryTrackingKey`. Used for:
- Cross-process change notification (the future iPad app or extension)
- Crash recovery — re-read history to reconstruct state
- Tombstone-style soft deletes if we ever need them

V1 doesn't use history actively, but enabling it now means we can later without a destructive migration.

### 5.6 Remote Change Notifications

`NSPersistentStoreRemoteChangeNotificationPostOptionKey = true` lets a future shared-container scenario (e.g., a Notification Service Extension that reads pending uploads) be notified of changes from the main app. Not used in v1; cheap to enable.

---

## 6. Migration Strategy

### 6.1 Lightweight Migration (Default)

Most schema changes are lightweight: add a new entity, add a new attribute with a default value, rename via renaming identifier, change index. These work automatically when:

- `shouldMigrateStoreAutomatically = true`
- `shouldInferMappingModelAutomatically = true`
- The new model can derive a mapping from the old via Core Data's inference rules

**Examples of safe lightweight migrations:**
- Adding a new optional attribute
- Adding a new entity
- Adding a new index or composite index
- Renaming an attribute (with renaming identifier set on the new model version)
- Adding a new enum case (string column, no schema change required)

### 6.2 Heavyweight Migration (Mapping Models)

Required for:
- Splitting one entity into two
- Combining attributes
- Type changes that aren't trivially convertible (string → date with custom parsing)
- Removing an attribute that has dependent data

When needed, we add a `.xcmappingmodel` file mapping `LakeloomStoreVN.xcdatamodel` → `LakeloomStoreVN+1.xcdatamodel`. Custom `NSEntityMigrationPolicy` subclasses handle complex transformations.

### 6.3 Pre-Flight Migration Check

Before opening the store, we check whether migration is needed. If the source model is more than one version behind the current model, we may need to do a chained migration (V1 → V2 → V3). The `NSPersistentContainer` handles chained migrations automatically when each step has a mapping model in the bundle, but we surface progress to the UI for long migrations:

```swift
private func loadStore(container: NSPersistentContainer) async throws {
    if try storeNeedsMigration() {
        coordinator.publishMigrationStart()
    }
    try await withCheckedThrowingContinuation { continuation in
        container.loadPersistentStores { description, error in
            if let error {
                continuation.resume(throwing: CoreDataStackError.openFailed(reason: error.localizedDescription))
            } else {
                continuation.resume()
            }
        }
    }
    coordinator.publishMigrationComplete()
}
```

For v1 there's only one version, so this is forward-looking machinery.

### 6.4 Failed Migration Recovery

If migration fails (corrupt store, unsupported version downgrade), we throw `CoreDataStackError.migrationFailed`. AppCoordinator catches this and surfaces the error UI with two options:

1. **Try again** — re-attempt the open (transient errors may resolve)
2. **Reset local data** — delete the SQLite file and start fresh

Reset is destructive: any unsent transcript records and any unuploaded audio files are lost. We surface this clearly in the UI. Because the app's design has fast outbox drain and aggressive Wi-Fi audio upload, the risk is bounded — most users would lose at most one session's worth of data.

---

## 7. Concurrency Model

### 7.1 Three Context Patterns

| Use case | Context source | Concurrency type |
|---|---|---|
| UI reads (Sessions list, project picker) | `viewContext` | `.mainQueueConcurrencyType` |
| Service writes (IngestService outbox, StorageService sessions) | `newBackgroundContext()` | `.privateQueueConcurrencyType` |
| Long-running background work (sweeper, retention) | `newBackgroundContext()` | `.privateQueueConcurrencyType` |

### 7.2 The `performWrite` Helper

```swift
func performWrite<T: Sendable>(
    _ block: @escaping (NSManagedObjectContext) throws -> T
) async throws -> T {
    let context = newBackgroundContext()
    return try await context.perform {
        let result = try block(context)
        if context.hasChanges {
            try context.save()
        }
        return result
    }
}
```

This is the workhorse. IngestService and StorageService use it for nearly all writes. Every call is its own short-lived context, ensuring no shared mutable state across actors.

### 7.3 Cross-Context References

When a service needs to hand a managed object reference to another part of the system, it uses `NSManagedObjectID`:

```swift
let objectID = try await stack.performWrite { context in
    let record = OutboxRecord(context: context)
    // ... configure ...
    try context.obtainPermanentIDs(for: [record])
    return record.objectID
}

// Later, on a different context:
let context = stack.newBackgroundContext()
let record = try context.existingObject(with: objectID) as! OutboxRecord
```

In practice, services prefer DTOs for cross-actor communication. Object IDs are reserved for internal store machinery.

### 7.4 Save Conflict Policy

`viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy` for UI reads — the in-memory object wins on conflict. Background contexts use the same policy by default. In our access patterns:

- The drainer is the only writer to outbox records' state field; no conflicts
- The upload coordinator is the only writer to session records' upload fields; no conflicts
- UI is read-only; no conflicts

So conflicts are rare. The policy is a safety net.

### 7.5 Notifications

`NSManagedObjectContextDidSave` fires after every save. The view context auto-merges via `automaticallyMergesChangesFromParent = true`. UI uses `@FetchRequest` (SwiftUI) or `NSFetchedResultsController` to react to changes; we don't add manual observers.

---

## 8. Reset and Recovery

### 8.1 Reset Local Data

User-facing reset path. Triggered from Settings → Diagnostics → "Reset local data" with strong confirmation.

```swift
@MainActor
func reset() async throws {
    guard let container else { throw CoreDataStackError.openFailed(reason: "stack not initialized") }
    let storeURL = container.persistentStoreCoordinator.persistentStores.first?.url

    // Tear down the stack.
    for store in container.persistentStoreCoordinator.persistentStores {
        try container.persistentStoreCoordinator.remove(store)
    }
    self.container = nil

    // Remove the SQLite + sidecar files.
    if let storeURL {
        try removeStoreFiles(at: storeURL)
    }

    // Re-initialize.
    try await initialize()
}
```

`removeStoreFiles` deletes the `.sqlite`, `.sqlite-wal`, and `.sqlite-shm` files. After reset, IngestService and StorageService re-discover empty state and run their normal recovery passes.

### 8.2 Corruption Detection

If `loadPersistentStores` returns an error containing the SQLite error code for corruption (11 or 26), we wrap as `CoreDataStackError.corruptStore`. AppCoordinator handles this by transitioning to `.error(.bootstrapFailed)` and offering reset.

### 8.3 Side Effects of Reset

- Outbox records lost → silver pipeline never sees them, but transcripts captured before the last successful drain were already sent
- Session records lost → Sessions list is empty until new captures
- Local audio files: **not** deleted by Core Data reset. StorageService's recovery pass will discover orphaned audio files and quarantine them
- Workspace metadata cache lost → re-fetched on next call
- Project metadata cache lost → re-fetched on next call

The user-visible message before confirming reset:
> "This deletes all local app data: pending uploads, session history, and cached metadata. Anything already sent to your Databricks workspace is unaffected. Continue?"

---

## 9. Test Strategy

### 9.1 In-Memory Stack for Tests

```swift
extension CoreDataStack {
    static func makeInMemory() throws -> CoreDataStack {
        let stack = CoreDataStack(testingOnly: true)
        let container = NSPersistentContainer(name: "LakeloomStore",
                                              managedObjectModel: stack.model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        stack.container = container
        return stack
    }
}
```

Tests construct fresh in-memory stacks per test case. Fast (~ms), isolated, no cleanup.

### 9.2 What to Test

- **Stack lifecycle:** initialize, shutdown, reset, re-initialize
- **Migration paths:** fixture stores at older versions, verify successful migration to current
- **Concurrent writes:** multiple background contexts saving concurrently; verify no deadlock and final state is consistent
- **Save conflict:** two contexts modify same record; verify merge policy resolves correctly
- **Performance regression test:** insert 10,000 outbox records, measure save duration (should be <1s on a modern device)

### 9.3 Migration Test Fixtures

For each new model version, we keep a fixture SQLite file with representative data at the old version. Migration tests open the fixture, run migration, and assert the migrated data matches expected output. Fixtures live under `AppTests/Persistence/Fixtures/`.

---

## 10. Observability

- Log at `info`: stack initialization start/complete with duration; migration occurrence and duration; reset triggered
- Log at `error`: load failures, save failures, corruption detection
- **Never log entity contents.** Logs reference entities by name and count only
- Counters in `CoreDataStackDiagnostics`:
  - `storeFileSizeBytes` — useful for users to understand disk impact
  - `walFileSizeBytes` — large WAL means lots of unflushed writes; diagnostic signal
  - `lastInitializedAt`, `migrationOccurredAtLaunch`, `migrationDurationMs`
- A debug-only "Persistence" view in Settings → Diagnostics shows entity row counts and store file size

---

## 11. Out of Scope for v1

- **CloudKit / iCloud sync.** Local-only. Cloud presence comes via Databricks.
- **Full-text search indexes.** No FTS5 setup in v1.
- **Encryption beyond file protection.** No SQLCipher; the file protection class plus SQLite WAL is sufficient.
- **Multi-store coordinators.** Single store, single coordinator.
- **App Group sharing.** No share extension or widget access in v1; if added later, the store would move to a shared container.
- **Tombstones for soft delete.** Persistent history is enabled but not actively consumed.

---

## 12. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Whether to put outbox + session entities in separate Core Data configurations within the same model (allows independent migration of related entity sets) | v1: single configuration. Revisit if migration coupling becomes painful. |
| 2 | Whether to enable persistent history token tracking (for log replay) or just rely on history pruning | v1: enable tracking, no manual replay. Pruning runs on a 30-day retention. |
| 3 | Default WAL truncation strategy — let SQLite manage or explicit `PRAGMA wal_checkpoint(TRUNCATE)` on app background | v1: SQLite default. Monitor WAL size in diagnostics; revisit if it grows unbounded. |
| 4 | Whether to add fetched properties or relationships in v1 for cross-entity navigation in debug views | v1: string-keyed joins only. Add relationships in v1.x if the debug view needs them. |
| 5 | Whether to use NSBatchInsertRequest for high-volume seed data | v1: not needed. Outbox writes are one-at-a-time and small. |
| 6 | Migration UI — block bootstrap with a spinner, or land the user at a "Migrating..." screen | v1: spinner integrated into AppCoordinator's `recovering` phase. Most migrations complete in <500ms. |
| 7 | Whether the in-memory store option should ship in release builds (gated behind a debug flag) | v1: build-time flag, default off |

---

## 13. File Layout (proposed)

```
App/Persistence/
├── CoreDataStack.swift                     // public surface
├── CoreDataStackDiagnostics.swift
├── CoreDataStackError.swift
├── Model/
│   └── LakeloomStore.xcdatamodeld/
│       ├── LakeloomStore.xcdatamodel/       (V1)
│       └── ...
├── Entities/
│   ├── OutboxRecord+CoreDataClass.swift
│   ├── OutboxRecord+CoreDataProperties.swift
│   ├── OutboxRecord+DTO.swift
│   ├── SessionRecord+CoreDataClass.swift
│   ├── SessionRecord+CoreDataProperties.swift
│   ├── SessionRecord+DTO.swift
│   ├── OutboxStateChange+CoreDataClass.swift
│   ├── OutboxStateChange+CoreDataProperties.swift
│   ├── WorkspaceMetadataCache+CoreDataClass.swift
│   ├── WorkspaceMetadataCache+CoreDataProperties.swift
│   ├── ProjectMetadataCache+CoreDataClass.swift
│   └── ProjectMetadataCache+CoreDataProperties.swift
├── Migration/
│   ├── MigrationDetector.swift
│   ├── MigrationProgressPublisher.swift
│   └── MappingModels/                      // .xcmappingmodel files for heavyweight migrations
├── Lifecycle/
│   ├── StoreFileLocator.swift
│   ├── StoreLoader.swift
│   ├── StoreReset.swift
│   └── ContextFactory.swift
└── Testing/
    └── InMemoryCoreDataStack.swift
```

Tests mirror this layout under `AppTests/Persistence/`.
