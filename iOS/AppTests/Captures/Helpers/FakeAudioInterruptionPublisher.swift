import Foundation

@testable import LakeloomApp

/// Test seam for ``AudioInterruptionPublishing``. Lets a test push
/// `true`/`false` values into the stream that LiveCaptureService
/// subscribes to, so we can assert the broadcast-and-fan-out wiring
/// without standing up a real `AVAudioSession`.
public actor FakeAudioInterruptionPublisher: AudioInterruptionPublishing {

    private var continuation: AsyncStream<Bool>.Continuation?
    private var stream: AsyncStream<Bool>?

    public init() {
        let (s, c) = AsyncStream<Bool>.makeStream()
        self.stream = s
        self.continuation = c
    }

    public func interruptionUpdates() async -> AsyncStream<Bool>? {
        stream
    }

    /// Push the next value onto the stream. Called from tests to
    /// simulate an iOS-driven interruption start/end.
    public func yield(_ interrupted: Bool) {
        continuation?.yield(interrupted)
    }

    /// End the stream so a subscriber Task can drain to completion.
    public func finish() {
        continuation?.finish()
        continuation = nil
    }
}
