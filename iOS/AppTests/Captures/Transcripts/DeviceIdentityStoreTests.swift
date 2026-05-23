import Foundation
import Testing

@testable import LakeloomApp

@Suite("InMemoryDeviceIdentityStore")
struct InMemoryDeviceIdentityStoreTests {

    @Test("First read lazy-creates a UUID")
    func firstReadCreates() async throws {
        let store = InMemoryDeviceIdentityStore()
        #expect(await store.currentValue() == nil)
        let id = try await store.deviceID()
        #expect(!id.isEmpty)
        #expect(UUID(uuidString: id) != nil, "should be a valid UUID")
        #expect(await store.currentValue() == id)
    }

    @Test("Subsequent reads return the same value")
    func subsequentReadsAreStable() async throws {
        let store = InMemoryDeviceIdentityStore()
        let first = try await store.deviceID()
        let second = try await store.deviceID()
        let third = try await store.deviceID()
        #expect(first == second)
        #expect(second == third)
    }

    @Test("Preloaded value short-circuits creation")
    func preloadedRoundTrips() async throws {
        let store = InMemoryDeviceIdentityStore(preloaded: "preloaded-uuid")
        let id = try await store.deviceID()
        #expect(id == "preloaded-uuid")
    }

    @Test("Each store instance generates its own UUID — they should not collide")
    func distinctStoresHaveDistinctIDs() async throws {
        let storeA = InMemoryDeviceIdentityStore()
        let storeB = InMemoryDeviceIdentityStore()
        let a = try await storeA.deviceID()
        let b = try await storeB.deviceID()
        #expect(a != b, "fresh stores must generate different UUIDs")
    }
}
