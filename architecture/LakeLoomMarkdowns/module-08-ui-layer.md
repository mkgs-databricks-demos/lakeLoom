# Module 08 — UI Layer (SwiftUI Views & View Models)

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** AppCoordinator (Module 05) for app-level state; AuthService (01), CaptureEngine (02), IngestService (03), StorageService (04), ProjectService (06) for screen-specific data
**Depended on by:** End users only

---

## 1. Purpose

The UI Layer is the SwiftUI presentation tier. It owns:

- All views — onboarding, home, sessions list, session detail, settings
- View-model types that adapt service outputs to view-friendly shapes
- Navigation within the app shell (tab structure, push/sheet/cover presentation)
- Live updates from service event streams
- The capture button and live transcript overlay
- Empty states, error states, loading states for every screen
- Accessibility, Dynamic Type, light/dark mode support
- The app's visual language (colors, typography, spacing, components)

The UI Layer is intentionally thin where it can be: services already publish observable state. View-models exist to *adapt* — to combine streams from multiple services, to format strings, to compute derived bindings — not to hold business logic.

---

## 2. Design Principles

1. **State down, actions up.** Every view is a function of its inputs. State lives in `AppCoordinator` or service-owned actors; views observe and dispatch. No view holds canonical state.
2. **One view, one responsibility.** Screens compose smaller component views. A complex screen is many small files, not one large one.
3. **`@Observable`, not `ObservableObject`.** Modern SwiftUI Observation framework throughout. `@Bindable` for two-way bindings. No `@Published` / `Combine` glue.
4. **View-models are `@Observable @MainActor` classes** that own a small slice of derived state. They subscribe to service streams in their `init` or via a `task` modifier and update their published properties on the main actor.
5. **AsyncStream is the integration primitive.** View-models read from service `events` / `status` / `changes` streams via `for await`. SwiftUI's `task(...)` modifier scopes the subscription to the view's lifetime.
6. **Loading / empty / error / content as first-class states.** Every list view enumerates these explicitly — no implicit "empty list looks the same as loading."
7. **Mobile-first layout.** Single-column, generous tap targets (44pt minimum), respects safe areas and Dynamic Type. iPad layout is forward-compatible but not specifically designed for in v1.
8. **Accessibility is required, not optional.** VoiceOver labels, hints, and traits on every interactive element. Dynamic Type up to AX5. Reduced motion honored.
9. **System-styled.** No custom controls where Apple-provided ones suffice. The app feels native because it *is* native.
10. **Capture is the hero.** The capture button is the largest, most prominent UI element. Everything else recedes.

---

## 3. App Shell and Navigation

### 3.1 Top-Level Structure

```
RootView (Module 05)
└── HomeContainerView (when phase == .ready or .capturing)
    └── TabView
        ├── HomeTab        (capture button + recent activity)
        ├── SessionsTab    (history, upload status, filterable list)
        └── SettingsTab    (account, workspaces, projects, storage, diagnostics)
```

### 3.2 Tab Bar

```swift
struct HomeContainerView: View {
    @Bindable var coordinator: AppCoordinator
    @State private var selectedTab: RootRoute = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTabRoot(coordinator: coordinator)
                .tabItem {
                    Label("Capture", systemImage: "mic.circle.fill")
                }
                .tag(RootRoute.home)

            SessionsTabRoot(coordinator: coordinator)
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet.rectangle")
                }
                .badge(pendingSessionsBadge)
                .tag(RootRoute.sessions)

            SettingsTabRoot(coordinator: coordinator)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(RootRoute.settings)
        }
    }
}
```

### 3.3 Within-Tab Navigation

Each tab uses `NavigationStack` with a typed path:

