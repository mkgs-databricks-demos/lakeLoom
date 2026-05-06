import Foundation
import Testing

@testable import LakeloomApp

@Suite("OAuthTokenResponse")
struct OAuthTokenResponseTests {

    @Test("decodes a Databricks-shaped success response")
    func decodesSuccessResponse() throws {
        let json = """
        {
          "access_token": "atk",
          "refresh_token": "rtk",
          "token_type": "Bearer",
          "expires_in": 3600,
          "scope": "all-apis offline_access"
        }
        """.data(using: .utf8) ?? Data()
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: json)
        #expect(response.accessToken == "atk")
        #expect(response.refreshToken == "rtk")
        #expect(response.tokenType == "Bearer")
        #expect(response.expiresIn == 3600)
        #expect(response.scope == "all-apis offline_access")
    }

    @Test("decodes a refresh response without a rotated refresh_token")
    func decodesWithoutRefreshToken() throws {
        let json = """
        {
          "access_token": "atk2",
          "token_type": "Bearer",
          "expires_in": 1800
        }
        """.data(using: .utf8) ?? Data()
        let response = try JSONDecoder().decode(OAuthTokenResponse.self, from: json)
        #expect(response.refreshToken == nil)
        #expect(response.scope == nil)
    }
}

@Suite("OAuthTokenErrorResponse")
struct OAuthTokenErrorResponseTests {

    @Test("isInvalidGrant true for invalid_grant")
    func invalidGrantDetected() throws {
        let json = """
        {
          "error": "invalid_grant",
          "error_description": "Refresh token is expired"
        }
        """.data(using: .utf8) ?? Data()
        let response = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: json)
        #expect(response.isInvalidGrant == true)
    }

    @Test("isInvalidGrant false for unrelated errors")
    func nonInvalidGrant() throws {
        let json = """
        {
          "error": "invalid_request",
          "error_description": "missing parameter"
        }
        """.data(using: .utf8) ?? Data()
        let response = try JSONDecoder().decode(OAuthTokenErrorResponse.self, from: json)
        #expect(response.isInvalidGrant == false)
    }
}
