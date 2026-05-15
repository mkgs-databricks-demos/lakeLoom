# Module 01 — AuthService

**Product:** Lakeloom
**Status:** Implemented (QR-pair flow)
**Last updated:** 2026-05-14
**Depends on:** DeviceKeyStore, M2MTokenClient, RequestSigner, LakeloomAppClient, KeychainStore (all in same module / Pairing subsystem)
**Depended on by:** ProjectService, IngestService, StorageService, AppCoordinator, all callers of the lakeLoom Databricks App

---

## 1. Purpose

AuthService is the single source of truth for Databricks workspace authentication in the iOS app. It owns:

- The **QR-pair sign-in flow** — decoding the QR payload, generating the Secure Enclave device keypair, calling `POST /api/pairing/confirm`, persisting credentials.
- Per-workspace credential management in Keychain (Xcode SPN client_id/secret, session token, App base URL, workspace metadata).
- Multi-workspace support (multiple paired workspaces simultaneously, one active at a time).
- Sign-in / sign-out / switch-workspace operations.

OAuth U2M was the original design but was abandoned on 2026-05-09 after empirical iOS-side failures — see `architecture/hi_genie/qr-pair-auth-model.md` for the full pivot rationale and the wire-format contract (which Genie Code owns server-side).

All other modules that need a bearer token call `AuthService.currentToken()`. They never see Xcode SPN credentials, session tokens, or device-key signing. Those layers live inside `LakeloomAppClient`, which the auth module composes with.

---

## 2. Design Principles

1. **One auth path: QR pairing.** No OAuth U2M, no PAT pasting, no API key fields. The QR delivered by the lakeLoom Databricks App is the only way to onboard a workspace.
2. **The active workspace is global state.** Exactly one workspace is active at a time; multi-workspace switch is an explicit user action.
3. **Tokens and signing are implementation details.** Callers ask `currentToken()` for "a valid bearer for the active workspace" — they don't manage M2M refresh, signing, or storage.
4. **Two-layer auth on every iOS → App call** (per `qr-pair-auth-model.md`):
   - Layer 0: Bearer M2M token minted from the Xcode SPN against the workspace's `/oidc/v1/token`. Validated by Databricks Apps' platform sidecar.
   - Layer 1: `X-Lakeloom-Session` + `X-Lakeloom-Timestamp` + `X-Lakeloom-Signature` (ECDSA P-256 over `METHOD\nPATH\nUNIX_SECONDS\nBODY_SHA256_HEX`). Validated by the App's `iosAuth` middleware.
5. **Keychain, not UserDefaults.** Xcode SPN secret, session token, and credential blob all live in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
6. **Device key never leaves the Secure Enclave.** Private key generated on first launch; only the public key is sent on `/api/pairing/confirm`.
7. **Failures are typed.** Auth errors propagate as a small enum (`AuthError`) that callers can pattern-match on, not as opaque `Error`.
8. **iOS has exactly one network destination: the Databricks App.** UC Volume binary uploads, ZeroBus events, Lakebase reads/writes, and SCIM lookups all happen server-side on the App.

---

## 3. Public Surface

### 3.1 Protocol

```swift
protocol AuthServicing: Sendable {
    /// All workspaces the user has paired. Empty if never paired.
    var workspaces: [WorkspaceCredential] { get async }

    /// The currently active workspace, if any. Nil before first pairing.
    var activeWorkspace: WorkspaceCredential? { get async }

    /// Stream of identity-relevant changes (sign-in, sign-out, workspace switch).
    var events: AsyncStream<AuthEvent> { get async }

    /// Returns a Layer 0 bearer token (M2M from Xcode SPN) for the
    /// active workspace. Delegates to LakeloomAppClient's cached bearer.
    func currentToken(forceRefresh: Bool) async throws -> AccessToken

    /// Completes a QR-pair sign-in for a new workspace.
    /// Decodes the payload, generates Secure Enclave key, configures
    /// LakeloomAppClient, POSTs /api/pairing/confirm, persists.
    func signInViaPairing(qrText: String, deviceLabel: String) async throws -> WorkspaceCredential

    /// Switches the active workspace. The target must already be in the list.
    func switchWorkspace(to workspaceID: String) async throws

    /// Signs out of a specific workspace. Removes credential + tokens +
    /// drops the LakeloomAppClient config so subsequent requests fail closed.
    func signOut(workspaceID: String) async throws

    /// Signs out of all workspaces.
    func signOutAll() async throws
}
```

