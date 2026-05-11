# Module 01 — AuthService

**Product:** Lakeloom
**Status:** Design — pre-implementation
**Last updated:** 2026-05-02
**Depends on:** None (foundation module)
**Depended on by:** IngestService, StorageService, AppCoordinator, all Databricks API callers

---

## 1. Purpose

AuthService is the single source of truth for Databricks workspace authentication in the iOS app. It owns:

- The OAuth 2.0 U2M (User-to-Machine) login flow with PKCE
- Token storage and lifecycle (access tokens, refresh tokens) in Keychain
- Per-workspace credential management (multi-workspace support)
- Silent token refresh on 401 responses
- The user identity (SCIM `Me` lookup post-login)
- Sign-in / sign-out / switch-workspace operations

All other modules that talk to Databricks call `AuthService.currentToken()` before each request. They never see PKCE, never see refresh tokens, never touch Keychain directly.

---

## 2. Design Principles

1. **Single auth flow.** OAuth U2M is the only mechanism. No PAT pasting, no service principals, no API key fields anywhere in the app.
2. **The active workspace is global state.** Exactly one workspace is active at a time. Switching is an explicit user action that propagates to all dependent services.
3. **Tokens are an implementation detail.** Callers ask for "a valid token for the active workspace" — they don't manage refresh, expiry, or storage.
4. **Refresh is silent and centralized.** A single mutex serializes refresh attempts so concurrent 401s don't trigger N parallel refreshes.
5. **Keychain, not UserDefaults.** Tokens never touch UserDefaults or files. Only Keychain, with the strictest reasonable accessibility.
6. **Identity is cached but verifiable.** The SCIM `Me` response is cached per-workspace; a manual "refresh identity" path exists but isn't needed for normal use.
7. **Failures are typed.** Auth errors propagate as a small enum that callers can pattern-match on, not as opaque `Error`.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol AuthServicing: Sendable {
    /// All workspaces the user has signed into. Empty if never signed in.
    var workspaces: [WorkspaceCredential] { get async }

    /// The currently active workspace, if any. Nil before first login.
    var activeWorkspace: WorkspaceCredential? { get async }

    /// Stream of identity-relevant changes (sign-in, sign-out, workspace switch).
    /// Consumers (e.g. AppCoordinator) subscribe to react to changes.
    var events: AsyncStream<AuthEvent> { get }

    /// Returns a valid bearer token for the active workspace.
    /// Refreshes silently if expired. Throws if no active workspace or refresh fails.
    func currentToken() async throws -> AccessToken

    /// Initiates the OAuth login flow for a new workspace.
    /// Presents ASWebAuthenticationSession via the provided presentation context.
    /// On success, the new workspace is added to the workspaces list and made active.
    @MainActor
    func signIn(workspaceURL: URL, presenting: ASWebAuthenticationPresentationContextProviding) async throws -> WorkspaceCredential

    /// Switches the active workspace. The target must already be in the workspaces list.
    func switchWorkspace(to workspaceID: String) async throws

    /// Signs out of a specific workspace. Removes its credential and tokens.
    /// If it was the active workspace, the next available workspace becomes active (or nil).
    func signOut(workspaceID: String) async throws

    /// Signs out of all workspaces. Clears all stored credentials.
    func signOutAll() async throws

    /// Forces a refresh of cached identity from SCIM /Me for the active workspace.
    func refreshIdentity() async throws -> UserIdentity
}
```

### 3.2 Value Types

```swift
struct WorkspaceCredential: Sendable, Identifiable, Equatable {
    let id: String                 // workspace_id from Databricks
    let workspaceURL: URL          // canonical https://<host> (no trailing slash)
    let workspaceName: String      // SCIM-derived display name; falls back to host
    let cloud: Cloud               // .aws | .azure | .gcp
    let region: String?            // best-effort, e.g. "us-west-2"
    let user: UserIdentity         // cached SCIM /Me response
    let isDefault: Bool            // user-marked default for next session
    let signedInAt: Date
    let identityRefreshedAt: Date
    // Tokens are NOT here. They live in Keychain keyed by workspaceID.
}

struct UserIdentity: Sendable, Equatable {
    let userID: String             // SCIM "id"
    let userName: String           // SCIM "userName" (typically email)
    let displayName: String        // SCIM "displayName"
    let email: String?             // first SCIM email entry, if present
    let active: Bool
}

