# Module 10 — Project Structure, Build, and Testing

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-06
**Depends on:** All prior modules (this one defines how they're assembled)
**Depended on by:** Every developer working on the app

---

## 1. Purpose

This module defines how the codebase is organized at the Xcode-project level: targets, schemes, dependencies, build configurations, signing, and the testing strategy that ties all module test suites together. It also covers continuous integration, release process, and the developer environment.

This is the only module without runtime code. Its outputs are:

- A canonical Xcode project layout
- A clear separation between app code, test code, and shared infrastructure
- Build configurations for development, TestFlight, and App Store
- A CI pipeline that runs on every pull request
- A release process that produces signed, distributable builds
- A documented developer onboarding flow

---

## 2. Design Principles

1. **One Xcode project, multiple targets.** No workspace-of-projects sprawl. The single `.xcodeproj` keeps build settings consolidated.
2. **Source files mirror the module layout from the design docs.** A developer reading Module 03 can find IngestService code under `App/Ingest/` without searching.
3. **Swift Package Manager for third-party dependencies.** No CocoaPods, no Carthage. SPM is Apple-supported and Xcode-integrated.
4. **First-party packages where boundaries are sharp.** Pure infrastructure (Telemetry, Persistence shared types) lives in local Swift Packages within the project. Domain modules stay in the app target for v1.
5. **Build configurations encode environment, not behavior toggles.** `Debug`, `Release-TestFlight`, `Release-AppStore`. Behavior toggles use feature flags read at runtime.
6. **One test target per module.** Test files are co-located with the module under `AppTests/<Module>/`. Each module's tests can run in isolation.
7. **CI is the source of truth for "buildable."** Local builds are convenient; CI is canonical. Anything that doesn't pass CI doesn't ship.
8. **Signing is fastlane-driven, not a developer chore.** Match handles certificates and profiles. Developers don't manage signing manually.
9. **Reproducible builds.** Pinned Xcode version, pinned Swift toolchain, pinned package versions. CI uses the same versions as developers.
10. **Onboarding a new developer takes <30 minutes.** Clone, run `make setup`, open Xcode, build. That's it.

---

## 3. Xcode Project Layout

### 3.1 Top-Level Directory Structure

```
lakeloom-ios/
├── App/                                    # Application source
│   ├── Auth/                               # Module 01
│   ├── Capture/                            # Module 02
│   ├── Ingest/                             # Module 03
│   ├── Storage/                            # Module 04
│   ├── Coordinator/                        # Module 05
│   ├── Projects/                           # Module 06
│   ├── Persistence/                        # Module 07
│   ├── Views/                              # Module 08
│   ├── Telemetry/                          # Module 09
│   ├── Common/                             # Shared utilities (UUIDv7, etc.)
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   ├── Localizable.xcstrings
│   │   ├── Info.plist
│   │   └── PrivacyInfo.xcprivacy
│   └── LakeloomApp.swift                    # @main entry point
│
├── AppTests/                               # Unit tests, mirror App/ layout
│   ├── Auth/
│   ├── Capture/
│   ├── ...
│   └── TestSupport/                        # Shared test utilities, fixtures
│
├── AppUITests/                             # XCUITest suite
│   ├── OnboardingHappyPathTests.swift
│   ├── CaptureHappyPathTests.swift
│   └── ...
│
├── Packages/                               # Local Swift Packages
│   ├── LakeloomTelemetry/                   # Promoted from Module 09 if reused
│   ├── LakeloomPersistenceCore/             # Promoted from Module 07 if reused
│   └── ...
│
├── BuildScripts/
│   ├── lint.sh                             # SwiftLint, format check
│   ├── build-debug.sh
│   ├── build-release.sh
│   └── seed-database.swift                 # Dev: pre-populate Core Data with fixtures
│
├── fastlane/
│   ├── Fastfile
│   ├── Appfile
│   ├── Matchfile
│   └── Pluginfile
│
├── .github/workflows/                      # CI definitions
│   ├── pr.yml
│   ├── nightly.yml
│   └── release.yml
│
├── docs/                                   # Architecture & module docs
│   ├── ios-app-architecture.md
│   ├── module-01-auth-service.md
│   ├── ... (the design docs we've produced)
│   └── developer-onboarding.md
│
├── LakeloomApp.xcodeproj                    # The Xcode project file
├── Package.swift                           # Resolved local packages
├── Package.resolved
├── .swiftlint.yml
├── .swift-format
├── .gitignore
├── .gitattributes
├── Makefile
└── README.md
```

### 3.2 Why a Single `.xcodeproj`

We considered a workspace with multiple projects (one per module). Rejected because:
- Xcode workspaces add navigation friction
- Cross-module refactoring is more painful
- A single project + folder organization gives the same logical separation
- SPM local packages handle the cases where true compilation isolation is needed

### 3.3 Targets

Five targets in the Xcode project:

| Target | Purpose |
|---|---|
| `LakeloomApp` | The shipping iOS app |
| `LakeloomAppTests` | Unit tests; uses host application |
| `LakeloomAppUITests` | XCUITest UI tests |
| `LakeloomAppMockServer` | A local mock server (CLI tool) for integration tests against fake Databricks |
| `LakeloomAppPreview` | A small preview helper target — test data + view fixtures for SwiftUI previews |

The mock server target is build-only-on-macOS; it doesn't ship to devices. It runs locally during integration tests to avoid hitting real Databricks workspaces.

---

## 4. Dependencies

### 4.1 First-Party Frameworks

All from the iOS SDK:
- SwiftUI, UIKit
- AVFoundation, Speech (iOS 26 SpeechAnalyzer)
- CryptoKit
- Network (NWPathMonitor)
- AuthenticationServices (ASWebAuthenticationSession)
- CoreData
- OSLog (unified logging)
- Combine (for legacy interop only; we use AsyncStream primarily)

### 4.2 Third-Party via SPM

| Package | Version | Purpose |
|---|---|---|
| `swift-async-algorithms` (Apple) | 1.x | `merge` / `combineLatest` for async sequences |
| `swift-collections` (Apple) | 1.x | `Deque`, `OrderedSet` for log collector and other ordered structures |
| `libopus` (vendored) | 1.4+ | Opus encoding for audio (Module 02) |

We deliberately keep this list short. Every third-party dependency is a future migration cost, a security review surface, and a build-time hit.

> **Note on transport.** Earlier drafts of Module 03 used `grpc-swift` + `swift-protobuf` for a direct gRPC connection to ZeroBus. Those dependencies are no longer needed: iOS POSTs JSON to the Databricks App, which owns the Zerobus TS SDK call server-side. `URLSession` + `JSONEncoder`/`JSONDecoder` from the standard library cover the entire ingest, projects, and sync transport.

### 4.3 What We Are NOT Using

- **gRPC tooling on iOS** (`grpc-swift`, `swift-protobuf`) — iOS speaks HTTPS to the Databricks App; the App owns the Zerobus gRPC client server-side
- **Combine** as a primary tool — AsyncStream replaces it
- **PromiseKit / RxSwift / similar** — Swift Concurrency replaces these
- **Alamofire** — `URLSession` is enough
- **Realm** — Core Data is enough
- **Sentry / Crashlytics / Bugsnag** — v1 uses Apple's built-in crash reporter (Module 09)
- **CocoaPods, Carthage** — SPM only
- **PostgresNIO or any direct Postgres client** — Lakebase access goes through the Databricks App's REST API (Module 06, Module 11)

### 4.4 Dependency Audit

Quarterly: review each dependency for security advisories (CVE feed), license changes, and ongoing maintenance. SPM's `Package.resolved` is committed to track exact versions.

---

## 5. Build Configurations

### 5.1 Three Configurations

| Configuration | Purpose | Distribution |
|---|---|---|
| `Debug` | Daily development | Local devices, simulators |
| `Release-TestFlight` | Pre-release testing | TestFlight |
| `Release-AppStore` | Production | App Store |

### 5.2 What Differs Between Them

| Setting | Debug | Release-TestFlight | Release-AppStore |
|---|---|---|---|
| Swift optimization | `-Onone` | `-O` | `-O` |
| Active compilation conditions | `DEBUG`, `INTERNAL_TOOLS` | `INTERNAL_TOOLS` | (none) |
| OAuth client_id | Dev OAuth app | Prod OAuth app | Prod OAuth app |
| Default ZeroBus endpoint base | configurable | derived from workspace URL | derived from workspace URL |
| Verbose logging in release | `trace` and `debug` enabled | `debug` enabled | `info` and above |
| In-app log viewer access | Always | Always | After unlock code (7 taps on Version) |
| Mock server target available | Yes | No | No |
| Crash on programming errors (`fatalError`/`precondition`) | Yes | Yes (telemetry) | Yes (telemetry only) |

### 5.3 Compilation Conditions

Used sparingly:

```swift
#if DEBUG
let logViewerAlwaysVisible = true
#else
let logViewerAlwaysVisible = false
#endif

#if INTERNAL_TOOLS
let mockServerEnabled = true
#else
let mockServerEnabled = false
#endif
```

Most "is this debug or production" logic is environment-driven, not compile-time. We prefer feature flags read at runtime so we can enable/disable in TestFlight without rebuilding.

### 5.4 Feature Flags

A small `FeatureFlags` struct is read at app start:

```swift
struct FeatureFlags: Sendable {
    let meetingModeEnabled: Bool
    let captureMaxDurationSeconds: Int
    let storagePressureThresholdMB: Int
    let outboxBatchSize: Int

    static let `default` = FeatureFlags(...)
    static let testFlight = FeatureFlags(...)
    static let appStore = FeatureFlags(...)
}
```

Loaded from `Info.plist`, then overridden by Settings → Internal (debug builds only). v1 doesn't have a remote-flags service; values are baked per build.

---

## 6. Code Signing and Distribution

### 6.1 Bundle Identifiers

| Configuration | Bundle ID |
|---|---|
| Debug | `com.<your-org>.lakeloom.dev` |
| Release-TestFlight | `com.<your-org>.lakeloom` (same as App Store; differs only by build number scheme) |
| Release-AppStore | `com.<your-org>.lakeloom` |

Different bundle IDs for Debug and Release allow side-by-side install of dev and prod on the same device. App Store Connect tracks only the production bundle ID.

### 6.2 fastlane

A `Fastfile` defines lanes:

| Lane | Action |
|---|---|
| `fastlane match_dev` | Sync development certificates |
| `fastlane match_appstore` | Sync App Store certificates |
| `fastlane test` | Run unit + UI tests on a clean simulator |
| `fastlane beta` | Build, sign, upload to TestFlight |
| `fastlane release` | Build, sign, submit to App Store |

`Match` keeps signing identities in a private git repo. New developers run `fastlane match_dev` once and have working signing.

### 6.3 Privacy Manifest

`PrivacyInfo.xcprivacy` declares:

- **Data collected:** None for analytics (we don't collect for analytics in v1). Audio + transcripts are user-generated content sent only to the user's own Databricks workspace, which is "linked to user" but not "collected by us."
- **Required reason APIs:** `UserDefaults` (CA92.1: app functionality), `FileTimestamp` (DDA9.1: app functionality), `SystemBootTime` (35F9.1: measure time), `DiskSpace` (E174.1: app functionality)
- **Tracking:** None
- **Tracking domains:** None

Every framework and SDK we link declares its own manifest; Apple validates the merged manifest at submission.

### 6.4 App Privacy Details (App Store)

What we declare on the App Store privacy nutrition label:

| Data type | Linked to user | Used for tracking | Purposes |
|---|---|---|---|
| Audio data | Yes | No | App functionality |
| User content (transcripts) | Yes | No | App functionality |
| Identifiers (user ID, device ID) | Yes | No | App functionality |
| Diagnostics (crash data, performance data) | No | No | App functionality |

---

## 7. Testing Strategy

### 7.1 Test Types

| Layer | Framework | Purpose | Speed |
|---|---|---|---|
| Unit tests | XCTest / Swift Testing | Per-module logic | <100 ms each, <30 s total |
| Integration tests | Swift Testing + mock server | Multi-module flows | <1 s each, <2 min total |
| Snapshot tests | swift-snapshot-testing | View regression | <500 ms each |
| UI tests (XCUITest) | XCTest | End-to-end smoke | ~30 s each, ~5 min total |

### 7.2 Swift Testing Migration

We use [Swift Testing](https://developer.apple.com/xcode/swift-testing/) (the `@Test` macro framework) for new tests, with XCTest still acceptable for existing test patterns that are awkward in Swift Testing (notably XCUITest, which remains XCTest-based).

```swift
import Testing

@Suite("ChunkAssembler — Quick Capture")
struct ChunkAssemblerQuickCaptureTests {
    @Test("Empty session emits an empty chunk")
    func emptySessionEmitsEmptyChunk() async throws {
        // ...
    }

    @Test("Multiple finals join with single space")
    func multipleFinalsJoin() async throws {
        // ...
    }
}
```

### 7.3 Test Doubles

Each module's design doc lists the protocols injectable into its actor. The pattern across all modules:

```swift
// Production
let auth = LiveAuthService(oauth: LiveOAuthClient(), keychain: LiveKeychainStore(), ...)

// Test
let auth = LiveAuthService(oauth: FakeOAuthClient(scripted: ...),
                           keychain: InMemoryKeychainStore(),
                           ...)
```

Test doubles are deliberately named `Fake*` (scriptable behavior), `Stub*` (canned responses), or `Mock*` (verifies interactions). The convention isn't enforced rigidly, but the names hint at usage.

### 7.4 Running Tests

| Command | What runs |
|---|---|
| `xcodebuild test -scheme LakeloomApp` | Unit + integration tests |
| `xcodebuild test -scheme LakeloomAppUITests` | UI tests |
| `xcodebuild test -scheme LakeloomApp -only-testing:LakeloomAppTests/AuthTests` | One module's tests |
| `make test` | Everything (CI-equivalent) |

### 7.5 Test Coverage Targets

| Module | Line coverage target |
|---|---|
| AuthService, IngestService, StorageService | 90%+ (critical paths) |
| ProjectService, AppCoordinator | 80%+ |
| CaptureEngine | 70%+ (audio plumbing is hard to unit-test fully; integration tests cover the rest) |
| Persistence | 80%+ |
| UI views | 50%+ (snapshot tests cover the visual side) |

These are guidelines, not gates. The build doesn't fail on coverage; PR review weighs coverage as one signal.

---

## 8. Continuous Integration

### 8.1 GitHub Actions Workflows

#### `pr.yml` — Runs on every pull request

```yaml
on: [pull_request]
jobs:
  build-and-test:
    runs-on: macos-15           # or whatever has Xcode 26
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.0.app
      - name: Cache SPM
        uses: actions/cache@v4
      - name: Lint
        run: ./BuildScripts/lint.sh
      - name: Build (Debug)
        run: xcodebuild build -scheme LakeloomApp -configuration Debug
      - name: Unit + integration tests
        run: xcodebuild test -scheme LakeloomApp -destination 'platform=iOS Simulator,name=iPhone 16'
      - name: Snapshot tests
        run: xcodebuild test -scheme LakeloomApp -only-testing:LakeloomAppTests/Snapshots
      - name: UI smoke tests
        run: xcodebuild test -scheme LakeloomAppUITests -destination 'platform=iOS Simulator,name=iPhone 16'
```

Required to pass for merge. Typical run time: ~10 minutes.

#### `nightly.yml` — Runs every night

- Full integration suite against a real test Databricks workspace (using a service-principal token that's tightly scoped)
- Performance benchmarks (capture engine throughput, outbox drain rate)
- Static analysis (Periphery for unused code, swift-format strict mode)
- Dependency audit (CVE check on SPM packages)

#### `release.yml` — Triggered on git tag `v*`

- Build with Release-AppStore configuration
- Run `fastlane release`
- Upload .xcarchive as a workflow artifact

### 8.2 Signing in CI

CI authenticates to `Match`'s private repo via a deploy key stored in GitHub Secrets. The keychain is recreated per CI run with `match`'s `--readonly` mode.

App Store Connect API key (also a GitHub Secret) authorizes upload to TestFlight / App Store.

### 8.3 Required Status Checks

Branch protection on `main`:
- Build + test must pass
- At least one approving code review
- No failing required checks
- Branch up to date with `main`

---

## 9. Linting and Formatting

### 9.1 SwiftLint

Standard ruleset with a few additions:

```yaml
# .swiftlint.yml
opt_in_rules:
  - empty_count
  - empty_string
  - first_where
  - sorted_imports
  - explicit_init
  - prefer_self_type_over_type_of_self
  - unused_import
  - convenience_type

disabled_rules:
  - identifier_name           # we accept short names like `id`, `ws`
  - line_length               # too noisy; we use swift-format for this

custom_rules:
  no_print:
    name: "Avoid print()"
    regex: "(^|\\s)print\\("
    message: "Use AppLogger, not print()"
    severity: error

  no_userdefaults_for_tokens:
    name: "Tokens never go in UserDefaults"
    regex: "UserDefaults.*(token|secret|password)"
    message: "Tokens belong in Keychain only"
    severity: error
```

### 9.2 swift-format

For consistent code style. Configuration in `.swift-format`. Run pre-commit (via a git hook installed by `make setup`) and verified in CI.

### 9.3 Pre-Commit Hook

Installed by `make setup`. Runs:
- swift-format on staged Swift files
- swiftlint on staged files
- A custom check: any commit touching log call sites verifies no token/transcript content is logged

---

## 10. Developer Onboarding

### 10.1 Prerequisites

- macOS 15 or later
- Xcode 26 (or whatever ships SpeechAnalyzer for iOS 26)
- Homebrew
- Git

### 10.2 First-Time Setup

```bash
git clone git@github.com:<your-org>/lakeloom-ios.git
cd lakeloom-ios
make setup
```

`make setup` runs:

1. `brew bundle` — installs swiftlint, swift-format, fastlane, xcbeautify
2. `bundle install` — installs Ruby dependencies (fastlane plugins)
3. `fastlane match_dev` — syncs signing certificates (developer must have access to the match repo)
4. `swift package resolve` — resolves SPM dependencies
5. `./BuildScripts/install-precommit-hook.sh` — sets up pre-commit hook
6. Opens `LakeloomApp.xcodeproj` in Xcode

Total time: ~20 minutes (mostly Xcode + SPM download).

### 10.3 Running Locally

The Debug configuration points to a development Databricks OAuth app (separate from production). Developers sign in with their own Databricks workspace; the OAuth flow uses the dev client_id.

### 10.4 Documentation

- `README.md` — overview and quickstart
- `docs/developer-onboarding.md` — detailed onboarding
- `docs/ios-app-architecture.md` — architecture overview (Module 0)
- `docs/module-XX-*.md` — per-module design docs (the docs we've produced)
- `docs/runbooks/` — operational guides (release process, incident response)
- `docs/decisions/` — Architecture Decision Records (ADRs) for significant choices

---

## 11. Release Process

### 11.1 Version Numbering

`MARKETING_VERSION` follows semver: `MAJOR.MINOR.PATCH` (e.g., `1.0.0`). Bumped via `agvtool` integrated into `fastlane release`.

`CURRENT_PROJECT_VERSION` (build number) is monotonically increasing across all builds: TestFlight build 142, 143, 144, ..., App Store release uses build 200. The build number resets only on major version bump.

### 11.2 Release Cadence

- **TestFlight:** weekly automated builds from `main` after Friday close, signed and uploaded by `nightly.yml` running `fastlane beta`
- **App Store:** every 2-4 weeks, gated on TestFlight feedback and product approval

### 11.3 Release Checklist

A `release.yml.template` checklist file is duplicated per release:

- [ ] Version number bumped
- [ ] CHANGELOG updated
- [ ] App Store metadata updated (screenshots, description, what's new)
- [ ] Privacy manifest reviewed
- [ ] No new third-party dependencies without security review
- [ ] Performance benchmarks not regressed (compared to last release)
- [ ] Crash-free session rate >99.5% on previous TestFlight build
- [ ] All P0/P1 bugs closed
- [ ] Release notes drafted

### 11.4 Rollout

App Store releases use **phased release**: 1% on day 1, 2% day 2, 5%, 10%, 20%, 50%, 100% over 7 days. Allows a halt-rollout response if a crash spike emerges.

### 11.5 Rollback

If a critical bug ships to App Store:
- Pause phased release (App Store Connect)
- Either hotfix forward (preferred) or remove from sale (last resort)
- Communicate via in-app message (not in v1; for now, App Store description update)

---

## 12. Out of Scope for v1

- **iPad-specific build target.** Universal binary only; iPad runs the iPhone layout.
- **Mac Catalyst target.** Not in v1.
- **App Clip.** Not in v1.
- **Widget extension.** Not in v1.
- **Notification Service Extension.** Not in v1.
- **CocoaPods support.** SPM only.
- **Server-driven feature flags.** Build-time only.
- **Multi-region / multi-language App Store listings.** US English only in v1.

---

## 13. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Whether to extract `LakeloomTelemetry` and `LakeloomPersistenceCore` as local SPM packages from day 1 or after some code lands | Default: in-app target for v1; revisit at v1.x for clean re-use across iPad |
| 2 | Whether to use Periphery for unused-code detection in CI | Add to nightly; not in PR pipeline (too noisy) |
| 3 | Snapshot test strategy: store images in repo or a separate Git LFS / cloud storage | v1: in repo (size manageable). Revisit at v1.x. |
| 4 | iOS Simulator vs real device for nightly performance benchmarks | Default: simulator (deterministic). Add real-device runs ad-hoc when investigating perf issues. |
| 5 | Whether `make setup` should support Linux for CI machines | v1: macOS only. CI is macOS only by necessity for iOS builds. |
| 6 | Dev OAuth app vs prod OAuth app — separate Databricks workspace registrations | Yes, separate. Dev app's client_id is in Debug config; never reaches App Store. |
| 7 | TestFlight external testing group composition (size, tester selection) | Out of scope for engineering doc; product-owned |
| 8 | Branch model — trunk-based vs git-flow | v1: trunk-based with short-lived feature branches. Documented in CONTRIBUTING.md |

---

## 14. Summary — What "Done" Looks Like for v1

When all 10 modules are implemented to their design specs, v1 ships with:

- A native iOS 26+ app with onboarding, capture, sessions, settings
- Quick Capture mode with on-device transcription
- Live transcript streaming to ZeroBus
- Wi-Fi-gated audio upload to Unity Catalog Volumes
- Multi-workspace OAuth U2M authentication
- Project management via Databricks SQL
- Local persistence with crash recovery
- Comprehensive observability (logs, metrics, support bundle)
- A test suite covering critical paths
- A CI pipeline that gates merges
- A repeatable release process to TestFlight and App Store

The schema, capture engine, chunk assembler, and ingest paths are all designed to support Meeting Mode without breaking changes — that becomes the v1.x release.

The downstream Databricks side (Spark Declarative Pipeline, silver/gold tables, Agent for requirements + architecture + Genie Code plans) is the natural next design effort.