OAuth U2M's `signIn(workspaceURL:presenting:)`, `validateWorkspaceURL(_:)`, and `refreshIdentity()` no longer exist — the workspace URL and user identity are both delivered via the QR payload, server-validated before the QR is even rendered.

### 3.2 Value Types

```swift
struct WorkspaceCredential: Sendable, Identifiable, Equatable, Codable {
    let id: String                 // workspace_id (derived from QR's workspace.url.host)
    let workspaceURL: URL          // QR's workspace.url
    let workspaceName: String      // QR's workspace.name
    let cloud: Cloud               // QR's workspace.cloud → enum
    let region: String?            // unused in v1 (reserved)
    let user: UserIdentity         // QR's user fields → SCIM-shaped struct
    let isDefault: Bool            // user-marked default for next session
    let signedInAt: Date
    let identityRefreshedAt: Date
    let appBaseURL: URL            // QR's app.base_url — the Databricks App's HTTPS root
    let authMethod: AuthMethod     // currently always .qrPaired(pairedSessionID:sessionExpiresAt:)
    // Xcode SPN client_id/secret + session token live in Keychain
    // under separate slots, not on this value.
}

enum AuthMethod: Sendable, Equatable, Hashable, Codable {
    case qrPaired(pairedSessionID: String, sessionExpiresAt: Date)
    // Forward-compatible — future auth methods get their own case.
}

struct AccessToken: Sendable {
    let value: String              // M2M bearer (Layer 0); not the session token
    let expiresAt: Date            // informational; LakeloomAppClient holds the real expiry
    let workspaceID: String
}

enum AuthEvent: Sendable, Equatable {
    case signedIn(WorkspaceCredential)
    case signedOut(workspaceID: String)
    case switchedWorkspace(WorkspaceCredential)
    // .identityRefreshed removed — identity comes from the QR; no SCIM refresh path.
}

enum AuthError: Error, Sendable, Equatable {
    case noActiveWorkspace
    case unknownWorkspace(String)
    case userCancelled                       // QR scan dismissed by the user
    case invalidPairingPayload(reason: String) // QR didn't decode or wrong version
    case pairingFailed(reason: String)       // App rejected /api/pairing/confirm
    case refreshFailed(reason: String)       // Layer 0 M2M exchange failed → re-pair
    case deviceKeyFailed(reason: String)     // Secure Enclave issue
    case keychainFailed(OSStatus)
    case networkUnavailable
    case unexpectedResponse(reason: String)
}
```

---

## 4. Internal Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         AuthService (actor)                          │
│       (orchestrator; serializes workspace state + Keychain I/O)      │
└──────────────────────────────────────────────────────────────────────┘
       │            │              │                    │
       ▼            ▼              ▼                    ▼
