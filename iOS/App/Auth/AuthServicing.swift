import Foundation

// MARK: - Public protocol

/// The single source of truth for Databricks workspace authentication.
///
/// Implementations own the QR-pair flow, per-workspace Keychain storage of
/// the paired credentials (Xcode SPN + session token + workspace + App URL),
/// and the active-workspace selection. Other modules never touch tokens,
/// Keychain, or the Databricks App URL directly — they call ``currentToken()``
/// for a Layer 0 bearer or go through ``LakeloomAppClient`` for full requests.
///
/// See `architecture/LakeLoomMarkdowns/module-01-auth-service.md` and
/// `architecture/hi_genie/qr-pair-auth-model.md`.
public protocol AuthServicing: Sendable {

    /// All workspaces the user has paired. Empty if never paired.
    var workspaces: [WorkspaceCredential] { get async }

    /// The currently active workspace, if any. Nil before first pairing.
    var activeWorkspace: WorkspaceCredential? { get async }

    /// Stream of identity-relevant changes (sign-in, sign-out, workspace switch).
    /// Multicast — multiple subscribers (e.g. AppCoordinator, IngestService)
    /// can listen in parallel.
    var events: AsyncStream<AuthEvent> { get async }

    /// Returns a Layer 0 bearer token (M2M from Xcode SPN) for the active
    /// workspace. Refreshes silently when the cached token is near expiry.
    /// Delegates to ``LakeloomAppClient/currentBearer(workspaceID:)``.
    ///
    /// Throws ``AuthError/noActiveWorkspace`` if no workspace is active,
    /// ``AuthError/refreshFailed(reason:)`` if the M2M exchange fails,
    /// ``AuthError/networkUnavailable`` if the token endpoint is unreachable.
    func currentToken(forceRefresh: Bool) async throws -> AccessToken

    /// Completes a QR-pair sign-in.
    ///
    /// 1. Decodes the QR string into a ``PairingPayload``.
    /// 2. Generates (or loads) the Secure Enclave device key.
    /// 3. Configures ``LakeloomAppClient`` for the workspace.
    /// 4. POSTs `/api/pairing/confirm` with the device pubkey + label.
    /// 5. Persists workspace credential + session token + Xcode SPN creds.
    /// 6. Activates the workspace and broadcasts `.signedIn`.
    func signInViaPairing(qrText: String, deviceLabel: String) async throws -> WorkspaceCredential

    /// Switches the active workspace. The target must already be in the
    /// workspaces list (i.e. the user must have paired it before).
    func switchWorkspace(to workspaceID: String) async throws

    /// Signs out of a specific workspace. Removes its credential and
    /// associated Keychain entries. If it was the active workspace, the
    /// next available workspace becomes active (or nil if no others
    /// remain). Also drops the workspace from ``LakeloomAppClient`` so
    /// subsequent requests fail closed.
    func signOut(workspaceID: String) async throws

    /// Signs out of all workspaces and clears all stored credentials.
    func signOutAll() async throws
}

extension AuthServicing {
    /// Convenience overload — equivalent to `currentToken(forceRefresh: false)`.
    public func currentToken() async throws -> AccessToken {
        try await currentToken(forceRefresh: false)
    }
}

// MARK: - Value types

/// A signed-in Databricks workspace, including the user identity for that
/// workspace. Tokens are NOT stored here; they live in Keychain keyed by
/// ``id`` so this value can cross actor boundaries safely.
public struct WorkspaceCredential: Sendable, Identifiable, Equatable, Hashable, Codable {
    public let id: String
    public let workspaceURL: URL
    public let workspaceName: String
    public let cloud: Cloud
    public let region: String?
    public let user: UserIdentity
    public let isDefault: Bool
    public let signedInAt: Date
    public let identityRefreshedAt: Date
    /// The Databricks App's HTTPS base URL for this workspace,
    /// delivered via the QR pairing payload's `app.base_url` field.
    /// Every iOS → App API call is built against this prefix.
    public let appBaseURL: URL
    /// How this credential was issued, plus auth-method-specific
    /// metadata (e.g. paired-session id + expiry for QR pairing).
    public let authMethod: AuthMethod

    public init(
        id: String,
        workspaceURL: URL,
        workspaceName: String,
        cloud: Cloud,
        region: String?,
        user: UserIdentity,
        isDefault: Bool,
        signedInAt: Date,
        identityRefreshedAt: Date,
        appBaseURL: URL,
        authMethod: AuthMethod
    ) {
        self.id = id
        self.workspaceURL = workspaceURL
        self.workspaceName = workspaceName
        self.cloud = cloud
        self.region = region
        self.user = user
        self.isDefault = isDefault
        self.signedInAt = signedInAt
        self.identityRefreshedAt = identityRefreshedAt
        self.appBaseURL = appBaseURL
        self.authMethod = authMethod
    }
}