struct AccessToken: Sendable {
    let value: String              // bearer token string
    let expiresAt: Date            // absolute expiry, computed from expires_in at issue time
    let workspaceID: String        // which workspace this is for
}

enum Cloud: String, Sendable, Codable {
    case aws, azure, gcp
}

enum AuthEvent: Sendable {
    case signedIn(WorkspaceCredential)
    case signedOut(workspaceID: String)
    case switchedWorkspace(WorkspaceCredential)
    case identityRefreshed(WorkspaceCredential)
}

enum AuthError: Error, Sendable, Equatable {
    case noActiveWorkspace
    case unknownWorkspace(String)
    case userCancelled                    // user dismissed ASWebAuthenticationSession
    case invalidWorkspaceURL(String)
    case oauthFailed(reason: String)      // server-returned error
    case refreshFailed(reason: String)    // refresh token rejected → re-login required
    case identityFetchFailed(reason: String)
    case keychainFailed(OSStatus)
    case networkUnavailable
    case unexpectedResponse(reason: String)
}
```

---

## 4. Internal Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                         AuthService                          │
│  (actor; serializes all operations on workspaces & tokens)   │
└──────────────────────────────────────────────────────────────┘
            │                │                │
            ▼                ▼                ▼
   ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐
   │  OAuthClient   │ │ KeychainStore│ │ DatabricksClient │
   │  (PKCE, ASWAS, │ │  (tokens +   │ │  (SCIM /Me only  │
   │   token I/O)   │ │   metadata)  │ │   in this module)│
   └────────────────┘ └──────────────┘ └──────────────────┘
```

### 4.1 Concurrency Model

- `AuthService` is implemented as a Swift `actor`. All mutable state — the workspaces array, the active workspace ID, the in-flight refresh task — is actor-isolated.
- The login flow requires `@MainActor` for `ASWebAuthenticationSession`, so `signIn(...)` is annotated `@MainActor`. Internally it calls back into the actor to persist the result.
- `currentToken()` uses an in-flight refresh task pattern: if a refresh is already running, concurrent callers `await` its result rather than starting a duplicate.
- The `events` stream has a single internal continuation; the actor publishes events under isolation.

### 4.2 Components

#### OAuthClient
Stateless helper. Owns:
- PKCE code verifier + challenge generation (`CryptoKit.SHA256` over a 32-byte random verifier; base64url-encoded)
- Authorization URL construction
- `ASWebAuthenticationSession` invocation
- Authorization code → token exchange (`POST /oidc/v1/token`)
- Refresh token → token exchange (`POST /oidc/v1/token` with `grant_type=refresh_token`)

Returns raw `OAuthTokenResponse` value types; doesn't touch Keychain or workspaces array.

#### KeychainStore
Wraps the Security framework. Stores per-workspace credential blobs and tokens.

Keys:
- `auth.workspace.<workspaceID>.credential` — encoded `WorkspaceCredential` (no token)
- `auth.workspace.<workspaceID>.access_token` — `{value, expires_at}` JSON
- `auth.workspace.<workspaceID>.refresh_token` — refresh token string
- `auth.workspaces.index` — array of workspace IDs (ordering for UI)
- `auth.active_workspace_id` — currently selected workspace ID

All entries use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. No iCloud sync (`kSecAttrSynchronizable = false`).

#### DatabricksClient (scope-limited within AuthService)
Calls `GET /api/2.0/preview/scim/v2/Me` with a bearer token. Returns `UserIdentity`. Does not retry on 401 — that's `AuthService`'s job. Lives in this module because it's the only network call AuthService needs to make beyond OAuth itself.

---

## 5. OAuth U2M Flow — Step by Step

### 5.1 Configuration Constants

```swift
enum OAuthConfig {
    /// Published Databricks OAuth U2M client_id. Registered with
    /// `http://localhost` redirects only — see §11 for why this drives
    /// an in-app loopback HTTP listener instead of a custom URL scheme.
    /// Not a secret (PKCE replaces client_secret).
    static let clientID = "databricks-cli"

    /// Scopes requested on every login. v1 uses `all-apis offline_access`.
    /// `offline_access` is required to receive a refresh token.
    static let scopes = ["all-apis", "offline_access"]
}
```

The redirect URI is **not** a static constant. The `LiveOAuthClient`
stands up an in-app HTTP listener on `127.0.0.1:<ephemeral-port>` for
each sign-in attempt and composes
`http://localhost:<port>/callback` on the fly. See §5.4 and §11.