```swift
struct SessionsTabRoot: View {
    @Bindable var coordinator: AppCoordinator
    @State private var path: [SessionsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            SessionsListView(...)
                .navigationDestination(for: SessionsRoute.self) { route in
                    switch route {
                    case .detail(let sessionID):
                        SessionDetailView(sessionID: sessionID)
                    case .uploadDiagnostics(let sessionID):
                        UploadDiagnosticsView(sessionID: sessionID)
                    }
                }
        }
    }
}

enum SessionsRoute: Hashable {
    case detail(sessionID: String)
    case uploadDiagnostics(sessionID: String)
}
```

Push, present-as-sheet, and full-screen-cover are used per Apple HIG conventions: push for hierarchical drilldown, sheet for self-contained tasks, cover only for capture.

### 3.4 Modal Presentation

| Modal | Style | Triggered by |
|---|---|---|
| Active capture overlay | Full-screen cover | Capture button tap |
| Workspace switcher | Sheet | Workspace chip tap |
| Project picker | Sheet | Project chip tap |
| Project create | Sheet (atop picker) | "+ New Project" |
| Sign-in (workspace switch) | Sheet | "Add workspace" in Settings |
| Confirmation dialogs | `.confirmationDialog` | Sign out, reset, archive, delete |

---

## 4. Home Tab — The Hero

### 4.1 HomeTabRoot

Single screen. The capture button dominates. Below it: current project + workspace chips, and a strip of recent sessions.

```
┌───────────────────────────────────────┐
│                                       │
│         ━━━━━━━━━━━━━━━━━━━           │
│         │ Project: ACME Q3│           │  ← chip, tap to change
│         │ Workspace: prod │           │  ← chip, tap to change
│         ━━━━━━━━━━━━━━━━━━━           │
│                                       │
│             ╭─────────╮               │
│             │         │               │
│             │   ●     │               │  ← Capture button (large, ~120pt)
│             │         │               │     "Hold to capture"
│             ╰─────────╯               │
│                                       │
│         Hold to capture               │
│                                       │
│   ─────────────────────────────       │
│   Recent                              │
│   • Today, 2:14 PM    ✓ Synced       │
│   • Today, 11:08 AM   ⏳ Uploading    │
│   • Yesterday         ⚠️ Retry        │
│                                       │
└───────────────────────────────────────┘
```

### 4.2 The Capture Button

The single most important interactive element. Specifications:

- **Size:** 120pt diameter, centered horizontally, vertically biased above the recent strip
- **Idle state:** Filled circle, accent color, microphone glyph (SF Symbol `mic.fill`), subtle inner shadow
- **Pressed state (during press-and-hold):** Slightly enlarged (1.1x), pulse animation at ~1Hz, ring of waveform glyphs animating outward
- **Disabled state:** Grayed out when prerequisites missing (no project, no workspace, no permissions)
- **Haptic feedback:** Medium impact on press-down, light impact on release
- **Accessibility:** Label "Capture", Hint "Press and hold to record. Release to send.", Trait `.startsMediaSession` while pressed

### 4.3 Press-and-Hold Gesture

```swift
struct CaptureButton: View {
    @Bindable var viewModel: HomeViewModel
    @State private var isPressed = false

    var body: some View {
        Circle()
            .fill(buttonColor)
            .frame(width: 120, height: 120)
            .overlay(micIcon)
            .scaleEffect(isPressed ? 1.1 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            Task { await viewModel.startCapture() }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        if isPressed {
                            isPressed = false
                            Task { await viewModel.endCapture() }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Capture")
            .accessibilityHint("Press and hold to record. Release to send.")
            .accessibilityAddTraits(isPressed ? .startsMediaSession : [])
            .disabled(!viewModel.canStartCapture)
    }
}
```

### 4.4 Active Capture Overlay

When a capture session starts, a full-screen cover appears showing:

- Top: workspace + project chips (compact)
- Center: live transcript preview (large, growing as text arrives)
- Below transcript: elapsed-time counter (mm:ss)
- Below time: a row of audio level bars animating to live volume
- Bottom: a large "Release" button with the same press-and-hold gesture (UI mirror of the home button — releasing here ends the session)