/// How a ``WorkspaceCredential`` was issued. Forward-compatible enum;
/// each case carries the metadata that's only meaningful for that
/// auth path. v1 only supports QR pairing.
public enum AuthMethod: Sendable, Equatable, Hashable, Codable {

    /// Issued via the QR-pair flow against the lakeLoom Databricks
    /// App. The `pairedSessionID` is the App-assigned UUID for this
    /// device's `app.paired_sessions` row (i.e. the value returned in
    /// `POST /api/pairing/confirm`'s `paired_session_id` field).
    /// `sessionExpiresAt` is the 7-day expiry the App sets.
    case qrPaired(pairedSessionID: String, sessionExpiresAt: Date)
}

extension AuthMethod {
    /// The session-expiry timestamp, regardless of which case. Used by
    /// the in-app banner that nudges the user to re-pair before the
    /// 7-day window elapses.
    public var sessionExpiresAt: Date {
        switch self {
        case .qrPaired(_, let expiresAt):
            return expiresAt
        }
    }

    /// The paired-session UUID iOS uses when sending requests. Same
    /// regardless of case for now; case-bound in case a future auth
    /// method doesn't have an analog.
    public var pairedSessionID: String {
        switch self {
        case .qrPaired(let pairedSessionID, _):
            return pairedSessionID
        }
    }
}

/// SCIM-derived identity for a user in a specific workspace.
public struct UserIdentity: Sendable, Equatable, Hashable, Codable {
    public let userID: String
    public let userName: String
    public let displayName: String
    public let email: String?
    public let active: Bool

    public init(userID: String, userName: String, displayName: String, email: String?, active: Bool) {
        self.userID = userID
        self.userName = userName
        self.displayName = displayName
        self.email = email
        self.active = active
    }
}

/// A bearer token for a specific workspace, with its absolute expiry.
public struct AccessToken: Sendable, Equatable, Hashable {
    public let value: String
    public let expiresAt: Date
    public let workspaceID: String

    public init(value: String, expiresAt: Date, workspaceID: String) {
        self.value = value
        self.expiresAt = expiresAt
        self.workspaceID = workspaceID
    }

    /// True when the token is past its expiry (or within `skew` of it).
    public func isExpired(now: Date = Date(), skew: TimeInterval = 30) -> Bool {
        expiresAt <= now.addingTimeInterval(skew)
    }
}

/// The cloud the workspace is hosted on. Best-effort; derived from workspace
/// URL or from a Databricks API response if available.
public enum Cloud: String, Sendable, Codable, CaseIterable {
    case aws
    case azure
    case gcp
    case unknown
}

// MARK: - Events

/// Identity-relevant events emitted by ``AuthServicing/events``.
public enum AuthEvent: Sendable, Equatable {
    case signedIn(WorkspaceCredential)
    case signedOut(workspaceID: String)
    case switchedWorkspace(WorkspaceCredential)
}

// MARK: - Errors

/// Typed errors surfaced by ``AuthServicing``. Internal helpers may throw
/// other error types (`LakeloomAppError`, `KeychainError`, `URLError`,
/// `DeviceKeyStoreError`, `PairingPayload.DecodingError`); the public
/// surface translates them into one of these cases.
public enum AuthError: Error, Sendable, Equatable {
    case noActiveWorkspace
    case unknownWorkspace(String)

    /// QR scan / pairing was cancelled by the user (camera dismissed
    /// without a code, or the QR was rejected by the App with a
    /// retry-allowed status).
    case userCancelled

    /// Scanned QR couldn't be decoded (invalid base64, wrong version,
    /// malformed JSON). Carries a short reason string for the UI.
    case invalidPairingPayload(reason: String)

    /// The App's `/api/pairing/confirm` rejected the device key or
    /// already-bound session. Carries the App-supplied detail.
    case pairingFailed(reason: String)

    /// The Layer 0 M2M token exchange failed (typically because the
    /// Xcode SPN's `client_secret` was rotated). Tokens have been
    /// cleared but the credential record is preserved so the UI can
    /// show "Re-pair to continue" without losing the workspace.
    case refreshFailed(reason: String)

    /// Secure Enclave key generation or signing failed.
    case deviceKeyFailed(reason: String)

    /// Keychain operation failed. Carries the OS status code for diagnostics.
    case keychainFailed(OSStatus)

    /// No network reachable when an authenticated call was attempted.
    case networkUnavailable

    /// The server returned an unexpected response (missing fields, wrong
    /// shape, etc.). Carries a short reason string for logging.
    case unexpectedResponse(reason: String)
}
