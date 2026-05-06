# Module 05 — AppCoordinator + Onboarding Flow

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** AuthService (Module 01), CaptureEngine (Module 02), IngestService (Module 03), StorageService (Module 04), ProjectService (Module 06 — referenced here, designed there)
**Depended on by:** SwiftUI views (Home, Settings, Sessions, Onboarding screens)

---

## 1. Purpose

AppCoordinator is the top-level state holder and navigation arbiter for the app. It owns:

- The **app phase** state machine: cold start → recovering → onboarding → ready → backgrounded → terminating
- The **current session context**: which user, workspace, and project are active
- **Navigation state** for the root flow (which screen the user sees at the top level)
- **Cross-service orchestration**: starting the four service modules in the right order, propagating sign-in / sign-out / workspace-switch events, blocking workspace switches during active capture
- **Permission orchestration**: requesting microphone and speech permissions at the right moment, with the right rationale
- The **onboarding flow** as a sequenced state machine

AppCoordinator does **not** own UI — SwiftUI views observe its published state. It does not perform domain work — it composes the four service modules. It does not own per-screen state — child view models do. It is intentionally a thin orchestrator with strict responsibilities.

The onboarding flow is the most user-visible part of this module: consent → workspace URL → OAuth login → identity confirmation → project selection → mic permission → home. Each step is an explicit state with explicit transitions.

---

## 2. Design Principles

1. **Single source of truth for app state.** No other module exposes "is the user signed in?" or "what's the active project?" — they ask AppCoordinator.
2. **Phases are explicit and observable.** SwiftUI views switch on `AppPhase`; transitions trigger animations. There is no implicit "ready" state.
3. **Onboarding is a state machine, not a view stack.** The current step is data; the view layer renders it. Back/forward navigation is a state transition, not a navigation push/pop.
4. **Service start order is enforced.** AuthService → SessionRecordStore (Core Data) → IngestService → StorageService → CaptureEngine. Each waits for prerequisites; failures cascade to a recoverable error state.
5. **Permissions are deferred until they make sense in context.** Microphone is requested at first capture, not during onboarding. Speech recognition is requested when the model is being prepared (first capture). Notifications (future) only when needed.
6. **Active capture locks workspace and project.** A user cannot switch workspace, change project, or sign out while a capture session is in progress. The UI reflects this with disabled controls; AppCoordinator enforces it at the action layer.
7. **Recovery happens before UI.** All four services run their recovery passes during the `recovering` phase, before any user-facing screen renders. The user never sees a "loading uploads from previous session" flicker.
8. **Sign-out is cooperative.** Sign-out cancels in-flight work in IngestService, StorageService, and CaptureEngine, then clears AuthService credentials. It does not race.
9. **Onboarding is interruptible and resumable.** A force-quit during onboarding lands the user back at the same step on next launch, not at the start.
10. **The coordinator is observable, not opaque.** A diagnostics view in Settings can introspect coordinator state for debugging.

---

## 3. Public Surface

### 3.1 The Coordinator Type

```swift
@MainActor
@Observable
final class AppCoordinator {
    // Top-level phase
    private(set) var phase: AppPhase = .coldStart

    // Active context (nil before onboarding completes)
    private(set) var activeContext: ActiveContext?

    // Onboarding state (nil when not in .onboarding phase)
    private(set) var onboarding: OnboardingState?

    // Navigation root (nil before .ready)
    private(set) var rootRoute: RootRoute?

    // Active capture session, if any
    private(set) var activeCaptureSession: SessionHandle?

    // Sign-out / sign-in / switch in progress
    private(set) var transitioning: TransitionKind?

    // Last error surfaced to the user (one-shot; consumed by views)
    private(set) var lastError: AppError?

    // ---- Lifecycle ----
    func bootstrap() async                        // call from App's onAppear
    func handleScenePhaseChange(_ phase: ScenePhase) async
    func handleBackgroundURLSessionLaunch(identifier: String,
                                          completionHandler: @escaping () -> Void) async

    // ---- Onboarding actions ----
    func acknowledgeConsent() async
    func submitWorkspaceURL(_ urlString: String) async
    func startOAuthSignIn(presenting: ASWebAuthenticationPresentationContextProviding) async
    func selectProject(_ projectID: String) async
    func createProject(name: String, description: String?) async
    func grantMicrophonePermission() async         // user tapped "Allow" in our pre-prompt
    func skipOptionalOnboardingStep() async
    func goBackInOnboarding() async

    // ---- Steady-state actions ----
    func switchWorkspace(to workspaceID: String) async throws
    func switchProject(to projectID: String) async throws
    func signOut(workspaceID: String) async throws
    func signOutAll() async throws
    func startQuickCapture() async throws -> SessionHandle
    func endQuickCapture() async                   // button release / stop tapped
    func consumeError() -> AppError?               // one-shot error read for views
}
```