### 5.2 Step 1 — Workspace URL Validation

User enters something like `acme-prod.cloud.databricks.com` or `https://acme-prod.cloud.databricks.com/`. The service:

1. Strips whitespace, lowercases, prepends `https://` if missing
2. Validates it parses to a URL with a host
3. Strips any path / query / fragment — only `https://<host>` is retained
4. Probes `GET https://<host>/oidc/.well-known/oauth-authorization-server` to discover endpoints. This both validates the URL is a real Databricks workspace and gives us the auth + token endpoints without hardcoding paths.

Discovery response is cached in memory for the duration of the login flow; not persisted (Databricks could change endpoint paths, and a fresh discovery on next sign-in is cheap).

### 5.3 Step 2 — PKCE Material

```swift
func generatePKCE() -> (verifier: String, challenge: String) {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let verifier = Data(bytes).base64URLEncodedString()      // ~43 chars
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
        .base64URLEncodedString()
    return (verifier, challenge)
}
```

### 5.4 Step 3 — Stand up loopback listener and build authorize URL

Before composing the authorize URL, `LiveOAuthClient` creates a
`LoopbackCallbackListener` (a small `NWListener`-backed HTTP server
bound to `127.0.0.1` on an OS-chosen ephemeral port) and asks it to
start. The bound port is then baked into the redirect URI.

```
{authorization_endpoint}?
  client_id=databricks-cli
  &response_type=code
  &redirect_uri=http://localhost:{port}/callback
  &scope=all-apis+offline_access
  &code_challenge={challenge}
  &code_challenge_method=S256
  &state={random-32-byte-base64url}
```

State is verified on callback to defend against CSRF.

Why loopback and not a custom URL scheme: the `databricks-cli` U2M
client registered by Databricks accepts redirects to `http://localhost`
only. iOS does not let `ASWebAuthenticationSession` capture an
`http://` callback via `callbackURLScheme:` (that API is custom-scheme
only), so the app captures the redirect itself by running an HTTP
listener inside the process.

### 5.5 Step 4 — Present ASWebAuthenticationSession (browser only)

`ASWebAuthenticationSession` is reduced to a browser presenter; the
authorization code is captured by `LoopbackCallbackListener.captureCallback()`,
not by ASWAS's completion handler.

```swift
@MainActor
func presentBrowserAndCaptureViaLoopback(
    authorizationURL: URL,
    listener: LoopbackCallbackListener,
    presenting: ASWebAuthenticationPresentationContextProviding
) async throws -> URL {
    let captureTask: Task<URL, any Error> = Task {
        try await listener.captureCallback()
    }
    let session = ASWebAuthenticationSession(
        url: authorizationURL,
        callbackURLScheme: nil
    ) { _, error in
        // Fires on user dismiss (canceledLogin) or our own session.cancel()
        // after capture; cancel the listener task so the caller surfaces
        // userCancelled, or no-ops if capture already won.
        if error != nil { captureTask.cancel() }
    }
    session.presentationContextProvider = presenting
    session.prefersEphemeralWebBrowserSession = false  // share cookies for SSO/passkey
    guard session.start() else {
        captureTask.cancel()
        throw OAuthError.authorizationFailed(reason: "ASWAS failed to start")
    }
    return try await withTaskCancellationHandler {
        do {
            let url = try await captureTask.value
            session.cancel()  // dismiss the browser sheet
            return url
        } catch is CancellationError {
            session.cancel()
            throw OAuthError.userCancelled
        }
    } onCancel: {
        captureTask.cancel()
    }
}
```

`prefersEphemeralWebBrowserSession = false` is a deliberate choice.
Setting it to true would force users to re-enter SSO credentials every
time. The shared cookie jar makes passkey/biometric Databricks logins
feel native.

### 5.6 Step 5 — Validate Callback and Exchange Code

The captured URL is `http://localhost/{path}?code=...&state=...` (the
listener reconstructs an absolute URL so `URLComponents` can parse the
query items uniformly). Verify:

- `state` matches the value sent
- `code` is present
- No `error` query param (if present, surface as `AuthError.oauthFailed(reason:)`)

Then POST to the token endpoint, echoing the **same** redirect URI
that was sent on `/authorize` (the OAuth spec requires it):

```
POST {token_endpoint}
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code={code}
&redirect_uri=http://localhost:{port}/callback
&client_id=databricks-cli
&code_verifier={verifier}
```