If the user swipes down to dismiss the cover, that's treated as a release: capture ends. We don't allow the cover to dismiss without ending the session.

```
┌───────────────────────────────────────┐
│  ACME Q3 · prod                       │
│                                       │
│                                       │
│  "We need to land customer events     │
│   in Unity Catalog with a CDC         │
│   pattern off the operational..."     │  ← live transcript, large text
│                                       │
│                                       │
│           00:14                       │  ← timer
│                                       │
│   ▁▃▅▇▅▃▁▁▃▅                          │  ← live audio levels
│                                       │
│             ╭─────────╮               │
│             │  ● HOLD │               │  ← release button
│             ╰─────────╯               │
│                                       │
└───────────────────────────────────────┘
```

### 4.5 HomeViewModel

```swift
@Observable
@MainActor
final class HomeViewModel {
    // Inputs (injected)
    private let coordinator: AppCoordinator
    private let capture: CaptureEngineProtocol
    private let storage: StorageServicing

    // Published state
    private(set) var canStartCapture: Bool = false
    private(set) var disabledReason: String?
    private(set) var liveTranscript: String = ""
    private(set) var liveAudioLevel: Float = 0.0
    private(set) var elapsedSeconds: Int = 0
    private(set) var recentSessions: [RecentSessionRow] = []

    // Activities
    private var partialsTask: Task<Void, Never>?
    private var elapsedTimerTask: Task<Void, Never>?

    init(coordinator: AppCoordinator, capture: CaptureEngineProtocol, storage: StorageServicing) {
        self.coordinator = coordinator
        self.capture = capture
        self.storage = storage
        observe(coordinator: coordinator)
        loadRecentSessions()
    }

    func startCapture() async {
        do {
            _ = try await coordinator.startQuickCapture()
            partialsTask = Task { [weak self] in
                guard let self else { return }
                for await partial in self.capture.partials {
                    self.liveTranscript = partial.text
                }
            }
            elapsedTimerTask = Task { [weak self] in
                let start = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
            }
        } catch {
            // Surface via coordinator.lastError
        }
    }

    func endCapture() async {
        partialsTask?.cancel(); partialsTask = nil
        elapsedTimerTask?.cancel(); elapsedTimerTask = nil
        await coordinator.endQuickCapture()
        liveTranscript = ""
        elapsedSeconds = 0
        loadRecentSessions()
    }

    private func observe(coordinator: AppCoordinator) {
        // canStartCapture derives from active context + permissions
        // Re-evaluated when coordinator.activeContext or activeCaptureSession changes.
    }
}

struct RecentSessionRow: Identifiable, Sendable, Equatable {
    let id: String                        // sessionID
    let displayTime: String                // "Today, 2:14 PM"
    let durationText: String               // "0:23"
    let projectName: String
    let uploadStateBadge: UploadStateBadge
}

enum UploadStateBadge: Sendable, Equatable {
    case synced
    case uploading(progress: Double)
    case waitingForWifi
    case retrying
    case failed
    case noAudio
}
```

### 4.6 Project + Workspace Chips

Compact pills that show the current selection and tap to swap:

```swift
struct ActiveContextChips: View {
    @Bindable var coordinator: AppCoordinator
    @State private var showingWorkspaceSheet = false
    @State private var showingProjectSheet = false

    var body: some View {
        HStack(spacing: 8) {
            Chip(label: coordinator.activeContext?.project.name ?? "—",
                 icon: "folder",
                 onTap: { showingProjectSheet = true })
                .disabled(coordinator.activeCaptureSession != nil)
            Chip(label: coordinator.activeContext?.workspace.workspaceName ?? "—",
                 icon: "server.rack",
                 onTap: { showingWorkspaceSheet = true })
                .disabled(coordinator.activeCaptureSession != nil)
        }
        .sheet(isPresented: $showingProjectSheet) { ProjectPickerSheet(...) }
        .sheet(isPresented: $showingWorkspaceSheet) { WorkspaceSwitcherSheet(...) }
    }
}
```

