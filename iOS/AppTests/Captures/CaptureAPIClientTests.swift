import Foundation
import Testing

@testable import LakeloomApp

@Suite("LiveCaptureAPIClient — create / update")
struct LiveCaptureAPIClientCreateUpdateTests {

    private static let workspaceID = "fevm-hls-fde"
    private static let projectID = "proj-123"
    private static let captureID = "cap-abc"
    private static let createdAt = "2026-05-15T10:00:00Z"

    // MARK: Create

    @Test("createCaptureSession parses 201 body, sends POST with label + client_ts")
    func createHappyPath() async throws {
        let fake = FakeLakeloomAppClient()
        let responseBody = """
        {
          "id": "\(Self.captureID)",
          "project_id": "\(Self.projectID)",
          "state": "active",
          "label": "Kickoff call",
          "started_at": "\(Self.createdAt)"
        }
        """
        await fake.enqueueResponse(.success(Data(responseBody.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        let session = try await client.createCaptureSession(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: "Kickoff call",
            clientTimestamp: nil
        )

        #expect(session.id == Self.captureID)
        #expect(session.projectID == Self.projectID)
        #expect(session.state == .active)
        #expect(session.label == "Kickoff call")
        #expect(session.endedAt == nil)

        // Verify the request: POST /api/projects/<projectID>/captures
        let calls = await fake.requestCalls
        #expect(calls.count == 1)
        #expect(calls.first?.method == .post)
        #expect(calls.first?.path == "/api/projects/\(Self.projectID)/captures")
        // Body should include label
        let body = String(data: calls.first!.body!, encoding: .utf8)!
        #expect(body.contains("\"label\":\"Kickoff call\""))
        // No client_ts because we passed nil
        #expect(!body.contains("\"client_ts\""))
    }

    @Test("createCaptureSession omits label + sends client_ts when provided")
    func createWithClientTs() async throws {
        let fake = FakeLakeloomAppClient()
        let responseBody = """
        {"id":"x","project_id":"\(Self.projectID)","state":"active","label":null,"started_at":"\(Self.createdAt)"}
        """
        await fake.enqueueResponse(.success(Data(responseBody.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        let timestamp = Date(timeIntervalSince1970: 1_715_770_800)
        _ = try await client.createCaptureSession(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            label: nil,
            clientTimestamp: timestamp
        )

        let body = String(data: (await fake.requestCalls).first!.body!, encoding: .utf8)!
        #expect(body.contains("\"client_ts\""))
    }

    @Test("createCaptureSession surfaces 400 as validationFailed")
    func createValidationError() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(.httpError(status: 400, detail: "label too long")))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        do {
            _ = try await client.createCaptureSession(
                workspaceID: Self.workspaceID,
                projectID: Self.projectID,
                label: String(repeating: "x", count: 300),
                clientTimestamp: nil
            )
            Issue.record("expected validationFailed")
        } catch let error as CaptureAPIError {
            if case .validationFailed(let reason) = error {
                #expect(reason.contains("label too long"))
            } else {
                Issue.record("expected validationFailed, got \(error)")
            }
        }
    }

    // MARK: Update

    @Test("updateCaptureSession sends PATCH with state + ended_at, parses response")
    func updateHappyPath() async throws {
        let fake = FakeLakeloomAppClient()
        let responseBody = """
        {
          "id": "\(Self.captureID)",
          "project_id": "\(Self.projectID)",
          "state": "completed",
          "label": null,
          "started_at": "\(Self.createdAt)",
          "ended_at": "2026-05-15T11:00:00Z"
        }
        """
        await fake.enqueueResponse(.success(Data(responseBody.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        let endedAt = Date(timeIntervalSince1970: 1_715_774_400)
        let session = try await client.updateCaptureSession(
            workspaceID: Self.workspaceID,
            captureSessionID: Self.captureID,
            state: .completed,
            endedAt: endedAt
        )

        #expect(session.state == .completed)
        #expect(session.endedAt != nil)

        let call = await fake.requestCalls.first!
        #expect(call.method == .patch)
        #expect(call.path == "/api/captures/\(Self.captureID)")
        let body = String(data: call.body!, encoding: .utf8)!
        #expect(body.contains("\"state\":\"completed\""))
        #expect(body.contains("\"ended_at\""))
    }

    @Test("updateCaptureSession 409 → invalidTransition")
    func updateInvalidTransition() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(
            .failure(.httpError(status: 409, detail: "Capture is already cancelled"))
        )

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        do {
            _ = try await client.updateCaptureSession(
                workspaceID: Self.workspaceID,
                captureSessionID: Self.captureID,
                state: .completed,
                endedAt: nil
            )
            Issue.record("expected invalidTransition")
        } catch let error as CaptureAPIError {
            if case .invalidTransition = error {
                #expect(Bool(true))
            } else {
                Issue.record("expected invalidTransition, got \(error)")
            }
        }
    }
}

@Suite("LiveCaptureAPIClient — get / list")
struct LiveCaptureAPIClientGetListTests {

    private static let workspaceID = "fevm-hls-fde"
    private static let projectID = "proj-456"
    private static let captureID = "cap-xyz"

    @Test("getCaptureSession without uploads parses full payload")
    func getWithoutUploads() async throws {
        let fake = FakeLakeloomAppClient()
        let body = """
        {
          "id": "\(Self.captureID)",
          "project_id": "\(Self.projectID)",
          "state": "completed",
          "label": "Demo run",
          "started_at": "2026-05-15T10:00:00Z",
          "ended_at": "2026-05-15T10:45:00Z",
          "created_by_user_id": "u-123",
          "device_label": "iPhone 17 Pro"
        }
        """
        await fake.enqueueResponse(.success(Data(body.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        let session = try await client.getCaptureSession(
            workspaceID: Self.workspaceID,
            captureSessionID: Self.captureID,
            includeUploads: false
        )

        #expect(session.createdByUserID == "u-123")
        #expect(session.deviceLabel == "iPhone 17 Pro")
        #expect(session.uploads == nil)

        let call = await fake.requestCalls.first!
        #expect(call.method == .get)
        #expect(call.path == "/api/captures/\(Self.captureID)")
        #expect(!call.path.contains("include"))
    }

    @Test("getCaptureSession?include=uploads parses uploads array")
    func getWithUploads() async throws {
        let fake = FakeLakeloomAppClient()
        let body = """
        {
          "id": "\(Self.captureID)",
          "project_id": "\(Self.projectID)",
          "state": "completed",
          "label": null,
          "started_at": "2026-05-15T10:00:00Z",
          "uploads": [
            {
              "id": "up-1",
              "kind": "audio",
              "volume_path": "/Volumes/x/y/z.m4a",
              "mime_type": "audio/m4a",
              "size_bytes": 1048576,
              "sha256_hex": "abc123",
              "original_filename": "session.m4a",
              "client_ts": "2026-05-15T10:30:00Z",
              "uploaded_at": "2026-05-15T10:45:00Z"
            }
          ]
        }
        """
        await fake.enqueueResponse(.success(Data(body.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        let session = try await client.getCaptureSession(
            workspaceID: Self.workspaceID,
            captureSessionID: Self.captureID,
            includeUploads: true
        )

        #expect(session.uploads?.count == 1)
        #expect(session.uploads?.first?.kind == .audio)
        #expect(session.uploads?.first?.sizeBytes == 1_048_576)

        let call = await fake.requestCalls.first!
        #expect(call.path == "/api/captures/\(Self.captureID)?include=uploads")
    }

    @Test("getCaptureSession 404 → notFound")
    func getNotFound() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(.httpError(status: 404, detail: "not found")))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        do {
            _ = try await client.getCaptureSession(
                workspaceID: Self.workspaceID,
                captureSessionID: Self.captureID,
                includeUploads: false
            )
            Issue.record("expected notFound")
        } catch let error as CaptureAPIError {
            if case .notFound = error {
                #expect(Bool(true))
            } else {
                Issue.record("expected notFound, got \(error)")
            }
        }
    }

    // MARK: List

    @Test("listProjectCaptureSessions parses captures array, attaches state + limit + before query items")
    func listHappyPath() async throws {
        let fake = FakeLakeloomAppClient()
        let body = """
        {
          "captures": [
            {
              "id": "c-1",
              "project_id": "\(Self.projectID)",
              "state": "active",
              "label": null,
              "started_at": "2026-05-15T09:00:00Z"
            },
            {
              "id": "c-2",
              "project_id": "\(Self.projectID)",
              "state": "completed",
              "label": "Older",
              "started_at": "2026-05-14T09:00:00Z",
              "ended_at": "2026-05-14T10:00:00Z"
            }
          ]
        }
        """
        await fake.enqueueResponse(.success(Data(body.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        let captures = try await client.listProjectCaptureSessions(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            state: .active,
            limit: 25,
            before: Date(timeIntervalSince1970: 1_715_770_800)
        )

        #expect(captures.count == 2)
        #expect(captures.first?.id == "c-1")

        let call = await fake.requestCalls.first!
        #expect(call.method == .get)
        #expect(call.path.hasPrefix("/api/projects/\(Self.projectID)/captures?"))
        #expect(call.path.contains("limit=25"))
        #expect(call.path.contains("state=active"))
        #expect(call.path.contains("before="))
    }

    @Test("listProjectCaptureSessions clamps limit to [1, 200]")
    func listClampsLimit() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.success(Data(#"{"captures":[]}"#.utf8)))
        await fake.enqueueResponse(.success(Data(#"{"captures":[]}"#.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        _ = try await client.listProjectCaptureSessions(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            state: nil,
            limit: 0,  // should clamp up to 1
            before: nil
        )
        _ = try await client.listProjectCaptureSessions(
            workspaceID: Self.workspaceID,
            projectID: Self.projectID,
            state: nil,
            limit: 1_000,  // should clamp down to 200
            before: nil
        )
        let calls = await fake.requestCalls
        #expect(calls[0].path.contains("limit=1"))
        #expect(calls[1].path.contains("limit=200"))
    }

    @Test("auth failure (token_expired) maps to authFailed")
    func authFailureMaps() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.failure(
            .unauthorized(kind: .tokenExpired, detail: "session expired")
        ))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        do {
            _ = try await client.getCaptureSession(
                workspaceID: Self.workspaceID,
                captureSessionID: Self.captureID,
                includeUploads: false
            )
            Issue.record("expected authFailed")
        } catch let error as CaptureAPIError {
            if case .authFailed = error {
                #expect(Bool(true))
            } else {
                Issue.record("expected authFailed, got \(error)")
            }
        }
    }

    @Test("decode failure surfaces decodeFailed")
    func decodeFailure() async throws {
        let fake = FakeLakeloomAppClient()
        await fake.enqueueResponse(.success(Data(#"{"definitely":"not a capture"}"#.utf8)))

        let client = LiveCaptureAPIClient(lakeloomApp: fake)
        do {
            _ = try await client.getCaptureSession(
                workspaceID: Self.workspaceID,
                captureSessionID: Self.captureID,
                includeUploads: false
            )
            Issue.record("expected decodeFailed")
        } catch let error as CaptureAPIError {
            if case .decodeFailed = error {
                #expect(Bool(true))
            } else {
                Issue.record("expected decodeFailed, got \(error)")
            }
        }
    }
}
