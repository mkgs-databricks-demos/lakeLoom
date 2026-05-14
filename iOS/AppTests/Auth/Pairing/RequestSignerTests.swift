import CryptoKit
import Foundation
import Testing

@testable import LakeloomApp

@Suite("RequestSigner — canonical form")
struct RequestSignerCanonicalFormTests {

    @Test("method is uppercased")
    func methodIsUppercased() {
        let canonical = RequestSigner.canonicalForm(
            method: "post",
            pathAndQuery: "/api/projects",
            timestamp: "1715284800",
            bodyHash: ""
        )
        #expect(canonical.hasPrefix("POST\n"))
    }

    @Test("path is preserved verbatim including query string")
    func pathIsPreservedVerbatim() {
        let canonical = RequestSigner.canonicalForm(
            method: "GET",
            pathAndQuery: "/api/projects?include=defaults&limit=10",
            timestamp: "1715284800",
            bodyHash: ""
        )
        #expect(canonical.contains("/api/projects?include=defaults&limit=10"))
    }

    @Test("fields joined by single newlines")
    func fieldsJoinedBySingleNewlines() {
        let canonical = RequestSigner.canonicalForm(
            method: "POST",
            pathAndQuery: "/api/x",
            timestamp: "100",
            bodyHash: "abc"
        )
        #expect(canonical == "POST\n/api/x\n100\nabc")
    }

    /// SHA-256 of zero bytes — what the canonical form uses for any
    /// bodyless (or empty-body) request. Locked in Genie's
    /// 2026-05-13_upload-traceability-response.md.
    private static let sha256OfEmpty =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test("body hash for nil body is sha256 of empty bytes")
    func bodyHashForNilBody() {
        #expect(RequestSigner.bodyHash(for: nil) == Self.sha256OfEmpty)
    }

    @Test("body hash for empty Data is sha256 of empty bytes")
    func bodyHashForEmptyData() {
        // Matches Genie's server-side `hashlib.sha256(b'').hexdigest()`
        // — both nil and Data() must yield the same canonical hash so
        // signed bodyless requests verify on the App side.
        #expect(RequestSigner.bodyHash(for: Data()) == Self.sha256OfEmpty)
    }

    @Test("body hash is lowercase hex sha256")
    func bodyHashIsLowercaseHex() {
        let body = Data("hello".utf8)
        let hash = RequestSigner.bodyHash(for: body)
        // sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}

@Suite("RequestSigner — sign() integration")
struct RequestSignerSignTests {

    @Test("sign() returns timestamp and signature headers")
    func returnsExpectedHeaders() async throws {
        let store = InMemoryDeviceKeyStore()
        let fixedDate = Date(timeIntervalSince1970: 1_715_284_800)
        let signer = RequestSigner(keyStore: store, nowProvider: { fixedDate })

        let headers = try await signer.sign(
            method: "POST",
            pathAndQuery: "/api/projects",
            body: Data("{\"name\":\"test\"}".utf8)
        )

        #expect(headers[RequestSigner.timestampHeader] == "1715284800")
        #expect(headers[RequestSigner.signatureHeader]?.isEmpty == false)
    }

    @Test("the produced signature verifies against the device's public key")
    func signatureVerifiesAgainstPublicKey() async throws {
        let store = InMemoryDeviceKeyStore()
        let fixedDate = Date(timeIntervalSince1970: 1_715_284_800)
        let signer = RequestSigner(keyStore: store, nowProvider: { fixedDate })

        let body = Data("{\"label\":\"iPhone\"}".utf8)
        let headers = try await signer.sign(
            method: "POST",
            pathAndQuery: "/api/pairing/confirm",
            body: body
        )

        // Reconstruct what the App would verify against.
        let timestamp = headers[RequestSigner.timestampHeader]!
        let signatureBase64URL = headers[RequestSigner.signatureHeader]!
        let canonical = RequestSigner.canonicalForm(
            method: "POST",
            pathAndQuery: "/api/pairing/confirm",
            timestamp: timestamp,
            bodyHash: RequestSigner.bodyHash(for: body)
        )

        guard let signatureDER = Data.fromBase64URLEncoded(signatureBase64URL) else {
            Issue.record("signature header was not base64url decodable")
            return
        }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        let pubKey = await store.currentPublicKey()
        #expect(pubKey.isValidSignature(signature, for: Data(canonical.utf8)))
    }

    @Test("two consecutive signatures of the same request differ — ECDSA randomness")
    func ecdsaSignaturesAreNonDeterministic() async throws {
        let store = InMemoryDeviceKeyStore()
        let signer = RequestSigner(keyStore: store)

        let h1 = try await signer.sign(method: "GET", pathAndQuery: "/api/x", body: nil)
        let h2 = try await signer.sign(method: "GET", pathAndQuery: "/api/x", body: nil)

        #expect(h1[RequestSigner.signatureHeader] != h2[RequestSigner.signatureHeader])
    }

    @Test("nil body and empty body produce the same canonical hash")
    func nilAndEmptyBodyEquivalent() async throws {
        let store = InMemoryDeviceKeyStore()
        let fixedDate = Date(timeIntervalSince1970: 1_715_284_800)
        let signer = RequestSigner(keyStore: store, nowProvider: { fixedDate })

        let h1 = try await signer.sign(method: "GET", pathAndQuery: "/api/x", body: nil)
        let h2 = try await signer.sign(method: "GET", pathAndQuery: "/api/x", body: Data())

        // Different signatures (ECDSA randomness) but same canonical
        // body hash → both verify against the same canonical form.
        let canonical = RequestSigner.canonicalForm(
            method: "GET",
            pathAndQuery: "/api/x",
            timestamp: h1[RequestSigner.timestampHeader]!,
            bodyHash: RequestSigner.bodyHash(for: nil)
        )
        let pub = await store.currentPublicKey()
        let s1 = try P256.Signing.ECDSASignature(
            derRepresentation: Data.fromBase64URLEncoded(h1[RequestSigner.signatureHeader]!)!
        )
        let s2 = try P256.Signing.ECDSASignature(
            derRepresentation: Data.fromBase64URLEncoded(h2[RequestSigner.signatureHeader]!)!
        )
        #expect(pub.isValidSignature(s1, for: Data(canonical.utf8)))
        #expect(pub.isValidSignature(s2, for: Data(canonical.utf8)))
    }
}

// MARK: - Test helper: base64url decode

extension Data {
    fileprivate static func fromBase64URLEncoded(_ string: String) -> Data? {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded)
    }
}