Response (the format Databricks returns):
```json
{
  "access_token": "...",
  "refresh_token": "...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "all-apis offline_access"
}
```

`expiresAt = Date().addingTimeInterval(expires_in - 60)` — the 60-second skew margin is intentional. We refresh slightly early so a request mid-refresh never sees a server-side expiry.

### 5.7 Step 6 — Identity Lookup

With the new access token, GET `/api/2.0/preview/scim/v2/Me`:

```json
{
  "id": "1234567890123456",
  "userName": "jhammond@acme.com",
  "displayName": "Jeff Hammond",
  "active": true,
  "emails": [{"value": "jhammond@acme.com", "primary": true}]
}
```

Map to `UserIdentity`. The workspace's own ID comes from a separate call:

```
GET /api/2.0/workspace-conf?keys=workspace_id
```

…or, more reliably, from the SCIM response's `meta.location` URL parsing. In practice, parsing the workspace host out of `workspaceURL` is sufficient and stable; we'll use SCIM only for user identity and derive workspace_id from a Databricks-provided field at first opportunity.

> **Open item:** confirm the canonical way to obtain `workspace_id` for the OAuth-authenticated workspace. Candidates: SCIM `meta.location`, `/api/2.0/workspace-conf`, or `/api/2.0/preview/accounts/me`. Pick one and document. Until resolved, the app uses the workspace host as a stable identifier and treats `workspace_id` as the host string.

### 5.8 Step 7 — Persist and Activate

Inside the actor:

1. Build `WorkspaceCredential` with all collected info
2. Save credential blob to Keychain
3. Save access + refresh tokens to Keychain (separately keyed)
4. Update workspaces index in Keychain
5. Set as active workspace
6. Emit `.signedIn(credential)` event
7. Return the credential to the UI caller

---

## 6. Token Refresh Flow

### 6.1 The `currentToken()` Method

```swift
func currentToken() async throws -> AccessToken {
    guard let workspaceID = activeWorkspaceID else {
        throw AuthError.noActiveWorkspace
    }

    // If a refresh is already in flight, await it.
    if let inflight = refreshTasks[workspaceID] {
        return try await inflight.value
    }

    // Read current token from Keychain.
    let stored = try keychain.loadAccessToken(workspaceID: workspaceID)

    // Valid and not near expiry? Return it.
    if stored.expiresAt > Date().addingTimeInterval(30) {
        return stored
    }

    // Otherwise refresh under a single in-flight task.
    let task = Task<AccessToken, Error> { [weak self] in
        guard let self else { throw AuthError.noActiveWorkspace }
        return try await self.performRefresh(workspaceID: workspaceID)
    }
    refreshTasks[workspaceID] = task
    defer { refreshTasks[workspaceID] = nil }
    return try await task.value
}
```

The `refreshTasks: [String: Task<AccessToken, Error>]` dictionary is the deduplication mechanism. It's actor-isolated, so reads/writes are serialized.

### 6.2 The `performRefresh(...)` Method

```swift
private func performRefresh(workspaceID: String) async throws -> AccessToken {
    let refreshToken = try keychain.loadRefreshToken(workspaceID: workspaceID)
    let credential = try keychain.loadCredential(workspaceID: workspaceID)
    let tokenEndpoint = try await oauth.discoverTokenEndpoint(workspaceURL: credential.workspaceURL)

    do {
        let response = try await oauth.refreshTokens(
            tokenEndpoint: tokenEndpoint,
            clientID: OAuthConfig.clientID,
            refreshToken: refreshToken
        )
        let newAccess = AccessToken(
            value: response.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn - 60)),
            workspaceID: workspaceID
        )
        try keychain.saveAccessToken(newAccess, workspaceID: workspaceID)
        // Databricks rotates refresh tokens — save the new one if returned.
        if let newRefresh = response.refreshToken {
            try keychain.saveRefreshToken(newRefresh, workspaceID: workspaceID)
        }
        return newAccess
    } catch let error as OAuthError where error.isInvalidGrant {
        // Refresh token expired or revoked. User must re-login.
        try keychain.deleteTokens(workspaceID: workspaceID)
        // Keep the credential record so the UI can show "Re-login required" without losing the workspace.
        throw AuthError.refreshFailed(reason: "refresh_token expired; re-login required")
    } catch {
        throw AuthError.refreshFailed(reason: error.localizedDescription)
    }
}
```