┌─────────────┐ ┌───────────┐ ┌──────────────┐ ┌──────────────────────┐
│LakeloomApp  │ │DeviceKey  │ │ KeychainStore│ │ PairingPayload       │
│Client (M2M  │ │Store      │ │ (credential, │ │ (decode + version    │
│cache + Layer│ │(Secure    │ │  session_tok,│ │  check)              │
│0/1 headers) │ │Enclave    │ │  xcode_spn)  │ │                      │
│             │ │P-256)     │ │              │ │                      │
└─────────────┘ └───────────┘ └──────────────┘ └──────────────────────┘
```

### 4.1 Concurrency Model

- `AuthService` is implemented as a Swift `actor`. All mutable state — the workspaces array, the active workspace ID, event continuations — is actor-isolated.
- `signInViaPairing(qrText:deviceLabel:)` is NOT `@MainActor` — the QR scanner view captures the device label from `UIDevice.current.name` before calling into the actor, so no main-thread dependency remains.
- M2M token caching + dedup lives inside `LakeloomAppClient` (also an actor). AuthService doesn't manage refresh state directly.
- The `events` stream is multicast — each subscriber gets its own `AsyncStream<AuthEvent>` continuation, all driven from the actor under isolation.

### 4.2 Components

#### LakeloomAppClient (shared across modules)
Lives at `iOS/App/Common/Networking/LakeloomAppClient.swift`. Owns:
- The per-workspace M2M token cache (Layer 0)
- The per-request signature computation (Layer 1) via `RequestSigner`
- URLSession dispatch

AuthService calls `lakeloomApp.configure(workspaceID:config:)` at pairing time and on cold-launch hydrate, then `lakeloomApp.request(...)` for `/api/pairing/confirm`. ProjectAPIClient and future upload clients share the same instance.

#### DeviceKeyStore
Lives at `iOS/App/Auth/Pairing/DeviceKeyStore.swift`. Wraps `SecureEnclave.P256.Signing.PrivateKey`. Generates the keypair on first use; persists the opaque `dataRepresentation` blob to its own Keychain service identifier (separate from the auth Keychain). Returns the DER-encoded public key on demand and signs canonical-form messages.

#### KeychainStore
Wraps the Security framework. Stores per-workspace credential blobs and the QR-delivered secrets.

Keys (see §8.1 for the full table):
- `workspace.<workspaceID>.credential` — encoded `WorkspaceCredentialDTO`
- `workspace.<workspaceID>.session_token` — opaque session token string
- `workspace.<workspaceID>.xcode_spn` — `{ clientID, clientSecret }` JSON
- `workspaces.index` — array of workspace IDs (ordering for UI)
- `active_workspace_id` — currently selected workspace ID

All entries use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. No iCloud sync (`kSecAttrSynchronizable = false`).

#### PairingPayload
Lives at `iOS/App/Auth/Pairing/PairingPayload.swift`. Codable model matching Genie's QR JSON. Static `decode(from qrString:)` handles base64/base64url + version check.

---

## 5. QR-Pair Sign-In Flow

The wire-format contract is owned by Genie Code and documented in
`architecture/hi_genie/qr-pair-auth-model.md`. iOS just consumes
that contract. This section describes how AuthService stitches the
iOS-side pieces together.

### 5.1 Dependencies AuthService Composes

```swift
public actor AuthService: AuthServicing {
    private let lakeloomApp: any LakeloomAppClient   // shared App-API primitive
    private let deviceKeyStore: any DeviceKeyStoring // Secure Enclave P-256 keypair
    private let keychain: KeychainStore              // per-workspace credential blob + slots
    private let logger: AppLogger
    // ...
}
```

Each dep is its own actor / struct and tested independently.
AuthService is the orchestrator; the work happens in the deps.

### 5.2 Step 1 — Decode the QR

`PairingPayload.decode(from: qrText)` accepts the base64-encoded
JSON. Tolerant of both standard base64 (RFC 4648 §4) and base64url
(§5). Rejects on:
- non-base64 input → `AuthError.invalidPairingPayload`
- malformed JSON → `.invalidPairingPayload`
- wire-version mismatch (anything other than `v: 1`) →
  `.invalidPairingPayload` carrying both encountered + supported
  versions, so the UI can say "Update lakeLoom."

### 5.3 Step 2 — Materialize the Device Public Key

`deviceKeyStore.publicKeyDER()` returns the DER-encoded
`SubjectPublicKeyInfo`. The private key never leaves the Secure
Enclave. First call generates the keypair and persists an opaque
blob in Keychain (under `LiveDeviceKeyStore`'s own service
identifier); subsequent calls restore from that blob.

### 5.4 Step 3 — Configure LakeloomAppClient for the New Workspace

Before `/api/pairing/confirm` can be called, the App-API client
needs to know how to mint M2M tokens (workspace URL + Xcode SPN
creds) and how to sign requests (session token from the QR). Done
via `lakeloomApp.configure(workspaceID:config:)` with a
`LakeloomAppClientConfig` built from the QR payload.

### 5.5 Step 4 — POST /api/pairing/confirm

Body:
```json
{
  "device_pubkey": "<base64url DER-encoded P-256 SPKI>",
  "device_label": "Matthew's iPhone"
}
```

`device_label` is `UIDevice.current.name` (truncated by server if
needed). `device_pubkey` is the result of step 2, base64url-encoded.

The request goes through `lakeloomApp.request(...)`, which attaches:
- `Authorization: Bearer <m2m-token>` (Layer 0, minted from the
  freshly-configured Xcode SPN)
- `X-Lakeloom-Session: <session token from QR>`
- `X-Lakeloom-Timestamp`, `X-Lakeloom-Signature` (Layer 1, signed
  via `RequestSigner`)

Response:
```json
{
  "paired_session_id": "<uuid>",
  "paired_at": "<ISO 8601>",
  "expires_at": "<ISO 8601>"
}
```

`paired_session_id` is the App-assigned UUID for this device's
`app.paired_sessions` row. iOS stores it in
`WorkspaceCredential.authMethod` and surfaces it in any future "My
paired devices" UX.

### 5.6 Step 5 — Persist and Activate

Inside the actor:
1. Build `WorkspaceCredential` from the QR's workspace + user + app
   fields, plus the `paired_session_id` and `session_expires_at`
   from the confirm response.
2. Save credential blob to Keychain (DTO schema v2).
3. Save session token to its own Keychain slot.
4. Save Xcode SPN client_id+secret to its own Keychain slot.
5. Update workspaces index in Keychain.
6. Set as active workspace.
7. Emit `.signedIn(credential)` event so AppCoordinator can advance
   the onboarding state machine.
8. Return the credential.

AppCoordinator additionally calls
`AppEndpointResolver.seed(workspaceID:appBaseURL:)` with the QR's
`app.base_url` so subsequent ProjectAPIClient calls route through
the correct App URL without falling back to the placeholder
workspace-URL derivation.


## 6. M2M Token Cache (delegated to LakeloomAppClient)

The QR-pair flow doesn't use refresh tokens — the M2M
`client_credentials` grant doesn't issue them. Each ~1hr access
token is independently re-minted from the Xcode SPN credentials
when the cached value is near expiry. That cache lives **inside
`LakeloomAppClient`**, not in AuthService, because every
ProjectAPIClient / future upload-client request needs the same
bearer and ought to share the cache.

### 6.1 The `currentToken()` Method

```swift
func currentToken(forceRefresh: Bool = false) async throws -> AccessToken {
    guard let workspaceID = activeWorkspaceID else {
        throw AuthError.noActiveWorkspace
    }
    let bearer = try await lakeloomApp.currentBearer(workspaceID: workspaceID)
    return AccessToken(
        value: bearer,
        expiresAt: Date().addingTimeInterval(60), // informational
        workspaceID: workspaceID
    )
}
```

`forceRefresh` is preserved for protocol compatibility but has no
effect — LakeloomAppClient's cache already re-mints on near-expiry
(default 30s skew). Callers who hit a 401 should let the App's
middleware tell them whether the issue is the bearer (Layer 0,
re-pair required) or the session token (Layer 1, expired or
revoked, also re-pair required) via the typed
`LakeloomAppError.unauthorized(kind:detail:)` cases.

### 6.2 Internal cache in LakeloomAppClient

```swift
private struct CachedM2MToken {
    let value: String
    let expiresAt: Date
}
private var m2mCache: [String: CachedM2MToken] = [:]

