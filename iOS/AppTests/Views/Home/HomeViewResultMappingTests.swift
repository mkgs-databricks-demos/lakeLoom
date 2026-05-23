import Foundation
import Testing

@testable import LakeloomApp

@Suite("HomeContainerView — CaptureServiceError → HomeViewResult")
@MainActor
struct HomeViewResultMappingTests {

    @Test("microphonePermissionDenied surfaces the typed banner")
    func micDenied() {
        let result = HomeContainerView.result(for: .microphonePermissionDenied)
        #expect(result == .microphonePermissionDenied)
    }

    @Test("createSessionNetworkUnavailable surfaces the offline banner")
    func networkUnavailable() {
        let result = HomeContainerView.result(for: .createSessionNetworkUnavailable)
        #expect(result == .networkUnavailable)
    }

    @Test("alreadyCapturing → generic failed banner")
    func alreadyCapturing() {
        let result = HomeContainerView.result(for: .alreadyCapturing)
        if case .failed(let reason) = result {
            #expect(reason.contains("already"))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    @Test("createSessionFailed (non-network) → generic failed banner with reason")
    func genericCreateFailure() {
        let result = HomeContainerView.result(for: .createSessionFailed(reason: "validation"))
        if case .failed(let reason) = result {
            #expect(reason.contains("Couldn't open"))
            #expect(reason.contains("validation"))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    @Test("recorderStartFailed (non-permission) → generic failed banner")
    func genericRecorderFailure() {
        let result = HomeContainerView.result(for: .recorderStartFailed(reason: "engineFailure"))
        if case .failed(let reason) = result {
            #expect(reason.contains("Couldn't start"))
            #expect(reason.contains("engineFailure"))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    @Test("recorderStopFailed → generic failed banner with stop-specific copy")
    func stopFailure() {
        let result = HomeContainerView.result(for: .recorderStopFailed(reason: "engineFailure"))
        if case .failed(let reason) = result {
            #expect(reason.contains("stop"))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }

    @Test("enqueueFailed → generic failed banner with upload-queue copy")
    func enqueueFailure() {
        let result = HomeContainerView.result(for: .enqueueFailed(reason: "fileNotFound"))
        if case .failed(let reason) = result {
            #expect(reason.contains("queue"))
        } else {
            Issue.record("expected .failed, got \(result)")
        }
    }
}
