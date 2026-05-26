import Foundation
import Testing

@testable import LakeloomApp

@Suite("OperationQueueStore")
struct OperationQueueStoreTests {

    private static func makeStore() -> (OperationQueueStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lakeloom-op-queue-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("operation-queue.json", isDirectory: false)
        return (OperationQueueStore(fileURL: url), url)
    }

    private static func makeOp(id: String, variant: PendingOperation.Variant) -> PendingOperation {
        PendingOperation(
            id: id,
            workspaceID: "ws-1",
            variant: variant,
            createdAt: Date(timeIntervalSince1970: 1_747_152_120)
        )
    }

    @Test("load on a missing file returns empty array")
    func loadMissing() async {
        let (store, _) = Self.makeStore()
        let ops = await store.load()
        #expect(ops.isEmpty)
    }

    @Test("save then load round-trips operations in order")
    func saveLoadRoundTrip() async throws {
        let (store, _) = Self.makeStore()
        let o1 = Self.makeOp(id: "o1", variant: .createCaptureSession(
            captureSessionID: "cap-1",
            projectID: "proj-1",
            label: "demo",
            clientTimestamp: Date(timeIntervalSince1970: 1_747_152_120),
            deviceID: "dev-1"
        ))
        let o2 = Self.makeOp(id: "o2", variant: .updateCaptureSessionState(
            captureSessionID: "cap-1",
            endState: .completed,
            endedAt: Date(timeIntervalSince1970: 1_747_152_180)
        ))
        try await store.save([o1, o2])

        let restored = await store.load()
        #expect(restored.count == 2)
        #expect(restored[0].id == "o1")
        #expect(restored[1].id == "o2")
        // Variant survives Codable round-trip
        if case .createCaptureSession(let captureSessionID, _, _, _, _) = restored[0].variant {
            #expect(captureSessionID == "cap-1")
        } else {
            Issue.record("Expected createCaptureSession variant, got \(restored[0].variant)")
        }
        if case .updateCaptureSessionState(_, let endState, _) = restored[1].variant {
            #expect(endState == .completed)
        } else {
            Issue.record("Expected updateCaptureSessionState variant, got \(restored[1].variant)")
        }
    }

    @Test("load on a corrupt file returns empty without throwing")
    func loadCorrupt() async throws {
        let (store, url) = Self.makeStore()
        try Data("not json".utf8).write(to: url)
        let ops = await store.load()
        #expect(ops.isEmpty)
    }

    @Test("clear deletes the file")
    func clearRemovesFile() async throws {
        let (store, url) = Self.makeStore()
        try await store.save([Self.makeOp(
            id: "o1",
            variant: .updateCaptureLabel(captureSessionID: "cap-1", label: "new")
        )])
        #expect(FileManager.default.fileExists(atPath: url.path))
        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("every variant survives Codable round-trip")
    func everyVariantRoundTrips() async throws {
        let (store, _) = Self.makeStore()
        let ts = Date(timeIntervalSince1970: 1_747_152_120)
        let ops: [PendingOperation] = [
            Self.makeOp(id: "create-cap", variant: .createCaptureSession(
                captureSessionID: "cap-uuidv7", projectID: "p1",
                label: nil, clientTimestamp: ts, deviceID: nil
            )),
            Self.makeOp(id: "state", variant: .updateCaptureSessionState(
                captureSessionID: "cap-uuidv7", endState: .cancelled, endedAt: nil
            )),
            Self.makeOp(id: "label", variant: .updateCaptureLabel(
                captureSessionID: "cap-uuidv7", label: "renamed"
            )),
            Self.makeOp(id: "create-proj", variant: .createProject(
                projectID: "p-uuidv7", name: "Acme", description: "an offline-created project"
            )),
            Self.makeOp(id: "update-proj", variant: .updateProject(
                projectID: "p1", name: "Renamed", description: nil
            ))
        ]
        try await store.save(ops)

        let restored = await store.load()
        #expect(restored.count == 5)
        #expect(restored.map(\.id) == ops.map(\.id))
        #expect(restored.map(\.variant.category) == [
            "capture.create", "capture.state", "capture.label",
            "project.create", "project.update"
        ])
    }
}
