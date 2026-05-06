# Session Summary — 2026-05-06 — Module 07 (Core Data persistence stack)

**Branch:** `feature/ios-module-07-persistence` (off `main` at `babca71`)
**Author:** Matthew Giglia (with Claude Code / Isaac)
**Scope:** Implements Module 07 (`architecture/LakeLoomMarkdowns/module-07-persistence.md`) — the unified Core Data persistence layer with five v1 entities (`OutboxRecord`, `SessionRecord`, `OutboxStateChange`, `WorkspaceMetadataCache`, `ProjectMetadataCache`), Sendable DTO mirrors, a `CoreDataStack` actor backed by SQLite + WAL under `<AppSupport>/Persistence/`, an in-memory factory for tests, and 15 new tests covering lifecycle, round-trips, and concurrent writes.

This unblocks Modules 03 (IngestService outbox) and 04 (StorageService session records) — both of which build directly on top of these entities.

---

## Decisions made

### 1. Manual / None codegen for entity classes

Module 07 §4.4's call. Rather than letting Xcode auto-generate the `NSManagedObject` subclasses into DerivedData, we hand-write them under `App/Persistence/Entities/`. Each entity is a triple of files:

- `+CoreDataClass.swift`: the `@objc(EntityName) public final class EntityName: NSManagedObject {}` shell, plus typed enum types nested inside (e.g. `OutboxRecord.State`) so callers don't string-key state values.
- `+CoreDataProperties.swift`: the `@NSManaged` property wall, separated for diff-friendliness when adding columns later.
- `+DTO.swift`: the Sendable mirror struct with `Equatable` + `Hashable`, plus `toDTO()` and `apply(_:)` extensions on the managed object for cross-actor handoff.

Pros: source of truth lives in version control, generated artifacts don't pollute DerivedData, and we can add typed enum scaffolding next to the entity it's about. Con: more files to write up front, but the cost is paid once and amortizes across modules.

### 2. Sendable DTO boundary

Module 07 §4.5. `NSManagedObject` instances are bound to a context's queue and are not `Sendable`. Crossing actor boundaries with them is a Swift 6 strict-concurrency violation. So:

- Managed-object instances stay inside `performWrite { context in ... }` blocks.
- Anything that needs to leave the persistence layer is converted to its DTO mirror first.
- The DTO types are `Sendable + Equatable + Hashable`, structured for direct use in `Set<>`, `Dictionary` keys, and `Codable` should we ever need it.

This is what makes the rest of the app's actor-based design tractable — IngestService and StorageService never touch `NSManagedObject` directly.

### 3. `projectDescription` instead of `description` on `ProjectMetadataCache`

Module 07 §4.2 spec'd the column as `description: String?`. Implementation renamed it to `projectDescription` because `description` is reserved on `NSObject` (every Cocoa class inherits it as a `String` description for debug printing). Shadowing it on a `@objc` Core Data class with a different type causes runtime issues — Cocoa printing falls back to the inherited version while Core Data tries to use the `@NSManaged` override. Renaming sidesteps the conflict; the DTO uses the same name so the wire form is consistent.

### 4. Single `CoreDataStack` with `inMemory: Bool` flag

Rather than separate `LiveCoreDataStack` and `InMemoryCoreDataStack` types, a single `CoreDataStack` actor takes an `inMemory: Bool = false` parameter. The only configuration difference is the persistent store description type (`NSSQLiteStoreType` vs `NSInMemoryStoreType`). All other code (model loading, context vending, `performWrite`, reset) is identical.

`CoreDataStack.makeInMemory()` is a static convenience for test ergonomics. Trivial extension; the actor has just one implementation.

### 5. `NSMergePolicy.mergeByPropertyObjectTrump`, not the legacy bridged constant

The original Module 07 §5.1 example used `NSMergeByPropertyObjectTrumpMergePolicy` — a legacy `Any`-typed constant from Apple's headers. Under Swift 6 strict concurrency, that constant trips a non-concurrency-safe error because Apple declared it as `var` rather than `let`. The modern Swift API is `NSMergePolicy.mergeByPropertyObjectTrump`, which returns a typed `NSMergePolicy` and is concurrency-safe. Used in three call sites.

