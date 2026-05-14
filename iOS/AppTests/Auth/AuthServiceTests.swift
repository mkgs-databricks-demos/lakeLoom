import Foundation
import Testing

@testable import LakeloomApp

@Suite("AuthService — QR-pair flow")
struct AuthServiceTests {

    // MARK: Fixtures

    private static let workspaceURL = URL(string: "https://acme.cloud.databricks.com")!
    private static let appBaseURL = URL(string: "https://lakeloom-ai-dev-1234.aws.databricksapps.com")!

    private static func samplePayloadJSON(
        workspaceHost: String = "acme.cloud.databricks.com",
        appBase: String = "https://lakeloom-ai-dev-1234.aws.databricksapps.com"
    ) -> String {
        """
        {
          "v": 1,
          "workspace": {
            "url": "https://\(workspaceHost)",
            "id": "1234",
            "name": "ACME",
            "cloud": "aws"
          },
          "user": {
            "scim_id": "5f33",
            "user_name": "user@example.com",
            "display_name": "Test User"
          },
          "xcode_spn": {
            "client_id": "xcode-client",
            "client_secret": "xcode-secret"
          },
          "session": {
            "token": "session-tok",
            "expires_at": "2026-05-21T20:00:00Z"
          },
          "app": {
            "base_url": "\(appBase)"
          }
        }
        """
    }

