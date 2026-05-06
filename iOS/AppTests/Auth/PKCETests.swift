import Foundation
import Testing

@testable import LakeloomApp

@Suite("PKCE")
struct PKCETests {

    @Test("generate() produces an S256 method, 43-char verifier, and challenge derivable from it")
    func generateProducesValidMaterial() throws {
        let pkce = try PKCE.generate()
        #expect(pkce.codeChallengeMethod == "S256")
        // Base64url(32 random bytes) without padding is exactly 43 chars.
        #expect(pkce.codeVerifier.count == 43)
        // Re-deriving the challenge from the verifier should match.
        let rederived = PKCE.from(verifier: pkce.codeVerifier)
        #expect(rederived.codeChallenge == pkce.codeChallenge)
    }

    @Test("verifier is URL-safe (no +/= chars)")
    func verifierIsURLSafe() throws {
        let pkce = try PKCE.generate()
        let forbidden = CharacterSet(charactersIn: "+/=")
        #expect(pkce.codeVerifier.unicodeScalars.allSatisfy { !forbidden.contains($0) })
        #expect(pkce.codeChallenge.unicodeScalars.allSatisfy { !forbidden.contains($0) })
    }

    @Test("two consecutive generations produce different verifiers")
    func generationIsRandom() throws {
        let a = try PKCE.generate()
        let b = try PKCE.generate()
        #expect(a.codeVerifier != b.codeVerifier)
    }

    @Test("from(verifier:) is deterministic — same verifier → same challenge")
    func fromVerifierIsDeterministic() {
        let a = PKCE.from(verifier: "fixed-test-verifier-string-43-chars-padding-")
        let b = PKCE.from(verifier: "fixed-test-verifier-string-43-chars-padding-")
        #expect(a == b)
    }
}

@Suite("Data.base64URLEncodedString")
struct Base64URLTests {
    @Test("strips padding and substitutes URL-safe characters")
    func stripsPaddingAndSubstitutes() {
        // 0xFB 0xFF 0xBF — chosen because base64-standard encodes to "+/+/" / "+/=" patterns.
        let bytes = Data([0xFB, 0xFF, 0xBF])
        let encoded = bytes.base64URLEncodedString()
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        // Sanity: base64-standard equivalent should contain at least one of +/ or = padding.
        let standard = bytes.base64EncodedString()
        #expect(standard.contains("+") || standard.contains("/") || standard.hasSuffix("="))
    }
}