### 6.3 Caller Pattern for 401 Handling

Other modules (IngestService, StorageService) call `currentToken()` once before each request. If they get a 401 anyway (clock skew, server-side token revocation), they call `currentToken(forceRefresh: true)` and retry once. We add a force-refresh variant:

```swift
func currentToken(forceRefresh: Bool = false) async throws -> AccessToken
```

Internally, `forceRefresh = true` skips the expiry check and goes straight to the refresh path. Still deduplicates against any in-flight refresh.

---

## 7. Multi-Workspace State Management

### 7.1 Switching

```swift
func switchWorkspace(to workspaceID: String) async throws {
    guard workspaces.contains(where: { $0.id == workspaceID }) else {
        throw AuthError.unknownWorkspace(workspaceID)
    }
    activeWorkspaceID = workspaceID
    try keychain.saveActiveWorkspaceID(workspaceID)
    let credential = workspaces.first { $0.id == workspaceID }!
    eventContinuation.yield(.switchedWorkspace(credential))
}
```

A switch does not invalidate any in-flight requests — the old workspace's token is still valid for any in-flight call that captured it. New calls to `currentToken()` get the new workspace's token. Callers that pin to a specific workspace (e.g., a session in progress) should capture the workspace ID at session start and pass it explicitly to `currentToken(workspaceID:)` if they care; for v1, sessions block workspace switching while active (enforced at the AppCoordinator layer).

### 7.2 Sign-Out

```swift
func signOut(workspaceID: String) async throws {
    try keychain.deleteCredential(workspaceID: workspaceID)
    try keychain.deleteTokens(workspaceID: workspaceID)
    workspaces.removeAll { $0.id == workspaceID }

    if activeWorkspaceID == workspaceID {
        activeWorkspaceID = workspaces.first?.id
        if let newActive = activeWorkspaceID {
            try keychain.saveActiveWorkspaceID(newActive)
        } else {
            try keychain.clearActiveWorkspaceID()
        }
    }
    eventContinuation.yield(.signedOut(workspaceID: workspaceID))
}
```

Sign-out also attempts a best-effort revocation by POSTing to the token revocation endpoint if available, but does not block on it — the local credential is gone regardless.

### 7.3 Sign-Out All

Iterates all workspaces, calls `signOut(workspaceID:)` for each. Final state: no workspaces, no active workspace, all Keychain entries cleared.

---

## 8. Keychain Layout

