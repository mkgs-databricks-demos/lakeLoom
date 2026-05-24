import Foundation

/// One recognized word with its timing + confidence — the minimum
/// data needed to roll words up into phrase-level ``TranscriptSegment``s.
/// Mirrors what we extract from Apple's `SFTranscriptionSegment` but
/// is a plain value type so tests can construct synthetic input
/// without touching the Speech framework.
public struct WordTiming: Sendable, Equatable {
    public let text: String
    public let startTimeSeconds: TimeInterval
    public let durationSeconds: TimeInterval
    /// 0 when the recognizer didn't surface a confidence (treated as
    /// "unknown" by the grouper — included in the mean only when
    /// non-zero).
    public let confidence: Float

    public init(
        text: String,
        startTimeSeconds: TimeInterval,
        durationSeconds: TimeInterval,
        confidence: Float
    ) {
        self.text = text
        self.startTimeSeconds = startTimeSeconds
        self.durationSeconds = durationSeconds
        self.confidence = confidence
    }
}

/// Groups a flat sequence of recognized words into phrase-level
/// ``TranscriptSegment``s using pause-gap detection.
///
/// `SFSpeechRecognizer` returns one segment per word — useful for
/// fine-grained alignment but a lot of noise to push into ZeroBus
/// one event at a time. Walking the word sequence and splitting on
/// any gap larger than `pauseThreshold` gives us natural sentence /
/// breath boundaries that match how a human would read the
/// transcript.
///
/// Per-phrase output:
/// * `text` — words joined with a single space (Apple already
///   handles inline punctuation when `addsPunctuation = true`).
/// * `segmentIndex` — phrase index (0, 1, 2, …), NOT word index.
/// * `startTimeSeconds` — first word's start.
/// * `durationMs` — span from first word's start to last word's end.
/// * `confidence` — mean of non-zero word confidences in the
///   phrase, or nil if every word reported 0.
public enum PhraseGrouper {

    /// Default gap (seconds) that splits one phrase from the next.
    /// 0.7s is comfortably above the cadence of fluent conversation
    /// while still catching the natural pauses at sentence /
    /// breath boundaries. Tunable per-recognizer if needed.
    public static let defaultPauseThresholdSeconds: TimeInterval = 0.7

    /// Roll `words` up into phrases. Words within a phrase are
    /// guaranteed to be in arrival order (we don't reorder), and
    /// the returned phrases are in start-time order.
    public static func phrases(
        from words: [WordTiming],
        pauseThresholdSeconds: TimeInterval = defaultPauseThresholdSeconds
    ) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }

        var groups: [[WordTiming]] = []
        var current: [WordTiming] = [words[0]]
        var lastEnd = words[0].startTimeSeconds + words[0].durationSeconds

        for word in words.dropFirst() {
            let gap = word.startTimeSeconds - lastEnd
            if gap >= pauseThresholdSeconds {
                groups.append(current)
                current = [word]
            } else {
                current.append(word)
            }
            lastEnd = max(lastEnd, word.startTimeSeconds + word.durationSeconds)
        }
        groups.append(current)

        return groups.enumerated().map { index, group in
            let firstStart = group.first!.startTimeSeconds
            let lastEndTime = group.map { $0.startTimeSeconds + $0.durationSeconds }.max() ?? firstStart
            let span = lastEndTime - firstStart

            let nonZero = group.map(\.confidence).filter { $0 > 0 }
            let confidence: Double?
            if nonZero.isEmpty {
                confidence = nil
            } else {
                let sum = nonZero.reduce(Float(0), +)
                confidence = Double(sum) / Double(nonZero.count)
            }

            let text = group
                .map(\.text)
                .joined(separator: " ")

            return TranscriptSegment(
                text: text,
                confidence: confidence,
                segmentIndex: index,
                durationMs: max(0, Int((span * 1000.0).rounded())),
                startTimeSeconds: firstStart
            )
        }
    }
}