Disabled (grayed) during active capture so the user can't accidentally change context mid-session.

---

## 5. Sessions Tab

### 5.1 SessionsListView

A vertically scrolling list of all past sessions, newest first. Each row:

```
┌───────────────────────────────────────┐
│ Today                                 │
│  ─────────────────────────────────    │
│  ● 2:14 PM    0:23   ACME Q3          │
│    ✓ Synced                           │
│  ─────────────────────────────────    │
│  ● 11:08 AM   1:42   ACME Q3          │
│    ⏳ Uploading 67%                   │
│  ─────────────────────────────────    │
│ Yesterday                             │
│  ─────────────────────────────────    │
│  ● 4:30 PM    0:15   ACME Q3          │
│    ⚠️ Retry needed (tap)              │
└───────────────────────────────────────┘
```

Sections by relative day ("Today", "Yesterday", "Last 7 days", "Earlier"). Within a section, newest first.

Filters at the top (collapsible):
- All / Pending uploads / Failed / Synced
- Filter by project (multi-select)
- Filter by workspace (multi-select)

### 5.2 SessionsListViewModel

Combines event streams from IngestService and StorageService:

```swift
@Observable
@MainActor
final class SessionsListViewModel {
    private let ingest: IngestServicing
    private let storage: StorageServicing
    private let projects: ProjectServicing

    private(set) var sections: [SessionListSection] = []
    private(set) var loadingState: LoadingState = .loading
    private(set) var filter: SessionFilter = .all

    func start() async {
        // Initial load
        let allSessions = await storage.pendingUploads() + (try? await fetchHistory()) ?? []
        sections = await groupAndSort(allSessions)
        loadingState = sections.isEmpty ? .empty : .loaded

        // Live updates
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.observeIngestStatus() }
            group.addTask { await self.observeStorageStatus() }
            group.addTask { await self.observeProjectChanges() }
        }
    }
}

enum LoadingState: Sendable {
    case loading
    case empty
    case loaded
    case error(String)
}

struct SessionListSection: Identifiable, Sendable {
    let id: String                       // section header text
    let title: String
    let rows: [SessionListRow]
}

struct SessionListRow: Identifiable, Sendable, Equatable {
    let id: String
    let startedAt: Date
    let displayTime: String
    let durationText: String
    let projectName: String
    let workspaceName: String
    let captureMode: CaptureMode
    let chunkCount: Int
    let uploadState: UploadStateBadge
    let ingestState: IngestStateBadge
}

enum IngestStateBadge: Sendable, Equatable {
    case sending
    case waitingForNetwork
    case waitingForAuth
    case complete
    case partiallyFailed
}
```

### 5.3 SessionDetailView

Drill-down for a single session. Shows:

- Header: project, workspace, started time, duration, capture mode, chunk count
- Section: **Transcript** — concatenated text from all chunks in the session, scrollable, copyable
- Section: **Audio** — local file size, hash, remote path (if uploaded), play button (v1.x), "Force upload over cellular" if waiting
- Section: **Ingest status** — counts (sent / pending / failed / dead-lettered), last error if any, "Retry failed" button
- Section: **Diagnostics** — UUIDs and IDs for support inquiries (long-press to copy)

### 5.4 Empty States

- No sessions yet: large illustration + "Tap and hold the capture button on the home screen to record your first session"
- Filter excludes all sessions: "No sessions match your filter" + "Clear filter" button
- Loading: shimmer placeholder rows (3-4 rows)

---

## 6. Settings Tab

### 6.1 SettingsListView

Organized as a grouped list with sections:

