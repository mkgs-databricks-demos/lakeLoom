import Foundation

@testable import LakeloomApp

/// Scriptable ``CaptureAPIClient`` for ``CaptureService`` tests.
/// Records each call and returns either a canned ``CaptureSession``
/// or a typed ``CaptureAPIError``.
public actor FakeCaptureAPIClient: CaptureAPIClient {

    public struct CreateCall: Sendable, Equatable {
        public let workspaceID: String
        public let projectID: String
        public let label: String?
    }

    public struct UpdateCall: Sendable, Equatable {
        public let workspaceID: String
        public let captureSessionID: String
        public let state: CaptureSession.EndState
    }

    public private(set) var createCalls: [CreateCall] = []
    public private(set) var updateCalls: [UpdateCall] = []

    private var nextCreateResults: [Result<CaptureSession, CaptureAPIError>] = []
    private var nextUpdateResults: [Result<CaptureSession, CaptureAPIError>] = []

    public init() {}

    public func enqueueCreateResult(_ result: Result<CaptureSession, CaptureAPIError>) {
        nextCreateResults.append(result)
    }

    public func enqueueUpdateResult(_ result: Result<CaptureSession, CaptureAPIError>) {
        nextUpdateResults.append(result)
    }

    public func createCaptureSession(
        workspaceID: String,
        projectID: String,
        label: String?,
        clientTimestamp: Date?
    ) async throws -> CaptureSession {
        createCalls.append(CreateCall(workspaceID: workspaceID, projectID: projectID, label: label))
        guard !nextCreateResults.isEmpty else {
            return CaptureSession(
                id: "cap-\(UUID().uuidString)",
                projectID: projectID,
                state: .active,
                label: label,
                startedAt: clientTimestamp ?? Date(),
                endedAt: nil
            )
        }
        let result = nextCreateResults.removeFirst()
        switch result {
        case .success(let session): return session
        case .failure(let error):   throw error
        }
    }

    public func updateCaptureSession(
        workspaceID: String,
        captureSessionID: String,
        state: CaptureSession.EndState,
        endedAt: Date?
    ) async throws -> CaptureSession {
        updateCalls.append(UpdateCall(workspaceID: workspaceID, captureSessionID: captureSessionID, state: state))
        guard !nextUpdateResults.isEmpty else {
            return CaptureSession(
                id: captureSessionID,
                projectID: "proj-default",
                state: state == .completed ? .completed : .cancelled,
                label: nil,
                startedAt: Date(),
                endedAt: endedAt
            )
        }
        let result = nextUpdateResults.removeFirst()
        switch result {
        case .success(let session): return session
        case .failure(let error):   throw error
        }
    }

    public func getCaptureSession(
        workspaceID: String,
        captureSessionID: String,
        includeUploads: Bool
    ) async throws -> CaptureSession {
        throw CaptureAPIError.unexpectedResponse(reason: "getCaptureSession not stubbed")
    }

    public func listProjectCaptureSessions(
        workspaceID: String,
        projectID: String,
        state: CaptureSession.State?,
        limit: Int,
        before: Date?
    ) async throws -> [CaptureSession] {
        return []
    }
}