All entries use:
- `kSecClass` = `kSecClassGenericPassword`
- `kSecAttrService` = `"com.<your-org>.lakeloom.auth"`
- `kSecAttrAccount` = key (see below)
- `kSecAttrAccessible` = `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- `kSecAttrSynchronizable` = `false`

### 8.1 Keys

| Account key | Value |
|---|---|
| `workspace.<workspaceID>.credential` | JSON-encoded `WorkspaceCredentialDTO` |
| `workspace.<workspaceID>.access_token` | JSON `{ "value": "...", "expires_at": "..." }` |
| `workspace.<workspaceID>.refresh_token` | Refresh token string (raw) |
| `workspaces.index` | JSON array of workspace IDs (ordered) |
| `active_workspace_id` | Workspace ID string (or absent) |

### 8.2 DTO Distinction

We deliberately separate the public `WorkspaceCredential` value type from the storage DTO:

```swift
private struct WorkspaceCredentialDTO: Codable {
    let id: String
    let workspaceURL: URL
    let workspaceName: String
    let cloud: Cloud
    let region: String?
    let user: UserIdentityDTO
    let isDefault: Bool
    let signedInAt: Date
    let identityRefreshedAt: Date
    let schemaVersion: Int
    // No tokens here.
}
```

`schemaVersion` lets us migrate the DTO format without invalidating existing logins. On read, if the schema version is older, we migrate in place and rewrite. If newer than the app supports, we treat the credential as corrupt and require re-login.

---

## 9. Error Model

All errors AuthService throws conform to `AuthError`. Internal helpers may throw `OAuthError`, `KeychainError`, or `URLError`, but the public surface translates them:

| Internal | Public |
|---|---|
| `OAuthError.invalidGrant` (refresh) | `.refreshFailed(reason:)` |
| `OAuthError.serverError(status:)` | `.oauthFailed(reason:)` |
| `URLError.notConnectedToInternet` | `.networkUnavailable` |
| `KeychainError.osStatus(s)` | `.keychainFailed(s)` |
| `ASWebAuthenticationSessionError.canceledLogin` | `.userCancelled` |

Pattern-match by callers:

```swift
do {
    let token = try await auth.currentToken()
    // ...
} catch AuthError.refreshFailed {
    // Show "Sign in again" UI for the active workspace
} catch AuthError.networkUnavailable {
    // Queue for later, show offline indicator
} catch AuthError.noActiveWorkspace {
    // Route to onboarding
} catch {
    // Unexpected — log + generic error UI
}
```

---

## 10. Threading and Reentrancy

- Public methods are `async` and run on the actor's executor
- `signIn(...)` is `@MainActor` because of `ASWebAuthenticationSession`; it hops to the actor for persistence
- Keychain calls are synchronous and happen on the actor executor — they're fast (microseconds) so this is fine
- The SCIM `Me` HTTP call uses `URLSession.shared.data(for:)` and runs concurrently with the actor; the actor only re-enters to persist the response
- The `events: AsyncStream<AuthEvent>` continuation is owned by the actor; events are yielded under isolation, ensuring strict ordering (sign-in always precedes any subsequent event for that workspace)

### 10.1 Reentrancy concern: concurrent `signIn` calls

If the UI somehow triggers two simultaneous `signIn(workspaceURL:)` calls for the same workspace (double-tap, view revival), the actor serializes them but both will complete the OAuth flow — bad. Mitigation: the actor maintains an in-flight set keyed by workspace URL; the second call waits for the first and returns its result.

---

## 11. Loopback Redirect URI Strategy

### 11.1 Why loopback (and not a custom URL scheme)

Databricks' published U2M client (`databricks-cli`) is registered with
`http://localhost` redirects only. Custom URL schemes
(`lakeloom://oauth/callback`) are not accepted at the OAuth layer.
That removes `CFBundleURLTypes` registration and `Info.plist`-based
URL handling from this module entirely.

### 11.2 In-app loopback HTTP listener

`LoopbackCallbackListener` (in `iOS/App/Auth/OAuth/LoopbackCallbackListener.swift`)
is an actor wrapping `Network.NWListener`:

- Binds to `127.0.0.1` (`requiredInterfaceType = .loopback`) on an OS-chosen
  ephemeral port (`NWEndpoint.Port.any`). The bound port is only known
  after the listener reaches `.ready`.
- Returns `UInt16` so the OAuth client can compose
  `http://localhost:<port>/callback`.
- Accepts a single GET on `/callback`, parses the path+query, and
  responds with a small "you may close this tab" HTML page before the
  in-app code programmatically dismisses ASWAS.
- One listener per sign-in attempt; `stop()` is idempotent and is
  invoked in both success and failure paths.
- Uses `withTaskCancellationHandler` so a parent-task cancellation
  (e.g. user navigates away from the SignIn screen) propagates
  cleanly: the listener's pending continuation is resumed with
  `CancellationError` and `LiveOAuthClient` translates that to
  `OAuthError.userCancelled`.

### 11.3 Privacy Manifest

The OAuth flow requires the Speech framework only indirectly (no
Speech APIs are called by AuthService), but the privacy manifest
(`PrivacyInfo.xcprivacy`) must declare:

- `NSPrivacyAccessedAPICategoryUserDefaults` if any settings end up there
  (we avoid this; AuthService uses only Keychain)
- Network calls to Databricks domains — covered by the app's general
  manifest

No new entries strictly required for AuthService.

---

## 12. Test Strategy

### 12.1 Unit Tests

- `OAuthClient`: PKCE generation determinism (with seeded RNG), URL construction edge cases, token response parsing, refresh-token-rotation behavior
- `KeychainStore`: round-trip save/load/delete using a mockable wrapper protocol; OSStatus error mapping
- `AuthService` actor:
  - First-time sign-in happy path (mock OAuthClient + KeychainStore)
  - Sign-in cancellation (`ASWebAuthenticationSessionError.canceledLogin` mapped to `.userCancelled`)
  - `currentToken()` returns cached when valid, refreshes when near expiry
  - Concurrent `currentToken()` calls during refresh dedup to single refresh
  - Refresh on `invalid_grant` triggers `.refreshFailed` and clears tokens but keeps credential
  - Switch workspace updates active and emits event in order
  - Sign-out of active workspace promotes next workspace correctly
  - Keychain corruption (wrong schema version) → treat as re-login required

