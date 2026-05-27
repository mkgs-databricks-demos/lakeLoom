import Foundation

/// Sideband publisher that surfaces `AVAudioSession` interruptions
/// from the audio engine up to the capture flow.
///
/// Same pattern as ``AudioBufferSource`` (PR 9b): the engine is the
/// thing that owns the `AVAudioSession` notification observers, so
/// it's also the thing that knows when an interruption begins / ends.
/// LiveCaptureService subscribes after `startCapture` returns so it
/// can broadcast a `recording_paused` flag onto its own state stream
/// for the UI.
///
/// `nil` from `interruptionUpdates()` means "no active recording right
/// now — nothing to subscribe to," exactly mirroring
/// `AudioBufferSource.buffers()`. Callers should treat it as a no-op.
public protocol AudioInterruptionPublishing: Sendable {

    /// Returns a stream that yields `true` on interruption start
    /// (engine paused) and `false` on interruption end (engine
    /// resumed, or remains paused if iOS withheld
    /// `.shouldResume`). The stream finishes when the recording
    /// stops or is cancelled. Returns nil when no recording is
    /// active.
    func interruptionUpdates() async -> AsyncStream<Bool>?
}
