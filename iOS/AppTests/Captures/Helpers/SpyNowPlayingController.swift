import Foundation

@testable import LakeloomApp

/// Records every call to ``NowPlayingControlling`` so tests can
/// assert what LiveCaptureService asked the lock-screen controller
/// to do — without actually touching MPNowPlayingInfoCenter (a
/// process-wide singleton that's brittle to drive from tests).
@MainActor
public final class SpyNowPlayingController: NowPlayingControlling {

    public enum Call: Equatable, Sendable {
        case start(label: String?, startedAt: Date)
        case update(elapsedSeconds: TimeInterval)
        case setInterrupted(Bool)
        case stop
    }

    public private(set) var calls: [Call] = []
    public private(set) var lastOnStop: (@Sendable () -> Void)?

    public init() {}

    public func start(
        label: String?,
        startedAt: Date,
        onStop: @escaping @Sendable () -> Void
    ) {
        calls.append(.start(label: label, startedAt: startedAt))
        lastOnStop = onStop
    }

    public func update(elapsedSeconds: TimeInterval) {
        calls.append(.update(elapsedSeconds: elapsedSeconds))
    }

    public func setInterrupted(_ interrupted: Bool) {
        calls.append(.setInterrupted(interrupted))
    }

    public func stop() {
        calls.append(.stop)
        lastOnStop = nil
    }
}