```
Account
  ▶ Signed in as [Display Name]                        [tap → AccountDetailView]

Workspaces
  ▶ ACME Production               (default)            [tap → WorkspaceDetailView]
  ▶ ACME Dev
  ▶ + Add workspace                                    [tap → sign-in flow]

Projects
  ▶ Manage projects                                    [tap → ProjectsManagementView]
  ▶ Default for ACME Production: Customer 360 …        [tap → DefaultPickerView]

Capture
  Default mode             Quick Capture
                            (Meeting Mode coming soon)
  Live transcript preview   ●────  on
  Haptic feedback           ●────  on

Storage & Uploads
  Local audio used          127 MB across 23 sessions
  Wi-Fi upload only         ●────  on  (recommended)
  Retention                 7 days after upload   ▶
  ▶ Manage storage                                     [tap → StorageManagementView]

Privacy
  Consent acknowledged      v1.0  on Apr 15, 2026
  ▶ Privacy policy
  ▶ Open source licenses

Diagnostics
  ▶ Diagnostic info                                    [tap → DiagnosticsView]
  ▶ Reset local data                                   [tap → confirmation]

About
  Version 1.0 (build 142)
```

### 6.2 AccountDetailView

- Avatar (initials in colored circle for v1)
- Display name, username (email), workspace count
- Sign out of all workspaces button (destructive)

### 6.3 WorkspaceDetailView

- Workspace name, URL, cloud, region
- Last signed in, last identity refresh
- Set as default toggle
- Sign out of this workspace (destructive)
- Diagnostic counters per workspace (record counts, upload counts)

### 6.4 ProjectsManagementView

- List of all projects (active section, archived section)
- Search bar at top
- "+ New Project" button
- Per-row: tap → project detail; swipe → archive/unarchive
- Each project's detail view: name, description, created by, created at, sessions associated, archive toggle

### 6.5 StorageManagementView

- Summary: total local storage used, breakdown by workspace
- List of sessions with local audio (sortable by size, age)
- Per-row: tap → session detail; swipe → purge local audio (with confirmation)
- "Purge all uploaded" button (purges all sessions in `uploaded` state regardless of grace period)
- Retention grace period control: 1 day / 7 days / 30 days / "until upload confirmed"
- Storage pressure threshold control: 250 MB / 500 MB / 1 GB / 2 GB
- Wi-Fi upload toggle (overrides default; advanced — with warning)

### 6.6 DiagnosticsView

For technical support and debugging. Shows:

- App version, build, OS version, device model
- Auth: workspace count, last refresh times, refresh failure count
- Capture: total sessions, total chunks, last error
- Ingest: outbox depth, dead-letter depth, lifetime sent/failed
- Storage: local files count, lifetime uploads, lifetime bytes
- Persistence: Core Data store size, WAL size, last migration
- Network: current path, recent disconnect count

"Copy all to clipboard" button at bottom for sharing with support.

---

## 7. Onboarding Views (Module 05 references these)

Each onboarding step is a single SwiftUI view file. The flow itself is driven by AppCoordinator; views are presentation-only.

### 7.1 ConsentStepView

```swift
struct ConsentStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 80))
                .foregroundStyle(.tint)
            Text("Capture conversations to build with Databricks")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("This app records your voice when you press the capture button. Transcripts are sent to your Databricks workspace to help generate requirements and architecture plans for your projects.\n\nAudio stays on your device until Wi-Fi is available, then uploads to your workspace.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: onContinue) {
                Text("I understand")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
            Link("Privacy policy", destination: URL(string: "https://example.com/privacy")!)
                .font(.footnote)
        }
        .padding(.bottom, 32)
    }
}
```

Each subsequent onboarding view follows similar structure: hero icon, headline, supporting text, primary action button, secondary link or back affordance.

### 7.2 WorkspaceURLStepView

Text field with helper text, validation, "Continue" button (disabled until valid), "Back" toolbar item.

### 7.3 OAuthLoginStepView

Workspace URL display, prominent "Sign in with Databricks" button. Tapping invokes `coordinator.startOAuthSignIn(presenting:)`. While in progress, the button shows a spinner and is disabled. Errors render as a banner above the button.

### 7.4 IdentityConfirmationStepView

"Welcome, [Display Name]" with avatar, workspace name, "Continue" + "Use a different account" buttons.

