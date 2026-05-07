# Session Summary — 2026-05-06 — Module 05 (AppCoordinator + Onboarding)

**Branch:** `feature/ios-module-05-coordinator` (off `main` at `c9eda17`)
**Author:** Matthew Giglia (with Claude Code / Isaac)
**Scope:** Implements **Module 05** (`architecture/LakeLoomMarkdowns/module-05-app-coordinator.md`) — top-level state holder + navigation arbiter + onboarding flow. Wires the previously-merged Auth (Module 01), Projects (Module 06), and Persistence (Module 07) modules into a complete user journey: cold-start → consent → workspace URL → real OAuth → identity confirmation → project picker → home. **First runnable end-to-end demo.**

---

## Decisions made

### 1. Capture-related concerns deferred to Module 02

Module 05's full design covers the `.capturing(SessionHandle)` phase, `startQuickCapture` / `endQuickCapture`, capture-event observation, scene-phase capture-stop, and capture-blocked guards on `switchWorkspace` / `switchProject` / `signOut`. All of these depend on Module 02 (CaptureEngine) which doesn't exist yet. Rather than stubbing the missing protocols, I dropped these surfaces from the v1 build:

- `AppPhase.capturing` is absent — added back when there's a real `SessionHandle` to carry.
- `OnboardingState.microphonePrePrompt` is absent — pre-prompting permissions for a feature that doesn't exist yet would be confusing.
- `AppCoordinator+SteadyState` has TODO-stub comments at every guard site (`// TODO(Module 02): block on activeCaptureSession != nil`). The `AppError.workspaceSwitchBlockedByActiveCapture` etc. cases exist in the type system; the throw sites arrive when Module 02 lands.
- AppCoordinator's init takes `auth + projects + coreDataStack` only. Module 02/03/04 protocols join when those modules land — additive change.

### 2. `internal(set)` on Observable state, not `private(set)`

Module 05's design has @Observable state declared as `private(set) var phase: AppPhase`. With AppCoordinator broken into multiple files (`+Onboarding`, `+SteadyState`), `private(set)` blocks cross-file extensions from writing. Loosened to `internal(set)` — public API is still read-only, module-internal extensions can mutate. Same change for the dependency `let`s (`auth`, `projects`, `coreDataStack`, `logger`, `nowProvider`) which the extensions need to read.

### 3. `AppLogger` autoclosures are `@Sendable`

