import Foundation
import Testing

@testable import LakeloomApp

@Suite("SCIMMeResponse")
struct SCIMMeResponseTests {

    @Test("primaryEmail returns the .primary entry when present")
    func primaryEmailFromPrimaryFlag() {
        let response = SCIMMeResponse(
            id: "1",
            userName: "u@example.com",
            displayName: "User",
            active: true,
            emails: [
                .init(value: "secondary@example.com", primary: false),
                .init(value: "main@example.com", primary: true)
            ]
        )
        #expect(response.primaryEmail == "main@example.com")
    }

    @Test("primaryEmail falls back to first entry when none flagged")
    func primaryEmailFallsBackToFirst() {
        let response = SCIMMeResponse(
            id: "1",
            userName: "u@example.com",
            displayName: "User",
            active: true,
            emails: [
                .init(value: "first@example.com", primary: nil),
                .init(value: "second@example.com", primary: nil)
            ]
        )
        #expect(response.primaryEmail == "first@example.com")
    }

    @Test("primaryEmail nil when emails missing or empty")
    func primaryEmailNil() {
        let none = SCIMMeResponse(id: "1", userName: "u", displayName: "U", active: true, emails: nil)
        #expect(none.primaryEmail == nil)
        let empty = SCIMMeResponse(id: "1", userName: "u", displayName: "U", active: true, emails: [])
        #expect(empty.primaryEmail == nil)
    }

    @Test("toUserIdentity falls back displayName to userName when missing, defaults active to true")
    func toUserIdentityDefaults() {
        let response = SCIMMeResponse(
            id: "abc",
            userName: "user@example.com",
            displayName: nil,
            active: nil,
            emails: nil
        )
        let identity = response.toUserIdentity()
        #expect(identity.userID == "abc")
        #expect(identity.userName == "user@example.com")
        #expect(identity.displayName == "user@example.com")
        #expect(identity.active == true)
        #expect(identity.email == nil)
    }
}