### 6. `newBackgroundContext()` is `async throws` on the protocol

The Module 07 §3.1 spec had `newBackgroundContext() -> NSManagedObjectContext` (sync). Implementing this on a Swift actor required either a semaphore-on-Task hack to hop into the actor, or making the method `nonisolated` and managing `container` access with a lock. Both are wrong tradeoffs. Changed the protocol method to `async throws` — the actor implementation is then a clean fetch of `container.newBackgroundContext()`.

`performWrite(_:)` remains the recommended path for the common "do this work in a background context and save" case; `newBackgroundContext()` is the escape hatch for advanced fetch / batched insert patterns.

### 7. Lightweight migration only for v1

`shouldMigrateStoreAutomatically = true` and `shouldInferMappingModelAutomatically = true`. v1 has one model version; future versions add fields additively where possible. Heavyweight migrations (`.xcmappingmodel` files + `NSEntityMigrationPolicy` subclasses) land if a future change can't be expressed as lightweight — Module 07 §6.2 has the full decision tree.

The stack records `migrationOccurredAtLaunch` and `migrationDurationMs` for the diagnostics screen so we can see it in the wild if it ever takes >100ms.

### 8. Corruption + migration error detection by error code

The stack inspects the `NSError` returned by `loadPersistentStores`:

- **Corruption**: SQLite codes 11 (`SQLITE_CORRUPT`) and 26 (`SQLITE_NOTADB`) → `CoreDataStackError.corruptStore`. AppCoordinator's bootstrap path catches this and routes the user to "Reset local data".
- **Migration failure**: Core Data error codes 134110 (`migrationMissingSourceModelError`), 134120 (`migrationError`), 134130 (`migrationCancelled`) → `CoreDataStackError.migrationFailed`.
- **Anything else**: `CoreDataStackError.openFailed(reason:)` with the underlying NSError's localizedDescription.

### 9. WAL + NORMAL synchronous + persistent history tracking enabled

Per Module 07 §5.3:

- `journal_mode = WAL`: concurrent reads while writing; the standard Core Data choice.
- `synchronous = NORMAL`: full WAL durability without `FULL` fsync overhead. Durable across process crashes; only OS-level crashes can lose the last commit, which is acceptable since the silver pipeline dedupes anyway.
- `NSPersistentHistoryTrackingKey = true`: enabled for v1 even though we don't actively consume history. Enabling it now is cheap; enabling it later requires coordination with all existing stores.
- `NSPersistentStoreRemoteChangeNotificationPostOptionKey = true`: same logic — no active consumer in v1, but if a future iPad app or notification service extension wants to consume changes, the store will already be configured for it.

### 10. `<AppSupport>/Persistence/` directory excluded from iCloud backup

Per Module 07 §5.2. The data is reconstructible from Databricks (or in the case of in-flight outbox records, expected at-least-once delivery handles it). Including it in user backups would bloat them with tens of MB per active user.

`URLResourceValues.isExcludedFromBackup = true` set on the directory itself, not per-file — covers the SQLite, `-wal`, and `-shm` sidecars in one shot.

---

## Work performed

5 commits on `feature/ios-module-07-persistence`:

| Commit | Subject | Files |
|---|---|---|
| `07cedb7` | feat(persistence): public CoreDataStacking protocol and error types | CoreDataStacking, CoreDataStackError, CoreDataStackDiagnostics (3 files, +143) |
| `0ba44b0` | feat(persistence): LakeloomStore.xcdatamodeld with 5 v1 entities | .xcdatamodeld bundle with .xccurrentversion + contents (2 files, +191) |
| `f2217fa` | feat(persistence): NSManagedObject subclasses + Sendable DTOs | 15 entity files (Class + Properties + DTO × 5 entities, +745) |
| `1a61300` | feat(persistence): live CoreDataStack actor with SQLite + WAL | CoreDataStack actor + protocol async tweak (2 files, +300/-1) |
| `1d716ef` | test(persistence): in-memory factory and entity round-trip suites | CoreDataStack+InMemory + 2 test files (4 files, +478) |
| (this commit) | docs(session-summary): record 2026-05-06 Module 07 session | iOS/session_summaries/2026-05-06-1329-module-07-persistence.md |