### 3.2 Value Types

```swift
enum AppPhase: Sendable, Equatable {
    case coldStart                                 // before bootstrap()
    case recovering                                // running recovery passes
    case onboarding                                // OnboardingState carries the step
    case preparingReady                            // services starting, project loaded
    case ready                                     // home screen visible, ready to capture
    case capturing(SessionHandle)                  // active capture session
    case backgrounded                              // app in background
    case error(AppError)                           // unrecoverable; user needs to act
}

struct ActiveContext: Sendable, Equatable {
    let user: UserIdentity
    let workspace: WorkspaceCredential
    let project: ProjectMetadata
    let establishedAt: Date
}

enum OnboardingState: Sendable, Equatable {
    case consent
    case workspaceURL(prefill: String?)
    case oauthLogin(workspaceURL: URL, inProgress: Bool, lastError: String?)
    case identityConfirmation(WorkspaceCredential)         // "Logged in as [Display Name]"
    case projectPicker(workspace: WorkspaceCredential,
                       projects: [ProjectMetadata],
                       loading: Bool,
                       lastError: String?)
    case projectCreate(workspace: WorkspaceCredential,
                       inProgress: Bool,
                       lastError: String?)
    case microphonePrePrompt                                // our explanation before OS prompt
    case finalizingOnboarding                                // brief; services starting up
}

enum RootRoute: Sendable, Equatable {
    case home
    case sessions
    case settings
}

enum TransitionKind: Sendable, Equatable {
    case signingIn
    case signingOut(workspaceID: String)
    case switchingWorkspace(toID: String)
    case switchingProject(toID: String)
}

enum AppError: Error, Sendable, Equatable {
    case bootstrapFailed(reason: String)
    case authError(AuthError)
    case projectFetchFailed(reason: String)
    case projectCreateFailed(reason: String)
    case capturePreflightFailed(CaptureError)
    case workspaceSwitchBlockedByActiveCapture
    case projectSwitchBlockedByActiveCapture
    case signOutBlockedByActiveCapture
    case unknown(reason: String)
}
```

### 3.3 ProjectMetadata (referenced; defined in Module 06)

```swift
struct ProjectMetadata: Sendable, Equatable, Identifiable {
    let id: String                    // project_id (UUIDv7)
    let name: String
    let description: String?
    let workspaceID: String
    let createdByUserID: String
    let createdByUsername: String
    let createdAt: Date
    let updatedAt: Date
    let archived: Bool
}
```

---

## 4. The App Phase State Machine

```
                ┌────────────┐
                │ coldStart  │
                └─────┬──────┘
                      │ bootstrap()
                      ▼
                ┌────────────┐
                │ recovering │── recovery pass complete + has active workspace + project ──►  preparingReady
                └─────┬──────┘
                      │ no active workspace OR no project
                      ▼
                ┌────────────┐
                │ onboarding │── completes ──►  preparingReady
                └─────┬──────┘
                      │ user signs out from settings later
                      │
                ┌─────▼──────────┐
                │ preparingReady │── services started ──►  ready
                └─────┬──────────┘
                      │
                      ▼
                  ┌───────┐
            ┌────►│ ready │◄─────────────────┐
            │     └───┬───┘                  │
            │         │ startQuickCapture()  │
            │         ▼                      │
            │   ┌──────────┐                 │
            │   │capturing │── endQuick ─────┘
            │   └──────────┘
            │
            │ scene → background
            ▼
      ┌────────────┐
      │backgrounded│── scene → foreground ─► (return to prior phase)
      └────────────┘

  any phase ── unrecoverable error ──► error
```

### 4.1 Phase Invariants

| Phase | Services started? | Active context required? | UI rendered? |
|---|---|---|---|
| `coldStart` | No | No | Splash |
| `recovering` | Auth + persistence only | No | Splash |
| `onboarding` | Auth started; others not | No | Onboarding |
| `preparingReady` | All starting | Yes | Splash → fade |
| `ready` | All running | Yes | Root |
| `capturing` | All running; CaptureEngine active | Yes | Root + capturing UI |
| `backgrounded` | All running (limited) | Yes | None |
| `error` | Variable | Variable | Error screen |

The invariants are enforced inside the coordinator: state transitions are atomic and the coordinator panics (debug) or recovers (release) if a transition violates them.