### 7.5 ProjectPickerStepView

List of projects (loading shimmer initially), search bar, "+ New Project" row at top.

### 7.6 ProjectCreateStepView

Two text fields (name, description), validation feedback inline, "Create" + "Cancel" buttons.

### 7.7 MicrophonePrePromptStepView

Hero icon, "We'll listen only when you press the capture button" explanation, "Continue" button. Cosmetic — actual permission prompt fires on first capture.

---

## 8. View Models — Pattern and Lifecycle

### 8.1 The Standard View Model

```swift
@Observable
@MainActor
final class SomeViewModel {
    // Inputs (constructor-injected protocols, never concrete types in tests)
    private let service: SomeServicing

    // Output state (Observable; SwiftUI re-renders on change)
    private(set) var rows: [Row] = []
    private(set) var loadingState: LoadingState = .loading
    private(set) var error: String?

    // Lifecycle
    private var observationTask: Task<Void, Never>?

    init(service: SomeServicing) {
        self.service = service
    }

    /// Called from view's .task modifier — scoped to view lifetime.
    func task() async {
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.service.events {
                self.handle(event)
            }
        }
        await loadInitial()
    }

    deinit { observationTask?.cancel() }
}
```

### 8.2 Wiring in the View

```swift
struct SomeView: View {
    @State private var viewModel: SomeViewModel

    init(service: SomeServicing) {
        _viewModel = State(wrappedValue: SomeViewModel(service: service))
    }

    var body: some View {
        Content(viewModel: viewModel)
            .task { await viewModel.task() }
    }
}
```

The `.task` modifier ties the subscription's lifetime to the view's on-screen presence. When the view disappears, the task is cancelled and the observation stops. No manual unsubscribe needed.

### 8.3 Shared View Models (rarely)

For cross-view state (e.g., a workspace switcher invoked from multiple places), the view model lives in `AppCoordinator` or as a singleton. Most view models are per-view and short-lived.

---

## 9. Visual Language

### 9.1 Colors

System-defined where possible:

- **Tint:** A custom accent color (electric blue, recognizable as "the Lakeloom color"). Defined in the asset catalog with light/dark variants.
- **Backgrounds:** `.systemBackground`, `.secondarySystemBackground`, `.tertiarySystemBackground`. Never custom backgrounds.
- **Text:** `.primary`, `.secondary`, `.tertiary`. Never custom text colors except for status indicators.
- **Status indicators:**
  - Synced / success: `.systemGreen`
  - Uploading / in-progress: `.systemBlue` (matching tint feel)
  - Waiting / pending: `.systemOrange`
  - Failed / error: `.systemRed`

### 9.2 Typography

System-defined Dynamic Type styles throughout. No custom fonts in v1.

| Use | Style |
|---|---|
| Screen title | `.largeTitle.bold()` or `.title.bold()` |
| Section header | `.headline` |
| Body | `.body` |
| Secondary text | `.subheadline` `.foregroundStyle(.secondary)` |
| Caption | `.caption` |
| Live transcript | `.title2` (large for readability while held away from face) |
| Capture button glyph | SF Symbol at 44pt |
| Timer in capture overlay | `.system(size: 48, weight: .semibold, design: .monospaced)` |

### 9.3 Spacing

A spacing scale: 4, 8, 12, 16, 24, 32, 48. Used consistently. Defined as constants:

```swift
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}
```

### 9.4 Components

A small library of reusable components in `App/Views/Components/`:

- `Chip` — pill with icon + text + tap handler
- `BadgeLabel` — pill with status color + text (used for upload/ingest state)
- `EmptyStateView` — illustration + headline + supporting text + CTA
- `ErrorBanner` — inline banner with icon + message + retry button
- `LoadingShimmer` — placeholder row variants
- `SectionHeaderView` — uppercase section header with optional accessory
- `DestructiveButton` — red, with extra confirmation hooks
- `LinkRow` — settings-style row with chevron