### Verification

```sh
$ xcodegen generate
Created project at .../iOS/LakeloomApp.xcodeproj

$ xcodebuild test -project LakeloomApp.xcodeproj -scheme LakeloomApp \
    -destination 'platform=iOS Simulator,name=iPhone 17'
…
✔ Test run with 92 tests in 25 suites passed after 0.197 seconds.
** TEST SUCCEEDED **
```

92 tests across 25 suites:
- 45 from Module 01 (auth) — all still green
- 32 from Module 09 (telemetry) — all still green
- 15 new (persistence):
  - CoreDataStack lifecycle (4): idempotent initialize, throws-before-initialize on diagnostics + performWrite, reset clears state
  - CoreDataStack performWrite (3): returns block value, autosaves on changes, two distinct records persist
  - CoreDataStack concurrency (1): 200 concurrent writes converge to total 200 with no deadlocks
  - Entity DTO round-trip (7): OutboxRecord full + state enum, SessionRecord full + no-audio variant, OutboxStateChange, WorkspaceMetadataCache, ProjectMetadataCache

Plus the 1 LaunchTests UI test.

---

## Open items / followups

- **AuthService → WorkspaceMetadataCache wiring**: Module 01 currently keeps workspace metadata in Keychain only. With `WorkspaceMetadataCache` now available, AuthService should also denormalize a non-sensitive subset (id / URL / name / cloud / region) on sign-in so the Sessions list (when Module 08 lands) can render workspace names without an extra Keychain hop. Mechanical follow-up — lands when AppCoordinator-driven Sessions list lands.
- **`OutboxStateChange` retention sweeper**: Module 07 §4.2 calls for last-1000-entries-per-session retention with purge on session completion. Not in this PR — that logic naturally lives in IngestService (Module 03) where it has the session-lifecycle context.
- **Migration test fixtures**: Module 07 §9.3 calls for storing fixture SQLite files at older model versions under `AppTests/Persistence/Fixtures/`. v1 has only one version, so there's nothing to migrate from yet. Lands when V2 arrives.
- **Persistent history pruning**: Tracking is enabled, but we don't actively consume or prune history records. v1 default behavior is fine; pruning logic lands if/when a feature uses history actively or if disk usage becomes a concern (Module 07 §12.2 open item).
- **`NSBatchInsertRequest` for high-volume seed**: Not needed — outbox writes are one-at-a-time and small per Module 07 §12.5. Revisit only if a workload demands it.

---

## What's next

**Module 06 (ProjectService)** is the natural next step — it depends only on AuthService (already merged) and produces the project-list / create / archive REST client iOS will use against the Databricks App. After that, **Module 05 (AppCoordinator + Onboarding)** brings the first runnable end-to-end demo: launch the app → real OAuth sign-in → identity confirmation → project picker.

Alternative: **Module 03 (IngestService)** now that the outbox table is in place. Would unblock Module 04 (Storage) right after. But there's no UI to drive it through yet, so testing stays headless. I'd prefer to land the visible-progress arc (06 → 05) first, then come back for the heavy infrastructure modules.

---

## What's not in this session

- No iOS source under any of the other module folders — they remain `.gitkeep` placeholders.
- No `CoreDataStack` hookup from `AppCoordinator` — that lands with Module 05.
- No live-store smoke test against the SQLite path — only the in-memory store is exercised by tests. A live-store test could land in nightly CI when Module 10 §8 wires it up.
- No `NSPersistentHistoryTransaction` consumers — the option is enabled but unused.
- No edits to `architecture/LakeLoomMarkdowns/`, `lakeLoom_infra/`, or anything outside `iOS/`.