---

## 5. Bootstrap Sequence

`bootstrap()` is called once from the SwiftUI `App`'s `task { }` modifier or scene-phase observer. It runs the recovery passes and decides the next phase.

```swift
@MainActor
func bootstrap() async {
    guard phase == .coldStart else { return }
    phase = .recovering

    do {
        // 1. Initialize the Core Data stack (shared by IngestService outbox + StorageService).
        try await coreDataStack.initialize()

        // 2. Load AuthService state from Keychain.
        await auth.start()

        // 3. Run recovery passes. These are independent and can run in parallel.
        async let ingestRecovery: Void = ingest.runRecoveryPass()
        async let storageRecovery: Void = storage.runRecoveryPass()
        async let captureRecovery: Void = capture.runRecoveryPass()
        _ = try await (ingestRecovery, storageRecovery, captureRecovery)

        // 4. Decide next phase.
        guard let workspace = await auth.activeWorkspace else {
            // No active workspace → onboarding.
            await beginOnboarding(at: .consent)
            return
        }
        // We have a workspace. Do we have a default project?
        let defaultProject = await projects.defaultProject(workspaceID: workspace.id)
        guard let project = defaultProject else {
            // Workspace but no project → project picker step of onboarding.
            await beginOnboarding(at: .projectPicker(
                workspace: workspace,
                projects: [],
                loading: true,
                lastError: nil
            ))
            await loadProjectsForOnboarding(workspace: workspace)
            return
        }
        // Full context.
        activeContext = ActiveContext(
            user: workspace.user,
            workspace: workspace,
            project: project,
            establishedAt: Date()
        )
        await transitionToReady()
    } catch {
        phase = .error(.bootstrapFailed(reason: error.localizedDescription))
    }
}
```

### 5.1 `transitionToReady()`

```swift
@MainActor
private func transitionToReady() async {
    phase = .preparingReady

    // Start the services that need an active context.
    await ingest.start()
    await storage.start()
    // CaptureEngine doesn't need to "start" — it's pull-driven from session calls.

    // Subscribe to event streams that drive UI status.
    ingestStatusTask = Task { await observeIngestStatus() }
    storageStatusTask = Task { await observeStorageStatus() }
    captureEventsTask = Task { await observeCaptureEvents() }
    authEventsTask = Task { await observeAuthEvents() }

    rootRoute = .home
    phase = .ready
}
```

The four `observe*` tasks are long-running listeners that translate domain events into coordinator state updates and one-shot error surfacing.

---

## 6. Onboarding Flow — The State Machine

Onboarding is itself a state machine, observed by SwiftUI views. Each state owns its inputs and outputs; transitions are explicit method calls on AppCoordinator.

### 6.1 Step Sequence (Happy Path)

```
consent
  └─► workspaceURL
        └─► oauthLogin (in progress / error / success)
              └─► identityConfirmation
                    └─► projectPicker
                          ├─► [select existing] ─┐
                          └─► projectCreate ─────┤
                                                 ▼
                                          microphonePrePrompt
                                                 ▼
                                          finalizingOnboarding
                                                 ▼
                                              (ready)
```

### 6.2 Step Details

#### `consent`
- View shows: app purpose, what's recorded, where it goes, link to privacy policy
- Input: tap "I understand" → `acknowledgeConsent()`
- Action: persist consent version + timestamp to UserDefaults; advance to `workspaceURL`
- The consent version is later embedded in every ZeroBus record's headers

#### `workspaceURL(prefill:)`
- View shows: text field for `acme-prod.cloud.databricks.com`, helper text, "Continue" button
- Input: `submitWorkspaceURL("...")`
- Action: `AuthService` validates and probes the OIDC discovery endpoint
- On success: advance to `oauthLogin`
- On failure: stay on this step with an inline error

```swift
func submitWorkspaceURL(_ urlString: String) async {
    guard case .onboarding = phase, case .workspaceURL = onboarding else { return }
    let normalized = WorkspaceURLNormalizer.normalize(urlString)
    do {
        try await auth.validateWorkspaceURL(normalized)
        onboarding = .oauthLogin(workspaceURL: normalized, inProgress: false, lastError: nil)
    } catch let error as AuthError {
        onboarding = .workspaceURL(prefill: urlString)
        lastError = .authError(error)
    } catch {
        onboarding = .workspaceURL(prefill: urlString)
        lastError = .unknown(reason: error.localizedDescription)
    }
}
```