### 12.2 Integration Tests (manual until we have a sandbox)

- Real OAuth login against a test Databricks workspace
- Refresh token rotation observed across two refreshes
- Force-quit during OAuth flow → next launch is not stuck (no orphan in-flight task)
- Remove app and reinstall → Keychain entries persist (this is iOS behavior; document and decide whether to clear on first launch via a UserDefaults marker)

### 12.3 Test Seams

The actor depends on three protocols:
```swift
protocol OAuthClient: Sendable { /* ... */ }
protocol KeychainStore: Sendable { /* ... */ }
protocol DatabricksIdentityClient: Sendable { /* ... */ }
```

Production implementations: `LiveOAuthClient`, `LiveKeychainStore`, `LiveDatabricksIdentityClient`. Test implementations: `FakeOAuthClient` (scriptable), `InMemoryKeychainStore`, `StubDatabricksIdentityClient`.

---

## 13. Observability

- Structured logs at `info` level for: sign-in start/success/failure, sign-out, workspace switch, refresh attempt/success/failure
- Token values **never logged**, even at debug level — only token IDs (last 4 chars) for correlation
- A `AuthDiagnostics` struct exposes counters (refresh attempts, refresh failures, last refresh timestamp per workspace) that the Settings → Diagnostics screen can show
- Errors that map to `AuthError.refreshFailed` increment a per-workspace counter; if it exceeds 3 in a 24h window, the UI surfaces a "There may be a problem with your sign-in — try signing out and back in" hint

---

## 14. Out of Scope for v1

- **Biometric gate before token use.** Could require Face ID before AuthService hands out a token — adds friction we don't think we need for v1. Revisit if customer security teams require it.
- **Token revocation on sign-out.** Best-effort for v1; not required to succeed.
- **Multi-account per workspace.** v1 assumes one user identity per workspace. If a user wants to switch identities within the same workspace, they sign out and sign in again.
- **Offline grace.** If the refresh token is rejected while the user is offline, we currently surface `.refreshFailed`. A more polished v1.x could distinguish "actually rejected" from "couldn't reach token endpoint" and treat the latter as `.networkUnavailable`.
- **Account-level OAuth.** v1 is workspace-level only. Account-level OAuth (`/oidc/accounts/...`) is not used.

---

## 15. Open Items

| # | Item | Owner | Resolution Path |
|---|---|---|---|
| 1 | Canonical source of `workspace_id` post-OAuth (SCIM `meta.location` vs. workspace-conf endpoint) | TBD | Empirically test against a Databricks workspace; document the chosen approach in this file |
| 2 | Whether to use `prefersEphemeralWebBrowserSession = true` for first sign-in (forces fresh login) | TBD | Default to `false` (shared cookies). Add a per-workspace setting if customer security teams require ephemeral. |
| 3 | Refresh-token rotation behavior (does Databricks always rotate? optionally?) | TBD | Implement rotation-aware (already does); verify in practice and document |
| 4 | Whether the SCIM user identity refresh has a TTL or is on-demand only | TBD | v1 default: refresh at sign-in only. Add 24h background refresh in v1.x. |
| 5 | First-launch Keychain hygiene — clear residual credentials from a prior install? | TBD | Use a UserDefaults sentinel; if absent on launch, treat Keychain as untrusted and clear it. |

---

## 16. File Layout (proposed)

```
App/Auth/
├── AuthService.swift                  // actor, public surface
├── AuthServicing.swift                // protocol + value types + AuthError
├── AuthEvent.swift
├── OAuth/
│   ├── OAuthClient.swift              // protocol
│   ├── LiveOAuthClient.swift
│   ├── LoopbackCallbackListener.swift // NWListener-backed http://localhost capture
│   ├── PKCE.swift
│   ├── OAuthURLBuilder.swift
│   └── OAuthTokenResponse.swift
├── Keychain/
│   ├── KeychainStore.swift            // protocol
│   ├── LiveKeychainStore.swift
│   ├── InMemoryKeychainStore.swift    // test impl
│   └── KeychainError.swift
├── Identity/
│   ├── DatabricksIdentityClient.swift // protocol
│   ├── LiveDatabricksIdentityClient.swift
│   └── SCIMMeResponse.swift
└── Diagnostics/
    └── AuthDiagnostics.swift
```

Tests mirror this layout under `AppTests/Auth/`.
