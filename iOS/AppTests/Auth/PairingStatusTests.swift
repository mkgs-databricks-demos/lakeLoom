import Foundation
import Testing

@testable import LakeloomApp

@Suite("PairingStatus")
struct PairingStatusTests {

    private static let now = Date(timeIntervalSince1970: 1_747_152_120)

    @Test("healthy when more than 7 days remain")
    func healthyBeyondSevenDays() {
        let expiresAt = Self.now.addingTimeInterval(10 * 86400)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.level == .healthy)
        #expect(status.shortDescription == "Expires in 10 days")
    }

    @Test("soft warning between 48h and 7 days")
    func softBucket() {
        let expiresAt = Self.now.addingTimeInterval(3 * 86400)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.level == .soft)
        #expect(status.shortDescription == "Expires in 3 days")
    }

    @Test("warning between 12h and 48h")
    func warningBucket() {
        let expiresAt = Self.now.addingTimeInterval(36 * 3600)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.level == .warning)
        #expect(status.shortDescription == "Expires in 36 hours")
    }

    @Test("sub-48h renders in hours, not days — sharper signal")
    func subFortyEightInHours() {
        let expiresAt = Self.now.addingTimeInterval(30 * 3600)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.level == .warning)
        #expect(status.shortDescription == "Expires in 30 hours")
    }

    @Test("urgent under 12h with hours phrasing")
    func urgentHours() {
        let expiresAt = Self.now.addingTimeInterval(4 * 3600)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.level == .urgent)
        #expect(status.shortDescription == "Expires in 4 hours")
    }

    @Test("urgent under 1h drops to minutes")
    func urgentMinutes() {
        let expiresAt = Self.now.addingTimeInterval(30 * 60)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.level == .urgent)
        #expect(status.shortDescription == "Expires in 30 minutes")
    }

    @Test("already expired clamps + reports Expired")
    func expired() {
        let expiresAt = Self.now.addingTimeInterval(-3600)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.level == .urgent)
        #expect(status.shortDescription == "Expired")
        #expect(status.secondsUntilExpiry == 0)
        #expect(status.longDescription.contains("Pairing expired"))
    }

    @Test("long description embeds the formatted date when healthy")
    func longDescriptionHealthy() {
        let expiresAt = Self.now.addingTimeInterval(10 * 86400)
        let status = PairingStatus(expiresAt: expiresAt, now: Self.now)
        #expect(status.longDescription.hasPrefix("Paired until "))
    }
}