private func bearer(for workspaceID: String, config: ...) async throws -> String {
    if let cached = m2mCache[workspaceID], !isNearExpiry(cached, now: now) {
        return cached.value
    }
    let response = try await m2mTokenClient.acquireToken(
        workspaceURL: config.workspaceURL,
        clientID: config.xcodeSPN.clientID,
        clientSecret: config.xcodeSPN.clientSecret,
        scopes: ["all-apis"]
    )
    let expiresAt = now.addingTimeInterval(TimeInterval(max(response.expiresIn - 60, 60)))
    m2mCache[workspaceID] = CachedM2MToken(value: response.accessToken, expiresAt: expiresAt)
    return response.accessToken
}
```

Token-exchange failures (invalid_client, etc.) map to
`LakeloomAppError.tokenExchangeFailed(reason:)` which AuthService
translates to `AuthError.refreshFailed` for UI consumption.

### 6.3 Caller Pattern for 401 Handling

The pattern is unchanged from the OAuth-era design: callers
(ProjectAPIClient, future upload clients) call `currentToken()`
once before each request. If they get a 401, the typed error tells
them what to do:
- `LakeloomAppError.unauthorized(.tokenExpired)` or `.tokenNotFound` →
  surface "session expired, re-pair" via AuthCoordinator.
- `.signatureInvalid` → likely clock skew; retry once with corrected
  time, then surface "device clock is off."

Re-pairing is the only recovery for any Layer 0 / Layer 1 failure
— there's no silent refresh path because the QR is the only source
of fresh credentials.

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
| `workspace.<workspaceID>.credential` | JSON-encoded `WorkspaceCredentialDTO` (schema v2 — adds `appBaseURL` + `authMethod`) |
| `workspace.<workspaceID>.access_token` | JSON `{ "value": "...", "expires_at": "..." }` — legacy slot, mostly unused now that M2M cache lives in LakeloomAppClient |
| `workspace.<workspaceID>.session_token` | Opaque per-paired-session token from the QR (raw UTF-8 string) |
| `workspace.<workspaceID>.xcode_spn` | JSON `{ "clientID": "...", "clientSecret": "..." }` — the iOS-facing SPN credentials delivered via QR |
| `workspaces.index` | JSON array of workspace IDs (ordered) |
| `active_workspace_id` | Workspace ID string (or absent) |
| (separate service: `com.databricks.lakeloom.device`) | `device.signing_key` — `SecureEnclave.P256.Signing.PrivateKey.dataRepresentation` blob; private key never leaves the SE, this is just the SE-issued handle |

### 8.2 DTO Distinction

We deliberately separate the public `WorkspaceCredential` value type from the storage DTO:

```swift
private struct WorkspaceCredentialDTO: Codable {
    let id: String
    let workspaceURL: URL
    let workspaceName: String
    let cloud: Cloud
    let region: String?
    let user: UserIdentity
    let isDefault: Bool
    let signedInAt: Date
    let identityRefreshedAt: Date
    let appBaseURL: URL          // NEW in schema v2
    let authMethod: AuthMethod   // NEW in schema v2
    let schemaVersion: Int
    // Session token + Xcode SPN secret live in separate Keychain slots
    // (see §8.1) so they aren't accidentally serialized into UI state
    // or logs alongside the credential metadata.
}
```

`schemaVersion: Int = 2` as of this rewrite. v1 records (OAuth-era) are rejected at load with `KeychainError.unsupportedSchemaVersion`; AuthService.start() catches this and drops the credential with a warning, forcing a re-pair. No production users had v1 records, so no migration path is provided.

---

## 9. Error Model

All errors AuthService throws conform to `AuthError`. Internal helpers may throw `LakeloomAppError`, `KeychainError`, `URLError`, `DeviceKeyStoreError`, or `PairingPayload.DecodingError`, but the public surface translates them:

| Internal | Public |
|---|---|
| `PairingPayload.DecodingError.*` | `.invalidPairingPayload(reason:)` |
| `DeviceKeyStoreError.*` | `.deviceKeyFailed(reason:)` |
| `LakeloomAppError.tokenExchangeFailed(reason:)` | `.refreshFailed(reason:)` |
| `LakeloomAppError.unauthorized(.tokenExpired/.tokenNotFound, ...)` | `.refreshFailed(reason:)` |
| `LakeloomAppError.unauthorized(.signatureInvalid/.timestampSkew, ...)` | `.pairingFailed(reason:)` |
| `LakeloomAppError.httpError(status:, detail:)` | `.pairingFailed(reason:)` (during confirm) |
| `LakeloomAppError.networkUnavailable` | `.networkUnavailable` |
| `URLError.notConnectedToInternet` | `.networkUnavailable` |
| `KeychainError.osStatus(s)` | `.keychainFailed(s)` |

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
- `signInViaPairing(...)` runs entirely on the actor's executor. The QR-scanner view hops to `@MainActor` to read `UIDevice.current.name` before calling in, but the auth service itself isn't main-actor-bound
- Keychain calls are synchronous and happen on the actor executor — they're fast (microseconds) so this is fine
- The SCIM `Me` HTTP call uses `URLSession.shared.data(for:)` and runs concurrently with the actor; the actor only re-enters to persist the response
- The `events: AsyncStream<AuthEvent>` continuation is owned by the actor; events are yielded under isolation, ensuring strict ordering (sign-in always precedes any subsequent event for that workspace)

### 10.1 Reentrancy concern: concurrent `signInViaPairing` calls

If the UI somehow triggers two simultaneous `signInViaPairing` calls (double-tap on a debounce-failed QR scan, view revival), the actor serializes them and both will run through their own `/api/pairing/confirm`. The App's `iosAuth` middleware short-circuits the second one with `409 already_bound` since the first will have set `device_pubkey` on the row. iOS surfaces the 409 as `AuthError.pairingFailed` and the user re-scans a fresh QR.

`QRScanStepView` additionally debounces at the UI layer — once a scan is in flight (`onboarding == .qrScan(inProgress: true, ...)`), further `onCodeScanned` callbacks are dropped until the in-flight call completes.

---

## 11. iOS Platform Concerns

### 11.1 No URL scheme, no loopback listener

The OAuth-era design needed `CFBundleURLTypes` registration and an
in-app `NWListener` HTTP server to capture the loopback redirect.
**Both are gone.** The QR-pair flow doesn't open a system browser,
doesn't redirect anywhere, and doesn't need any `Info.plist` URL
configuration.

### 11.2 Camera usage (NSCameraUsageDescription)

Required for the QR scanner:

```
INFOPLIST_KEY_NSCameraUsageDescription = "lakeLoom uses the camera to scan the pairing QR code shown by the lakeLoom Databricks App."
```

Already wired in `iOS/project.yml`. The `QRScannerView` SwiftUI view
handles its own permission flow (request prompt for `.notDetermined`,
Settings deeplink for `.denied`).

### 11.3 Privacy Manifest

The privacy manifest (`PrivacyInfo.xcprivacy`) needs no new entries
specifically for AuthService — Keychain is the only sensitive API
this module touches, and that's already declared by the app's
general manifest.

---

## 12. Test Strategy

### 12.1 Unit Tests

- `PairingPayload`: decode happy path (standard base64 + base64url variants), whitespace tolerance, invalid-base64 rejection, malformed-JSON rejection, unsupported-version rejection, ISO 8601 timestamp parsing, cloud-string → Cloud enum mapping.
- `DeviceKeyStore`: keypair persistence across instances (Live, SE-backed when available), signature verification round-trip, reset wipes the blob.
- `RequestSigner`: canonical-form construction, body hash for nil/empty/non-empty bodies, signature verification against the public key.
- `M2MTokenClient`: HTTP Basic auth header, body composition, error mapping (invalid_client → `.invalidClient`, invalid_scope → `.insufficientScope`).
- `LakeloomAppClient`: happy-path two-layer header attachment, M2M cache reuse, M2M near-expiry refresh, 401 type URI → `UnauthorizedReason`, 5xx → `.httpError`, decode failure → `.decodeFailed`, token exchange failure → `.tokenExchangeFailed`.
- `KeychainStore`: round-trip save/load/delete; OSStatus error mapping; new slots (session_token, xcode_spn).
- `AuthService`:
  - `signInViaPairing` happy path (FakeLakeloomAppClient + InMemoryDeviceKeyStore + InMemoryKeychainStore).
  - Invalid QR rejected as `.invalidPairingPayload`.
  - App rejection (e.g. 409 already_bound) surfaces as `.pairingFailed`.
  - Layer 0 M2M failure surfaces as `.refreshFailed`.
  - `signOut` clears Keychain + drops `LakeloomAppClient` config.
  - `currentToken` delegates to `lakeloomApp.currentBearer`.
  - `currentToken` with no active workspace throws `.noActiveWorkspace`.
- Schema-version test: persist a v1 record, attempt load, expect drop + warning.

### 12.2 Integration Tests (manual against the live App)

- Real pairing against `lakeloom-ai-dev`: scan a freshly-rotated QR, observe `/api/pairing/confirm` success, observe subsequent ProjectAPIClient calls succeed.
- M2M token refresh observed across two ProjectAPIClient calls separated by ~1hr (or by faking the clock).
- 401 `token_not_found` on a deliberately-revoked device → iOS clears Keychain and routes to `.qrScan`.
- Force-quit during the confirm round-trip → next launch is at `.qrScan(lastError: nil)` (no orphan in-flight task, no half-pairing in Keychain).
- Remove app + reinstall → Keychain entries persist (iOS behavior); first-launch logic handles re-pair gracefully.

### 12.3 Test Seams

The actor depends on four protocols:
```swift
protocol LakeloomAppClient: Sendable, AnyObject { /* ... */ }
protocol DeviceKeyStoring: Sendable { /* ... */ }
protocol KeychainStore: Sendable { /* ... */ }
protocol M2MTokenClient: Sendable { /* ... */ }
```

Production: `LiveLakeloomAppClient`, `LiveDeviceKeyStore`, `LiveKeychainStore`, `LiveM2MTokenClient`. Test: `FakeLakeloomAppClient`, `InMemoryDeviceKeyStore` (software P256, no SE), `InMemoryKeychainStore`, `FakeM2MTokenClient`. All four test impls already exist under `iOS/AppTests/Auth/Helpers/`.

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

## 16. File Layout (current)

```
App/Auth/
├── AuthService.swift                  // actor, public surface
├── AuthServicing.swift                // protocol + value types + AuthError
├── Pairing/
│   ├── PairingPayload.swift           // QR JSON Codable model
│   ├── XcodeSPNCredentials.swift      // Keychain-stored SPN creds
│   ├── DeviceKeyStore.swift           // Secure Enclave P-256 wrapper
│   ├── M2MTokenClient.swift           // client_credentials grant against /oidc/v1/token
│   ├── RequestSigner.swift            // canonical-form ECDSA signer for Layer 1
│   ├── QRScannerView.swift            // AVFoundation camera view
│   └── OAuthTokenResponse.swift       // shared with M2MTokenClient (RFC 6749 shape)
├── Keychain/
│   ├── KeychainStore.swift            // protocol
│   ├── LiveKeychainStore.swift
│   ├── InMemoryKeychainStore.swift    // test impl
│   └── KeychainError.swift
├── Identity/
│   ├── DatabricksIdentityClient.swift // legacy — SCIM is App-proxied now; types remain for UserIdentity
│   ├── LiveDatabricksIdentityClient.swift
│   └── SCIMMeResponse.swift
└── Diagnostics/
    └── AuthDiagnostics.swift

App/Common/Networking/
├── LakeloomAppClient.swift             // shared App-API primitive (Layer 0 + Layer 1)
├── AppEndpoint.swift
└── AppEndpointResolver.swift           // seeded with credential.appBaseURL at sign-in

App/Common/
└── Base64URLEncoding.swift             // shared Data → base64url helper
```

Tests mirror this layout under `AppTests/Auth/` and `AppTests/Common/`.
