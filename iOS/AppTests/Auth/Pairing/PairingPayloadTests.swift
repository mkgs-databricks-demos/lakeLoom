import Foundation
import Testing

@testable import LakeloomApp

@Suite("PairingPayload")
struct PairingPayloadTests {

    private static let sampleJSON = """
    {
      "v": 1,
      "workspace": {
        "url": "https://fevm-hls-fde.cloud.databricks.com",
        "id": "7474657291520070",
        "name": "FE-VM HLS FDE",
        "cloud": "aws"
      },
      "user": {
        "scim_id": "5f33-abc",
        "user_name": "matthew.giglia@databricks.com",
        "display_name": "Matthew Giglia"
      },
      "xcode_spn": {
        "client_id": "xcode-client-id",
        "client_secret": "xcode-client-secret"
      },
      "session": {
        "token": "session-token-abc",
        "expires_at": "2026-05-21T20:00:00Z"
      },
      "app": {
        "base_url": "https://lakeloom-ai-dev-7474657291520070.aws.databricksapps.com"
      }
    }
    """

    private static func encodedQR(json: String, useBase64URL: Bool = false) -> String {
        let data = Data(json.utf8)
        let std = data.base64EncodedString()
        guard useBase64URL else { return std }
        return std
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @Test("decode happy path — standard base64")
    func decodeHappyPath() throws {
        let qr = Self.encodedQR(json: Self.sampleJSON, useBase64URL: false)
        let payload = try PairingPayload.decode(from: qr)

        #expect(payload.version == 1)
        #expect(payload.workspace.id == "7474657291520070")
        #expect(payload.workspace.cloudCase == .aws)
        #expect(payload.user.userName == "matthew.giglia@databricks.com")
        #expect(payload.xcodeSPN.clientID == "xcode-client-id")
        #expect(payload.session.token == "session-token-abc")
        #expect(payload.app.baseURL.absoluteString.hasPrefix("https://lakeloom-ai-dev"))
    }

    @Test("decode happy path — base64url (unpadded)")
    func decodeBase64URL() throws {
        let qr = Self.encodedQR(json: Self.sampleJSON, useBase64URL: true)
        let payload = try PairingPayload.decode(from: qr)
        #expect(payload.version == 1)
        #expect(payload.user.displayName == "Matthew Giglia")
    }

    @Test("decode handles Data URI wrapper — `data:application/json;base64,<payload>`")
    func decodeDataURIWrapper() throws {
        // Live shape from lakeloom-ai/client/src/pages/pairing/PairingPage.tsx:
        // `data:application/json;base64,${btoa(JSON.stringify(payload))}`
        let base64 = Self.encodedQR(json: Self.sampleJSON, useBase64URL: false)
        let dataURI = "data:application/json;base64,\(base64)"

        let payload = try PairingPayload.decode(from: dataURI)
        #expect(payload.version == 1)
        #expect(payload.workspace.id == "7474657291520070")
    }

    @Test("decode handles Data URI variants (different MIMEs)")
    func decodeDataURIVariantMIMEs() throws {
        let base64 = Self.encodedQR(json: Self.sampleJSON, useBase64URL: false)
        let variants = [
            "data:text/plain;base64,\(base64)",
            "data:application/octet-stream;base64,\(base64)",
            "data:;base64,\(base64)",  // empty MIME is legal per RFC 2397
        ]
        for variant in variants {
            let payload = try PairingPayload.decode(from: variant)
            #expect(payload.version == 1)
        }
    }

    @Test("decode happy path — raw JSON (no base64 wrapper)")
    func decodeRawJSON() throws {
        // Genie's pairing endpoint now serves the JSON directly via
        // the QR (the network response in the browser DevTools is
        // the literal JSON object). iOS must accept this without a
        // base64/data-URI wrapper.
        let payload = try PairingPayload.decode(from: Self.sampleJSON)
        #expect(payload.version == 1)
        #expect(payload.workspace.id == "7474657291520070")
        #expect(payload.user.displayName == "Matthew Giglia")
    }

    @Test("decode raw JSON tolerates leading/trailing whitespace")
    func decodeRawJSONTrimsWhitespace() throws {
        let qr = "  \n\(Self.sampleJSON)\n  "
        let payload = try PairingPayload.decode(from: qr)
        #expect(payload.version == 1)
    }

    @Test("decode tolerates leading/trailing whitespace")
    func decodeTrimsWhitespace() throws {
        let qr = "  \n" + Self.encodedQR(json: Self.sampleJSON) + "\n  "
        let payload = try PairingPayload.decode(from: qr)
        #expect(payload.version == 1)
    }

    @Test("decode rejects non-base64 input")
    func decodeRejectsNonBase64() {
        do {
            _ = try PairingPayload.decode(from: "!!!not base64 at all!!!")
            Issue.record("expected invalidBase64")
        } catch let error as PairingPayload.DecodingError {
            switch error {
            case .invalidBase64: break
            default: Issue.record("expected invalidBase64, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("decode rejects malformed JSON")
    func decodeRejectsMalformedJSON() {
        let bad = Data("{not even close to valid json".utf8).base64EncodedString()
        do {
            _ = try PairingPayload.decode(from: bad)
            Issue.record("expected invalidJSON")
        } catch let error as PairingPayload.DecodingError {
            switch error {
            case .invalidJSON: break
            default: Issue.record("expected invalidJSON, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("decode rejects unsupported version")
    func decodeRejectsUnsupportedVersion() {
        let v2JSON = Self.sampleJSON.replacingOccurrences(of: "\"v\": 1", with: "\"v\": 99")
        let qr = Self.encodedQR(json: v2JSON)
        do {
            _ = try PairingPayload.decode(from: qr)
            Issue.record("expected unsupportedVersion")
        } catch let error as PairingPayload.DecodingError {
            switch error {
            case .unsupportedVersion(let found, let supported):
                #expect(found == 99)
                #expect(supported == 1)
            default:
                Issue.record("expected unsupportedVersion, got \(error)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("session expires_at parses as ISO 8601 with Z suffix")
    func sessionExpiresAtParsesISO8601() throws {
        let qr = Self.encodedQR(json: Self.sampleJSON)
        let payload = try PairingPayload.decode(from: qr)
        // 2026-05-21T20:00:00Z
        let expected = Date(timeIntervalSince1970: 1_779_393_600)
        #expect(payload.session.expiresAt == expected)
    }

    @Test("cloud case maps lowercase string to enum, unknown falls through")
    func cloudCaseMapping() {
        let aws = PairingPayload.WorkspaceInfo(url: URL(string: "https://x")!, id: "1", name: "x", cloud: "aws")
        let azure = PairingPayload.WorkspaceInfo(url: URL(string: "https://x")!, id: "1", name: "x", cloud: "AZURE")
        let weird = PairingPayload.WorkspaceInfo(url: URL(string: "https://x")!, id: "1", name: "x", cloud: "uhhh")

        #expect(aws.cloudCase == .aws)
        #expect(azure.cloudCase == .azure)
        #expect(weird.cloudCase == .unknown)
    }
}
