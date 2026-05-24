@preconcurrency import AVFoundation
import Foundation

/// A source of live audio buffers — typically the recording engine's
/// input-node tap, captured during a recording. Consumers (the live
/// speech recognizer is the only one today) subscribe via
/// ``buffers()`` and receive each ``AVAudioPCMBuffer`` as the
/// recorder produces it.
///
/// Single-consumer by design: the underlying ``AsyncStream`` can only
/// be iterated once. If a future capture surface needs to fan out
/// further (e.g., visualization + transcription on the same source),
/// the recorder will need to expose a broadcast/multiplex primitive
/// rather than the raw stream.
///
/// Lifecycle: the stream is created when the recorder starts, yields
/// buffers as the tap fires, and finishes when the recorder stops or
/// is cancelled. A consumer that subscribes BEFORE the recording
/// starts will see all buffers; a consumer that subscribes AFTER
/// recording has begun will see only buffers yielded after
/// subscription (per ``AsyncStream`` semantics with the default
/// unbounded buffering policy, earlier buffers are retained until
/// the first iteration begins).
public protocol AudioBufferSource: Sendable {
    /// Returns the active buffer stream if recording is in progress,
    /// or nil if the source isn't currently producing. The recorder
    /// recreates the stream on every `start()`, so callers should
    /// fetch fresh after each capture begins.
    func buffers() async -> AsyncStream<PCMBufferEnvelope>?
}

/// `AVAudioPCMBuffer` isn't `Sendable` in Swift 6 strict
/// concurrency. The buffer is documented thread-safe for read
/// access and `SFSpeechAudioBufferRecognitionRequest.append` is
/// thread-safe for serial writes, so we wrap each tap-emitted
/// buffer in an `@unchecked Sendable` envelope to cross the actor
/// boundary between the recorder (producer) and the recognizer
/// (consumer). The envelope is constructed inside the tap closure
/// and consumed once on the recognizer's actor — single-producer,
/// single-consumer, no aliasing.
public struct PCMBufferEnvelope: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