    private static func encodedQR(json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    /// Builds an AuthService with all in-memory deps + a programmable
    /// pairing-confirm response.
    private static func makeService(
        confirmResponseJSON: String? = nil,
        confirmStatusCode: Int = 200,
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async -> (
        AuthService,
        FakeLakeloomAppClient,
        InMemoryDeviceKeyStore,
        InMemoryKeychainStore
    ) {
        let lakeloom = FakeLakeloomAppClient()
        let deviceKeys = InMemoryDeviceKeyStore()
        let keychain = InMemoryKeychainStore()
        if let body = confirmResponseJSON {
            await lakeloom.enqueueResponse(
                .success(Data(body.utf8))
            )
        }
        let service = AuthService(
            lakeloomApp: lakeloom,
            deviceKeyStore: deviceKeys,
            keychain: keychain,
            nowProvider: { now }
        )
        return (service, lakeloom, deviceKeys, keychain)
    }

    // MARK: signInViaPairing happy path

    @Test("signInViaPairing decodes QR, configures lakeloomApp, posts confirm, persists credentials")
    func signInHappyPath() async throws {
        let confirmBody = """
        {
          "paired_session_id": "paired-uuid-1",
          "paired_at": "2026-05-14T10:00:00Z",
          "expires_at": "2026-05-21T20:00:00Z"
        }
        """
        let (service, lakeloom, _, keychain) = await Self.makeService(
            confirmResponseJSON: confirmBody
        )
        let qr = Self.encodedQR(json: Self.samplePayloadJSON())

        let credential = try await service.signInViaPairing(
            qrText: qr,
            deviceLabel: "Test iPhone"
        )

        #expect(credential.id == "acme.cloud.databricks.com")
        #expect(credential.workspaceName == "ACME")
        #expect(credential.cloud == .aws)
        #expect(credential.appBaseURL == Self.appBaseURL)
        #expect(credential.user.userName == "user@example.com")
        if case .qrPaired(let pairedID, _) = credential.authMethod {
            #expect(pairedID == "paired-uuid-1")
        } else {
            Issue.record("expected qrPaired auth method")
        }

        // Verify Keychain was populated.
        let stored = try await keychain.loadCredential(workspaceID: credential.id)
        #expect(stored.appBaseURL == Self.appBaseURL)
        let sessionToken = try await keychain.loadSessionToken(workspaceID: credential.id)
        #expect(sessionToken == "session-tok")
        let xcodeSPN = try await keychain.loadXcodeSPNCredentials(workspaceID: credential.id)
        #expect(xcodeSPN.clientID == "xcode-client")
        #expect(xcodeSPN.clientSecret == "xcode-secret")

        // Verify lakeloomApp was configured.
        let configured = await lakeloom.configured[credential.id]
        #expect(configured?.appBaseURL == Self.appBaseURL)
        #expect(configured?.sessionToken == "session-tok")

        // Verify exactly one /api/pairing/confirm request.
        let calls = await lakeloom.requestCalls
        #expect(calls.count == 1)
        #expect(calls.first?.path == "/api/pairing/confirm")
        #expect(calls.first?.method == .post)
    }

    // MARK: Error paths

    @Test("signInViaPairing rejects malformed QR")
    func invalidQR() async throws {
        let (service, _, _, _) = await Self.makeService()
        do {
            _ = try await service.signInViaPairing(
                qrText: "!!!definitely not base64!!!",
                deviceLabel: "iPhone"
            )
            Issue.record("expected invalidPairingPayload")
        } catch let error as AuthError {
            switch error {
            case .invalidPairingPayload: break
            default: Issue.record("expected invalidPairingPayload, got \(error)")
            }
        }
    }

    @Test("signInViaPairing surfaces App-side rejections as pairingFailed")
    func confirmRejected() async throws {
        let lakeloom = FakeLakeloomAppClient()
        await lakeloom.enqueueResponse(.failure(
            LakeloomAppError.httpError(status: 409, detail: "already_bound")
        ))
        let service = AuthService(
            lakeloomApp: lakeloom,
            deviceKeyStore: InMemoryDeviceKeyStore(),
            keychain: InMemoryKeychainStore()
        )
        let qr = Self.encodedQR(json: Self.samplePayloadJSON())

        do {
            _ = try await service.signInViaPairing(qrText: qr, deviceLabel: "iPhone")
            Issue.record("expected pairingFailed")
        } catch let error as AuthError {
            switch error {
            case .pairingFailed(let reason):
                #expect(reason.contains("409") || reason.contains("already_bound"))
            default: Issue.record("expected pairingFailed, got \(error)")
            }
        }
    }

    @Test("signInViaPairing maps Layer 0 token failure to refreshFailed")
    func tokenExchangeFailed() async throws {
        let lakeloom = FakeLakeloomAppClient()
        await lakeloom.enqueueResponse(.failure(
            LakeloomAppError.tokenExchangeFailed(reason: "invalid_client")
        ))
        let service = AuthService(
            lakeloomApp: lakeloom,
            deviceKeyStore: InMemoryDeviceKeyStore(),
            keychain: InMemoryKeychainStore()
        )
        let qr = Self.encodedQR(json: Self.samplePayloadJSON())

        do {
            _ = try await service.signInViaPairing(qrText: qr, deviceLabel: "iPhone")
            Issue.record("expected refreshFailed")
        } catch let error as AuthError {
            switch error {
            case .refreshFailed(let reason):
                #expect(reason.contains("invalid_client"))
            default: Issue.record("expected refreshFailed, got \(error)")
            }
        }
    }

    // MARK: Sign-out + current token

    @Test("signOut clears Keychain entries and drops lakeloomApp config")
    func signOutCleansUp() async throws {
        let confirmBody = """
        { "paired_session_id": "p-1", "paired_at": null, "expires_at": null }
        """
        let (service, lakeloom, _, keychain) = await Self.makeService(
            confirmResponseJSON: confirmBody
        )
        let qr = Self.encodedQR(json: Self.samplePayloadJSON())
        let credential = try await service.signInViaPairing(qrText: qr, deviceLabel: "iPhone")

        try await service.signOut(workspaceID: credential.id)

        let workspaces = await service.workspaces
        #expect(workspaces.isEmpty)
        let active = await service.activeWorkspace
        #expect(active == nil)

        // Verify lakeloomApp.removeConfiguration was called.
        let removed = await lakeloom.removedConfigurations
        #expect(removed.contains(credential.id))

        // Verify Keychain entries are gone.
        do {
            _ = try await keychain.loadSessionToken(workspaceID: credential.id)
            Issue.record("expected itemNotFound")
        } catch KeychainError.itemNotFound {
            #expect(Bool(true))
        }
    }

    @Test("currentToken delegates to lakeloomApp.currentBearer")
    func currentTokenDelegates() async throws {
        let confirmBody = """
        { "paired_session_id": "p-1", "paired_at": null, "expires_at": null }
        """
        let (service, lakeloom, _, _) = await Self.makeService(
            confirmResponseJSON: confirmBody
        )
        await lakeloom.setNextBearer("m2m-bearer-xyz")
        let qr = Self.encodedQR(json: Self.samplePayloadJSON())
        _ = try await service.signInViaPairing(qrText: qr, deviceLabel: "iPhone")

        let token = try await service.currentToken()
        #expect(token.value == "m2m-bearer-xyz")
    }

    @Test("currentToken throws noActiveWorkspace when not paired")
    func currentTokenNoWorkspace() async throws {
        let (service, _, _, _) = await Self.makeService()
        do {
            _ = try await service.currentToken()
            Issue.record("expected noActiveWorkspace")
        } catch let error as AuthError {
            switch error {
            case .noActiveWorkspace: break
            default: Issue.record("expected noActiveWorkspace, got \(error)")
            }
        }
    }
}