These exist as `View` types with init parameters, not modifiers.

---

## 10. Accessibility

### 10.1 VoiceOver

Every interactive element has:
- A clear `accessibilityLabel` (what it is)
- A `accessibilityHint` when behavior isn't obvious
- Appropriate `accessibilityTraits` (`.button`, `.startsMediaSession` on capture, etc.)
- Custom rotor for sessions list (jump by date section)

### 10.2 Dynamic Type

All text uses Dynamic Type styles. Layouts must reflow at AX5 (largest accessibility size) without truncation:

- Capture button label below the circle wraps if needed
- Sessions list rows use `Layout` containers that stack vertically at extreme sizes
- Tab bar labels truncate gracefully (system-handled)

### 10.3 Reduced Motion

`@Environment(\.accessibilityReduceMotion)` consulted before any non-essential animation:

- Capture button pulse: replaced with simple opacity change
- Live audio level bars: simplified to a single non-animating indicator
- Screen transitions: cross-dissolve instead of slide

### 10.4 Color and Contrast

All status colors meet WCAG AA contrast against their backgrounds. Status conveyed via icon + color, never color alone (e.g., red ⚠️ icon in addition to red color).

### 10.5 Haptics

Used sparingly:
- Capture press-down: medium impact
- Capture release: light impact
- Successful action (project created, etc.): success notification feedback
- Error: error notification feedback

Honored via `UIDevice.current.userInterfaceIdiom` and respect for system "Reduce Motion" (which reduces haptics too — handled automatically).

---

## 11. Testing UI

### 11.1 SwiftUI Snapshot Tests

For every screen and every state (loading / empty / content / error), a snapshot test renders at multiple Dynamic Type sizes and color schemes. Reference images stored in version control. Helpful for catching regressions during onboarding tuning especially.

### 11.2 ViewInspector for Logic

Where view logic is non-trivial (chips disable during capture, list filters compose correctly), `ViewInspector` allows assertions about view structure and state without running the app.

### 11.3 ViewModel Unit Tests

Each view-model has unit tests: scripted service streams produce expected published-state transitions. Standard pattern; covered in respective service module test sections.

### 11.4 UI Tests (XCUITest)

Smoke tests only in v1:
- Onboarding happy path: launch → consent → workspace → OAuth (mocked) → project create → capture
- Capture happy path: tap capture, hold for 5s, release, verify session appears in list
- Sign out flow

Heavy UI test coverage waits for v1.x; the high iteration cost of XCUITests doesn't pay off until UX has stabilized.

---

## 12. Performance Considerations

### 12.1 List Rendering

Sessions list could grow long (hundreds of sessions). Use `LazyVStack` inside `ScrollView` for sections, and `List` where built-in cell recycling matters. Avoid loading full transcript text in row models — only load on detail view open.

### 12.2 Live Transcript Updates

The live transcript can update many times per second as partials arrive. We throttle to 10 updates per second using a debounced binding to avoid excessive view updates during fast speech.

### 12.3 Image Assets

App icon and SF Symbols. No bitmap assets in v1 beyond the app icon and one or two onboarding hero illustrations.

### 12.4 Launch Time

The splash → ready transition target is <1 second on a recent iPhone. Achieved by:

- Eager AppCoordinator bootstrap on `App.task` (already designed)
- No synchronous Core Data work on main thread
- Core Data store load is async via `loadPersistentStores`
- AuthService Keychain reads are sub-millisecond

---

## 13. Out of Scope for v1