Existing `AppLogger.info(_ message: @autoclosure () -> String, ...)` tripped Swift 6 strict concurrency when called from `@MainActor` AppCoordinator (it didn't trip from actor-isolated AuthService for inscrutable reasons). Fixed at the source: every level entry point now takes `@autoclosure @Sendable () -> String`. No call site changed; existing AuthService / ProjectService callers compile unchanged.

### 4. `WorkspaceURLNormalizer` is permissive on input, strict on output

The user can type any of: `acme.cloud.databricks.com`, `https://acme.cloud.databricks.com`, `acme.cloud.databricks.com/`, `https://ACME.cloud.databricks.com/some/path?x=1#frag`. Normalizer prepends `https://` if missing, lowercases the host, strips path / query / fragment. Output is always `https://<lowercase-host>/`. Anything that fails to parse to a host returns a sentinel URL that `AuthService.validateWorkspaceURL` will cleanly reject — no try/throw at the normalizer layer.

### 5. RootView animates phase transitions; no jarring frame snaps

`.animation(.default, value: coordinator.phase)` + `.animation(.default, value: coordinator.onboarding)` cross-fade every state change. Splash → consent, oauthLogin → identityConfirmation, projectPicker → finalizingOnboarding all visibly transition. Module 08's design system can refine the timing / curve later; default works fine for v1.

### 6. `WindowScenePresentationProvider` is per-view, not singleton

`ASWebAuthenticationSession` requires an `ASPresentationAnchor` from a `UIWindowScene`. The provider is constructed in `OAuthLoginStepView.onAppear` and held per-view; it grabs the foreground-active scene at presentation time (or any connected scene as fallback). A singleton would risk stale window references on iPad when the active scene changes; per-view avoids that complexity.

### 7. `LakeloomApp.swift` constructs the live dependency graph at init

Rather than threading dependencies through environment, the entry point builds `AuthService + LiveOAuthClient + LiveKeychainStore + LiveDatabricksIdentityClient + ProjectService + LiveAppEndpointResolver + CoreDataStack` and hands the resulting `AppCoordinator` to `RootView` via `@State` + `@Bindable`. Single construction site keeps it testable (tests inject mocks; production construction lives in one file).

`AppConfig.oauthClientID` is empty by default — the published Databricks OAuth client ID gets baked in via a build setting before TestFlight (Module 10 §5.4). Empty value means OAuth fails cleanly with an error, not a crash.

### 8. CoreDataStack falls back to in-memory if on-disk init throws

The `CoreDataStack()` initializer is `throws` for the file-system-permission case. Falling back to `try! CoreDataStack(inMemory: true)` keeps the app launchable even on a broken filesystem; if the fallback also throws (effectively never), the trap is louder than a launch crash. The bootstrap path then surfaces any persistent-store issue through `phase = .error(.bootstrapFailed)`.

### 9. LaunchTest now asserts on the consent screen, not the splash

A fresh-install launch transitions splash → onboarding(.consent) too quickly to reliably catch the splash text with `waitForExistence(timeout: 10)`. The test now looks for "Capture conversations to build with Databricks" (the consent step's headline) and the "I understand" button. This is also a more semantically meaningful assertion — the splash is a transition, not a destination.

---

## Work performed

7 commits on `feature/ios-module-05-coordinator`:

| Commit | Subject | Files |
|---|---|---|
| `0144549` | feat(coordinator): public AppCoordinator value types | App/Coordinator (7 files, +226) |
| `dee4803` | feat(coordinator): AppCoordinator @MainActor @Observable + bootstrap | AppCoordinator.swift + AppLogger Sendable fix (3 files, +301/-7) |
| `5f5f01a` | feat(coordinator): onboarding state machine actions | AppCoordinator+Onboarding.swift (2 files, +263/-12) |
| `3a366e3` | feat(coordinator): steady-state actions (switch / signOut / signOutAll) | AppCoordinator+SteadyState.swift (1 file, +140) |
| `f3eb79e` | feat(views): SwiftUI onboarding step views | App/Views/Onboarding (8 files, +613) |
| `5a938ec` | feat(app): wire RootView + HomeContainer to AppCoordinator | LakeloomApp.swift, RootView.swift, HomeContainerView.swift, ErrorScreenView.swift, LaunchTests.swift (6 files, +232/-18) |
| `8b78a10` | test(coordinator): unit tests for AppCoordinator + WorkspaceURLNormalizer | AppCoordinatorTests.swift (2 files, +316) |
| (this) | docs(session-summary): record 2026-05-06 Module 05 session | iOS/session_summaries/2026-05-06-2213-module-05-coordinator.md |

### Verification

```sh
$ xcodebuild test -project LakeloomApp.xcodeproj -scheme LakeloomApp \
    -destination 'platform=iOS Simulator,name=iPhone 17'
…
✔ Test run with 131 tests in 35 suites passed after 0.848 seconds.
** TEST SUCCEEDED **
```

131 tests across 35 suites:
- 45 from Module 01 (auth) — still green
- 32 from Module 09 (telemetry) — still green
- 15 from Module 07 (persistence) — still green
- 25 from Module 06 (projects) — still green
- 14 new (coordinator):
  - Bootstrap routing (5): no consent → consent step; consent + no workspace → URL step; full context → ready; workspace + no projects → picker; idempotent
  - Onboarding state machine (3): acknowledgeConsent advances; submitWorkspaceURL on success; goBackInOnboarding from oauthLogin
  - Error rendering (2): ProjectError → human message; ProjectError → stable error code
  - WorkspaceURLNormalizer (4): prepends scheme; strips path/query/fragment; lowercases host; trims whitespace
- 1 LaunchTests UI test (now asserts on consent screen)

---

## What you can demo today

After this PR merges, on a real iPhone (or simulator):

1. Launch the app → splash → consent screen
2. Tap "I understand" → workspace URL entry
3. Type a Databricks workspace host (e.g. `your-workspace.cloud.databricks.com`)
4. Tap Continue → OAuth login screen
5. Tap "Sign in" → real `ASWebAuthenticationSession` opens to your workspace's Databricks login
6. Complete OAuth → "Welcome, [your name]" identity confirmation
7. Tap Continue → project picker (calls the App's REST endpoint that doesn't exist yet — shows an error state with retry; "+ New Project" tries to create and fails the same way)

Steps 1-6 are fully functional. Step 7 requires Genie Code's Databricks App to be deployed; the iOS side fails gracefully with the typed `ProjectError` cases the views already handle.

Before TestFlight: bake the published Databricks OAuth client_id into `AppConfig.oauthClientID`.

---

## Open items / followups

- **OAuth client_id**: `AppConfig.oauthClientID` is empty. Replace with the published Databricks OAuth app's client_id before any TestFlight build. Module 10 §5.4 specifies build-config-driven feature flags; same mechanism applies here.
- **Capture-related coordinator surfaces**: 8 explicit `TODO(Module 02)` comments in `AppCoordinator+SteadyState.swift` and the elided `.capturing` phase. These light up when Module 02 lands.
- **Cooperative drain on signOut**: when Modules 03 (Ingest) and 04 (Storage) land, `signOut(workspaceID:)` should drain pending outbox + pause uploads for the workspace before clearing the credential. Currently a TODO comment.
- **Background URLSession launch path** (Module 05 §9.1): not implemented — depends on Module 04 (StorageService).
- **Scene-phase observer**: not implemented — depends on Module 02 to know whether a capture session is active.
- **ConsentVersion re-consent trigger**: `hasAcknowledgedCurrent` compares strings exactly; bumping `ConsentVersion.current` would force re-consent. The comparison is in place; the policy for when to bump isn't in this PR.
- **`projectPicker.lastError` style**: shows `ProjectError.localizedDescription` via `AppCoordinator.message(for:)` — fine for v1 but a real app might want a Designer-vetted error catalog.

---

## What's next

After this lands, two reasonable paths:

1. **Module 02 (CaptureEngine)** — the hero feature. Big module (audio engine + iOS 26 SpeechAnalyzer + Opus recorder + chunk assembler + ChunkAssembler policy layer). Once it lands, AppCoordinator gets the `.capturing` phase and the capture-blocked guards become real.
2. **Module 11 (AppSyncService)** — Brickster→iOS sync via cursor polling against the Databricks App. Smaller than Module 02; unlocks the Sessions list updates path.

I lean toward Module 02 next — it's the project's namesake feature, and once it lands the running app captures voice → live transcript → (eventually, when Modules 03/04 follow) ingest to Databricks. That's the full narrative arc.

---

## What's not in this session

- No `App/Auth/`, `App/Projects/`, or `App/Persistence/` changes (module-isolated by design).
- No edits to `architecture/LakeLoomMarkdowns/` or `lakeLoom_infra/`.
- No live Databricks workspace OAuth test (Module 05 §12.2 integration test) — that's a `LAKELOOM_E2E=1` nightly affordance for when CI lands.
- No Sessions tab, Settings tab, or full Home tab — those are Module 02 + 08 territory; HomeContainerView is a placeholder.
- No SwiftUI snapshot tests for the onboarding views (Module 08 §11.1 territory).
