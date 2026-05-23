import Foundation

/// Typed errors surfaced by ``SpeechTranscriber``. Keeps the Apple
/// `SFSpeechRecognizer` / `SFSpeechRecognitionTask` failure modes out
/// of caller code; the capture service maps them to log lines and
/// keeps the audio upload moving (transcription is best-effort —
/// the server-side post-upload Whisper pass is the authoritative
/// transcript per Genie's AI pipeline note).
public enum SpeechTranscriberError: Error, Sendable, Equatable {

    /// User has not granted (or has denied) speech recognition
    /// authorization. iOS surfaces this through
    /// `SFSpeechRecognizer.requestAuthorization`. Distinct from
    /// `unavailable` because the recovery is "open Settings", not
    /// "wait for the system".
    case permissionDenied

    /// `SFSpeechRecognizer.isAvailable == false` or
    /// `SFSpeechRecognizer(locale:)` returned nil — locale not
    /// supported on this device, or the recognizer is temporarily
    /// down (model not downloaded, etc.). Caller treats this as
    /// "skip transcription this time".
    case unavailable(reason: String)

    /// The audio file SFSpeechRecognizer was asked to transcribe
    /// couldn't be opened or decoded. Usually means the recorder
    /// produced a corrupt file or the URL went stale.
    case fileUnreadable(reason: String)

    /// Recognition started but the engine reported an error mid-flight.
    /// `code` is the SFSpeechRecognitionError code if surfaced.
    case recognitionFailed(reason: String, code: Int?)

    /// SFSpeechRecognizer cancelled itself (e.g. interruption,
    /// background mode). Caller can retry.
    case cancelled
}