- **iPad-optimized layouts.** The app runs on iPad (it's a universal binary by default) but uses iPhone-style single-column layout. iPad multi-column comes in v1.x.
- **Mac Catalyst.** Not in v1.
- **Widgets.** No home-screen widget for "tap to capture" or "uploads pending".
- **App Clip.** No demo App Clip.
- **In-app onboarding tours / coachmarks.** No "tap here!" overlays. Onboarding is enough.
- **Custom themes.** System light/dark only.
- **Localization.** English (`en-US`) only in v1.
- **Audio playback.** Sessions list shows status; doesn't let you play back the recording.
- **Sharing / export.** No "share this transcript" or "export to file" affordances. Users go to Databricks for the data.

---

## 14. Open Items

| # | Item | Resolution Path |
|---|---|---|
| 1 | Should the Home tab show an upload progress banner when an upload is mid-flight in the background? | UX call. Default v1: no banner, just badge on Sessions tab. |
| 2 | Should the recent-sessions strip on Home be limited (3 rows) or scroll horizontally? | v1: 3 rows, "View all" link to Sessions tab. |
| 3 | Confirmation dialog vs sheet for destructive actions (sign out, reset, archive) | v1: confirmation dialog (lighter, system-styled). |
| 4 | Sessions list grouping — relative ("Today") vs absolute ("May 2") | v1: relative for last 7 days, absolute thereafter. |
| 5 | Live transcript display style — bubble, paragraph, or terminal-style | v1: paragraph (most readable for long-form). |
| 6 | Whether to show audio level visualization during capture | v1: yes, simplified to ~10 bars. Rationale: feedback that the mic is working. |
| 7 | Whether to add a "What's New" sheet on first launch after update | v1: no. Add in v1.x once we have meaningful changes between versions. |
| 8 | App icon design | Out of scope for this doc. Owned by design. |
| 9 | Dark mode design tokens — same accent color or shifted? | v1: same hex with system contrast adjustments. Shift if accessibility audit fails. |
| 10 | Tablet keyboard-shortcut bar entries (e.g., Cmd-N for new project) | v1: not implemented. Forward-compatible. |

---

## 15. File Layout (proposed)

```
App/Views/
├── RootView.swift                          // Module 05 owns; lives here for proximity
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
├── Home/
│   ├── HomeContainerView.swift
│   ├── HomeTabRoot.swift
│   ├── HomeView.swift
│   ├── HomeViewModel.swift
│   ├── CaptureButton.swift
│   ├── ActiveContextChips.swift
│   ├── ActiveCaptureCoverView.swift
│   ├── LiveTranscriptOverlay.swift
│   ├── AudioLevelMeterView.swift
│   └── RecentSessionsStrip.swift
├── Sessions/
│   ├── SessionsTabRoot.swift
│   ├── SessionsListView.swift
│   ├── SessionsListViewModel.swift
│   ├── SessionListSection.swift
│   ├── SessionListRowView.swift
│   ├── SessionFilterBar.swift
│   ├── SessionDetailView.swift
│   ├── SessionDetailViewModel.swift
│   ├── UploadDiagnosticsView.swift
│   ├── ProjectPickerSheet.swift
│   └── WorkspaceSwitcherSheet.swift
├── Settings/
│   ├── SettingsTabRoot.swift
│   ├── SettingsListView.swift
│   ├── AccountDetailView.swift
│   ├── WorkspaceDetailView.swift
│   ├── WorkspacesListView.swift
│   ├── ProjectsManagementView.swift
│   ├── ProjectDetailView.swift
│   ├── DefaultPickerView.swift
│   ├── StorageManagementView.swift
│   ├── PrivacyView.swift
│   ├── DiagnosticsView.swift
│   └── AboutView.swift
├── Components/
│   ├── Chip.swift
│   ├── BadgeLabel.swift
│   ├── EmptyStateView.swift
│   ├── ErrorBanner.swift
│   ├── LoadingShimmer.swift
│   ├── SectionHeaderView.swift
│   ├── DestructiveButton.swift
│   └── LinkRow.swift
├── Style/
│   ├── Spacing.swift
│   ├── Tokens.swift
│   ├── ButtonStyles.swift
│   └── ViewModifiers.swift
└── Accessibility/
    ├── HapticFeedback.swift
    └── ReducedMotion.swift
```

Tests mirror this layout under `AppTests/Views/`.