#### `oauthLogin(workspaceURL:inProgress:lastError:)`
- View shows: workspace URL display, "Sign in with Databricks" button, error banner if applicable
- Input: tap → `startOAuthSignIn(presenting:)`
- Action: present `ASWebAuthenticationSession` via AuthService, await completion
- On success: AuthService returns a `WorkspaceCredential` with identity already fetched; advance to `identityConfirmation`
- On user cancellation: stay; show no error
- On error: stay with inline error
- On `AuthError.refreshFailed` mid-flow (shouldn't happen here — first login has no prior token): treat as fresh login required

```swift
func startOAuthSignIn(presenting: ASWebAuthenticationPresentationContextProviding) async {
    guard case .onboarding(let step) = phase,
          case .oauthLogin(let url, _, _) = step else { return }
    onboarding = .oauthLogin(workspaceURL: url, inProgress: true, lastError: nil)
    do {
        let credential = try await auth.signIn(workspaceURL: url, presenting: presenting)
        onboarding = .identityConfirmation(credential)
    } catch AuthError.userCancelled {
        onboarding = .oauthLogin(workspaceURL: url, inProgress: false, lastError: nil)
    } catch {
        onboarding = .oauthLogin(
            workspaceURL: url,
            inProgress: false,
            lastError: error.localizedDescription
        )
    }
}
```

#### `identityConfirmation(WorkspaceCredential)`
- View shows: "Logged in as [Display Name] ([userName])" with workspace name + URL, "Continue" button, "Use a different account" button
- Input: tap "Continue" → fetch projects for the workspace, advance to `projectPicker`
- Input: tap "Use a different account" → sign out and return to `workspaceURL`

#### `projectPicker(workspace:projects:loading:lastError:)`
- View shows: list of projects, search bar, "+ New Project" button at the top, refresh control
- On entry: triggers `loadProjectsForOnboarding(workspace:)` which calls `ProjectService.list(workspaceID:)`
- Input: tap a project → `selectProject(projectID)` → advance to `microphonePrePrompt`
- Input: tap "+ New Project" → advance to `projectCreate`
- Input: pull-to-refresh → reload list

#### `projectCreate(workspace:inProgress:lastError:)`
- View shows: name field (required), description field (optional), "Create" button, "Cancel" button
- Input: tap "Create" → `createProject(name:description:)`
- Action: call `ProjectService.create(...)` which writes to `main.lakeloom.projects`
- On success: select the newly created project, advance to `microphonePrePrompt`
- On failure: stay with inline error
- Cancel → return to `projectPicker`

#### `microphonePrePrompt`
- View shows: large icon, "We'll listen only when you press the capture button" explanation, "Continue" button
- This is a **soft** pre-prompt — the OS dialog appears only on first capture (deferred). The pre-prompt's job is to set expectations so the user is more likely to grant permission later.
- Input: tap "Continue" → `grantMicrophonePermission()` (poorly named — it doesn't actually request the OS prompt; it just closes the pre-prompt and advances)
- Advance to `finalizingOnboarding`

#### `finalizingOnboarding`
- View shows: progress spinner, "Setting things up..."
- Action:
  1. Set the chosen project as default for this workspace (via ProjectService)
  2. Build `ActiveContext`
  3. Call `transitionToReady()`
- Brief; usually <500ms. The view exists to avoid a jarring jump.

### 6.3 Resumability

Onboarding state is **not** persisted. If the user force-quits during onboarding:
- If they had completed OAuth (workspace credential is in Keychain) → next launch resumes at `projectPicker`
- If they had selected a project but not finished → next launch resumes at `microphonePrePrompt` if a default project was already saved, else `projectPicker`
- Otherwise → restart at `consent` (cheap; ~10 seconds for the user)

This keeps the resumability rules simple: only durable side effects (Keychain credential, default project) drive resume.

### 6.4 Backward Navigation

`goBackInOnboarding()` allowed only at `workspaceURL` (no-op, it's the start), `oauthLogin` (back to `workspaceURL`), `identityConfirmation` (signs out and back to `workspaceURL`), `projectPicker` (warning: signs out), `projectCreate` (back to `projectPicker`), `microphonePrePrompt` (back to `projectPicker`).

Back from `consent` exits the app (or no-op).

---

## 7. Steady-State Actions

### 7.1 Switching Workspace

```swift
func switchWorkspace(to workspaceID: String) async throws {
    guard activeCaptureSession == nil else {
        throw AppError.workspaceSwitchBlockedByActiveCapture
    }
    transitioning = .switchingWorkspace(toID: workspaceID)
    defer { transitioning = nil }

    try await auth.switchWorkspace(to: workspaceID)
    let workspace = try await auth.activeWorkspace.requireUnwrap()

    // Pause services briefly. They don't need a hard restart — they re-authenticate via AuthService
    // on the next request — but we do need to refresh the active project for this workspace.
    let project = try await projects.defaultProject(workspaceID: workspace.id)
        ?? projects.firstAvailableProject(workspaceID: workspace.id)

    if let project {
        activeContext = ActiveContext(
            user: workspace.user,
            workspace: workspace,
            project: project,
            establishedAt: Date()
        )
        // No phase change needed — we're already in .ready.
    } else {
        // Need to onboard a project for this workspace.
        await beginOnboarding(at: .projectPicker(
            workspace: workspace,
            projects: [],
            loading: true,
            lastError: nil
        ))
    }
}
```

Notable: services are **not** torn down on workspace switch. IngestService and StorageService key all their work by `workspaceID`, and pending uploads/sends for the old workspace continue draining in the background. AuthService's `events` stream notifies them of the active-workspace change.

### 7.2 Switching Project

```swift
func switchProject(to projectID: String) async throws {
    guard activeCaptureSession == nil else {
        throw AppError.projectSwitchBlockedByActiveCapture
    }
    transitioning = .switchingProject(toID: projectID)
    defer { transitioning = nil }

    let workspace = try requireActiveContext().workspace
    let project = try await projects.fetch(projectID: projectID, workspaceID: workspace.id)
    activeContext?.project = project
    try await projects.setDefault(projectID: projectID, workspaceID: workspace.id)
}
```

Trivial: change the project field on `ActiveContext`. The next capture session uses the new project.

### 7.3 Sign Out

```swift
func signOut(workspaceID: String) async throws {
    guard activeCaptureSession == nil else {
        throw AppError.signOutBlockedByActiveCapture
    }
    transitioning = .signingOut(workspaceID: workspaceID)
    defer { transitioning = nil }

    // Cooperative drain: give IngestService and StorageService a chance to flush pending work
    // for this workspace before invalidating the token.
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await self.ingest.flush(workspaceID: workspaceID, timeout: 5.0) }
        group.addTask { await self.storage.pause(workspaceID: workspaceID) }
        await group.waitForAll()
    }

    try await auth.signOut(workspaceID: workspaceID)

    // Decide next state.
    if let nextActive = await auth.activeWorkspace {
        // Promote the next workspace.
        let project = await projects.defaultProject(workspaceID: nextActive.id)
        if let project {
            activeContext = ActiveContext(
                user: nextActive.user,
                workspace: nextActive,
                project: project,
                establishedAt: Date()
            )
        } else {
            await beginOnboarding(at: .projectPicker(
                workspace: nextActive, projects: [], loading: true, lastError: nil
            ))
        }
    } else {
        activeContext = nil
        await beginOnboarding(at: .consent)
    }
}
```

### 7.4 Sign Out All

Calls `signOut(workspaceID:)` for each workspace in sequence. Lands the user at `consent`.

### 7.5 Starting Quick Capture

```swift
func startQuickCapture() async throws -> SessionHandle {
    let context = try requireActiveContext()
    guard activeCaptureSession == nil else { throw AppError.unknown(reason: "session already active") }

    // Pre-flight permissions.
    try await ensureMicrophonePermission()
    try await ensureSpeechPermission()

    let request = CaptureRequest(
        mode: .quickCapture,
        projectID: context.project.id,
        workspaceID: context.workspace.id,
        userIdentity: context.user,
        workspaceMetadata: WorkspaceMetadata(from: context.workspace),
        consentVersion: ConsentVersion.current,
        consentAcknowledgedAt: ConsentVersion.acknowledgedAt!
    )
    let handle = try await capture.startSession(request)
    activeCaptureSession = handle
    phase = .capturing(handle)
    return handle
}
```

The permission helpers:

```swift
private func ensureMicrophonePermission() async throws {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
        return
    case .denied:
        throw AppError.capturePreflightFailed(.microphonePermissionDenied)
    case .undetermined:
        let granted = await AVAudioApplication.requestRecordPermission()
        if !granted { throw AppError.capturePreflightFailed(.microphonePermissionDenied) }
    @unknown default:
        throw AppError.capturePreflightFailed(.microphonePermissionDenied)
    }
}

private func ensureSpeechPermission() async throws {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
        return
    case .denied, .restricted:
        throw AppError.capturePreflightFailed(.speechPermissionDenied)
    case .notDetermined:
        let status = await SFSpeechRecognizer.requestAuthorization()
        if status != .authorized { throw AppError.capturePreflightFailed(.speechPermissionDenied) }
    @unknown default:
        throw AppError.capturePreflightFailed(.speechPermissionDenied)
    }
}
```

### 7.6 Ending Quick Capture

```swift
func endQuickCapture() async {
    guard case .capturing(let handle) = phase else { return }
    await capture.releaseQuickCaptureButton()        // finalizes chunk, emits sessionEnded
    activeCaptureSession = nil
    phase = .ready
    // Note: we don't await session-end events. CaptureEngine will emit them async,
    // and IngestService/StorageService pick them up via their own subscriptions.
}
```

The release of the button is what causes ChunkAssembler to finalize the chunk with `trigger_reason: user_release`. AppCoordinator doesn't need to wait for the chunk to be sent — that's the outbox's job.

---

## 8. Service Event Subscriptions

AppCoordinator subscribes to four event streams to update its state.

### 8.1 AuthService Events

```swift
private func observeAuthEvents() async {
    for await event in auth.events {
        switch event {
        case .signedOut(let workspaceID):
            // If this was the active workspace and we're not in the middle of an
            // intentional sign-out, treat as forced sign-out (e.g., refresh token expired).
            if activeContext?.workspace.id == workspaceID && transitioning == nil {
                await handleForcedSignOut(workspaceID: workspaceID)
            }
        case .switchedWorkspace, .signedIn, .identityRefreshed:
            // Already handled by the action that caused the event.
            break
        }
    }
}

private func handleForcedSignOut(workspaceID: String) async {
    activeContext = nil
    // Stop active capture if any.
    if activeCaptureSession != nil {
        await capture.stopSession(reason: .interrupted)
        activeCaptureSession = nil
    }
    // Decide next state — same logic as voluntary sign-out.
    if let nextActive = await auth.activeWorkspace {
        await transitionToReadyForWorkspace(nextActive)
    } else {
        await beginOnboarding(at: .consent)
    }
    lastError = .authError(.refreshFailed(reason: "Sign in again required"))
}
```

### 8.2 CaptureEngine Events

AppCoordinator subscribes to `CaptureEngine.events` for one purpose only: detecting unexpected session termination.

```swift
private func observeCaptureEvents() async {
    for await event in capture.events {
        switch event {
        case .sessionEnded(let s) where s.terminationReason == .interrupted:
            if activeCaptureSession?.sessionID == s.sessionID {
                activeCaptureSession = nil
                phase = .ready
                lastError = .unknown(reason: "Capture was interrupted")
            }
        case .error(let captureError):
            if activeCaptureSession != nil {
                activeCaptureSession = nil
                phase = .ready
                lastError = .capturePreflightFailed(captureError)
            }
        default:
            break
        }
    }
}
```

IngestService and StorageService have their own subscriptions to the same stream — multicast supports it.

### 8.3 IngestService and StorageService Status

These streams update view-model-level state, not coordinator-level. AppCoordinator doesn't directly subscribe; the Sessions list view model does. If a system-wide condition emerges (e.g., all workspaces in `waitingForAuth`), we surface it as `lastError`, but in v1 we don't model it.

---

## 9. Scene Phase Handling

```swift
@MainActor
func handleScenePhaseChange(_ scenePhase: ScenePhase) async {
    switch scenePhase {
    case .background:
        previousPhaseBeforeBackground = phase
        phase = .backgrounded
        // Capture mid-session in v1: stop. (Background audio is v1.x.)
        if activeCaptureSession != nil {
            await capture.stopSession(reason: .appBackgrounded)
            activeCaptureSession = nil
        }

    case .active:
        if phase == .backgrounded, let prior = previousPhaseBeforeBackground {
            phase = (prior == .capturing(activeCaptureSession ?? .empty)) ? .ready : prior
            previousPhaseBeforeBackground = nil
        }
        // Refresh project list opportunistically.
        if let workspace = activeContext?.workspace {
            Task { await projects.refreshIfStale(workspaceID: workspace.id) }
        }

    case .inactive:
        // Transient (control center, incoming call). No-op.
        break

    @unknown default:
        break
    }
}
```

### 9.1 Background URLSession Launch

When iOS launches the app silently for a background URLSession event:

```swift
@MainActor
func handleBackgroundURLSessionLaunch(
    identifier: String,
    completionHandler: @escaping () -> Void
) async {
    // We're being launched in the background. Do the minimum needed to deliver
    // events, then call the completion handler. Do NOT bootstrap full UI.
    if phase == .coldStart {
        try? await coreDataStack.initialize()
        await auth.start()
        await storage.start()                        // critical: this attaches to the background URLSession
    }
    storage.handleBackgroundURLSessionEvents(
        identifier: identifier,
        completionHandler: completionHandler
    )
}
```

The bootstrap path here is a deliberate subset: only the services needed to deliver URL session events. The user is not foregrounded; we don't run capture or onboarding logic.

---

## 10. The SwiftUI Integration

### 10.1 App Entry

```swift
@main
struct LakeloomApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var coordinator = AppCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .task { await coordinator.bootstrap() }
                .onChange(of: scenePhase) { _, new in
                    Task { await coordinator.handleScenePhaseChange(new) }
                }
        }
    }
}
```

### 10.2 RootView

```swift
struct RootView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        switch coordinator.phase {
        case .coldStart, .recovering, .preparingReady:
            SplashView()
        case .onboarding:
            OnboardingFlowView(coordinator: coordinator)
        case .ready, .capturing:
            HomeContainerView(coordinator: coordinator)
        case .backgrounded:
            // Renders nothing visible (app is backgrounded), but keeps view tree stable.
            Color.clear
        case .error(let err):
            ErrorScreenView(error: err) {
                Task { await coordinator.bootstrap() }     // retry
            }
        }
    }
}
```

### 10.3 OnboardingFlowView

```swift
struct OnboardingFlowView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        switch coordinator.onboarding {
        case .consent:
            ConsentStepView(onContinue: { Task { await coordinator.acknowledgeConsent() } })
        case .workspaceURL(let prefill):
            WorkspaceURLStepView(prefill: prefill,
                                 onSubmit: { Task { await coordinator.submitWorkspaceURL($0) } })
        case .oauthLogin(let url, let inProgress, let error):
            OAuthLoginStepView(workspaceURL: url, inProgress: inProgress, lastError: error,
                               onSignIn: { provider in Task { await coordinator.startOAuthSignIn(presenting: provider) } })
        case .identityConfirmation(let cred):
            IdentityConfirmationStepView(credential: cred,
                                         onContinue: { /* ... */ },
                                         onUseDifferent: { /* ... */ })
        case .projectPicker(let workspace, let projects, let loading, let error):
            ProjectPickerStepView(workspace: workspace, projects: projects, loading: loading, lastError: error,
                                  onSelect: { id in Task { await coordinator.selectProject(id) } },
                                  onCreate: { /* navigate to create step */ })
        case .projectCreate(let workspace, let inProgress, let error):
            ProjectCreateStepView(workspace: workspace, inProgress: inProgress, lastError: error,
                                  onCreate: { name, desc in Task { await coordinator.createProject(name: name, description: desc) } })
        case .microphonePrePrompt:
            MicrophonePrePromptStepView(onContinue: { Task { await coordinator.grantMicrophonePermission() } })
        case .finalizingOnboarding:
            SplashView()
        case .none:
            EmptyView()
        }
    }
}
```

### 10.4 HomeContainerView

A `TabView` (or a custom switcher if we want a bottom-nav-free experience). The capture button is on the Home tab; the active capture overlay is conditionally rendered when `phase == .capturing(...)`.

---

## 11. Threading and Concurrency

- AppCoordinator is `@MainActor`. All state mutations and view-observable properties happen on the main thread.
- Service calls are `async` and may suspend; SwiftUI animations cooperate with the MainActor model naturally.
- Long-running observation tasks (`observeAuthEvents`, `observeCaptureEvents`) are stored on the coordinator and cancelled on sign-out / sign-out-all.
- The `activeCaptureSession` field is consulted by every steady-state action that should be blocked during capture. Reads/writes are MainActor-isolated.

---

## 12. Test Strategy

### 12.1 Unit Tests

- **Phase transitions:** every documented edge in §4 is exercised; invalid edges throw or no-op
- **Bootstrap routing:** no workspace → onboarding consent; workspace + no project → onboarding project picker; workspace + project → ready
- **Onboarding state machine:** every step's input methods produce expected next state; invalid inputs (e.g., calling `selectProject` while in `consent`) are no-ops
- **Workspace switch during capture:** throws `workspaceSwitchBlockedByActiveCapture`
- **Sign out during capture:** throws `signOutBlockedByActiveCapture`
- **Forced sign-out propagation:** AuthService event triggers active context clear and onboarding return
- **Scene phase transitions:** background during capture stops session; return to foreground restores prior phase
- **Permission flow:** undetermined → request → granted → session starts; denied → throws `microphonePermissionDenied`

### 12.2 Test Seams

```swift
protocol AuthServicing: Sendable { /* Module 01 */ }
protocol CaptureEngineProtocol: Sendable { /* Module 02 */ }
protocol IngestServicing: Sendable { /* Module 03 */ }
protocol StorageServicing: Sendable { /* Module 04 */ }
protocol ProjectServicing: Sendable { /* Module 06 */ }
```

AppCoordinator takes all five as initializer dependencies. Production app wires the live implementations; tests use scripted mocks. A single `AppCoordinator.shared` is convenient for SwiftUI but not required — tests construct fresh coordinators per scenario.

### 12.3 SwiftUI Snapshot Tests

Each onboarding step has a snapshot test rendering with representative state (loading, error, populated). Helps catch UI regressions during the high-iteration onboarding tuning phase.

---

## 13. Observability

- Every phase transition is logged at `info` with old/new phase + reason
- Onboarding step transitions logged at `info`
- Forced sign-out logged at `warning`
- Capture preflight failures logged at `warning` with the specific reason
- A debug-only "App State" view in Settings → Diagnostics shows the live coordinator state (phase, onboarding step, active context, transitioning kind) — useful during development

---

## 14. Out of Scope for v1

- **Deep linking.** A `lakeloom://project/<id>` URL that opens the app to a specific project. v1.x.
- **Multi-window support.** iPad multi-window or stage manager. v2.
- **Tab restoration.** Returning to the same tab after backgrounding. v1 always returns to Home.
- **Onboarding analytics.** Tracking step completion rates. v1.x with the telemetry module (Module 09).
- **Forced re-onboarding.** If the consent version changes server-side, force users through consent again. Mechanism designed-in (consent_version is checked at bootstrap), but no policy for triggering it in v1.
- **Multi-project pinning.** Active project per workspace; switching back to a workspace remembers its last project. v1.x.

---

## 15. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Whether the consent pre-prompt (mic) is required by App Store guidelines or just good UX | Review Apple HIG; pre-prompt is widely accepted as good practice regardless |
| 2 | Default project behavior on workspace switch — auto-pick first vs. prompt | v1 default: first existing project, or onboarding flow if none. Validate with users. |
| 3 | Whether to allow onboarding to skip project creation and land at home with a "select project to start" empty state | v1 design: project is required. Reconsider if it adds friction. |
| 4 | Onboarding back navigation from `oauthLogin` after partial OAuth success but before identity fetch | v1: treat as user cancellation, AuthService cleans up |
| 5 | App-wide "first launch ever" sentinel for Keychain hygiene (deferred from Module 01) | UserDefaults sentinel checked here at bootstrap; clears stale Keychain on fresh install |
| 6 | Behavior when Core Data fails to initialize (corrupt database) | v1: phase → error, offer "Reset app" button that wipes Application Support |
| 7 | Whether to surface "uploads pending" as a banner or pull-to-refresh hint on Home | v1: badge on Sessions tab; no banner. Tunable. |

---

## 16. File Layout (proposed)

```
App/Coordinator/
├── AppCoordinator.swift                    // @MainActor @Observable, public surface
├── AppPhase.swift
├── ActiveContext.swift
├── AppError.swift
├── TransitionKind.swift
├── RootRoute.swift
├── ConsentVersion.swift                    // current consent version + persistence
├── Onboarding/
│   ├── OnboardingState.swift
│   ├── OnboardingActions.swift             // extension on AppCoordinator
│   ├── WorkspaceURLNormalizer.swift
│   └── OnboardingResumability.swift        // decide step on launch
├── ServiceObservers/
│   ├── AuthEventObserver.swift
│   ├── CaptureEventObserver.swift
│   └── ScenePhaseObserver.swift
├── Permissions/
│   ├── MicrophonePermission.swift
│   └── SpeechPermission.swift
└── Diagnostics/
    └── CoordinatorDiagnostics.swift

App/Views/
├── RootView.swift
├── SplashView.swift
├── ErrorScreenView.swift
├── Onboarding/
│   ├── OnboardingFlowView.swift
│   ├── ConsentStepView.swift
│   ├── WorkspaceURLStepView.swift
│   ├── OAuthLoginStepView.swift
│   ├── IdentityConfirmationStepView.swift
│   ├── ProjectPickerStepView.swift
│   ├── ProjectCreateStepView.swift
│   └── MicrophonePrePromptStepView.swift
└── Home/
    ├── HomeContainerView.swift
    ├── CaptureButton.swift
    ├── ActiveContextChips.swift            // current project + workspace display
    └── LiveTranscriptOverlay.swift
```

Tests mirror this layout under `AppTests/Coordinator/`.
