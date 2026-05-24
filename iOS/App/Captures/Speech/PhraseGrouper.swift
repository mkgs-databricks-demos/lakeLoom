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
/// ``TranscriptSegment``s using pause-gap AND sentence-ending
/// punctuation detection.
///
/// `SFSpeechRecognizer` returns one segment per word — useful for
/// fine-grained alignment but a lot of noise to push into ZeroBus
/// one event at a time. Walking the word sequence and splitting on
/// either a sufficient pause OR a sentence-ending punctuation mark
/// (`.`, `!`, `?`) gives us natural sentence/breath boundaries.
/// Pauses catch breath stops; punctuation catches the cases where
/// the file-based recognizer normalized word timings tight (so
/// pauses don't appear) but the speech model identified sentence
/// boundaries.
///
/// Empty phrases (joined text trims to empty) are dropped from the
/// output entirely. PR 8f decision: when Apple's on-device
/// recognizer returns one empty-substring segment (quiet audio /
/// low VAD), we don't ship a bogus event to ZeroBus — better to
/// surface no transcript than a null/empty one.
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

    /// End-of-sentence punctuation that should trigger a phrase split
    /// (the word ending in one of these is the LAST word of its
    /// phrase; the next word starts a fresh phrase).
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// Roll `words` up into phrases. Words within a phrase are
    /// guaranteed to be in arrival order (we don't reorder), and
    /// the returned phrases are in start-time order. Empty phrases
    /// (joined text whitespace-only) are filtered out.
    public static func phrases(
        from words: [WordTiming],
        pauseThresholdSeconds: TimeInterval = defaultPauseThresholdSeconds
    ) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }

        var groups: [[WordTiming]] = []
        var current: [WordTiming] = [words[0]]
        var lastEnd = words[0].startTimeSeconds + words[0].durationSeconds
        var lastWordEndsSentence = endsSentence(words[0].text)

        for word in words.dropFirst() {
            let gap = word.startTimeSeconds - lastEnd
            let pauseSplit = gap >= pauseThresholdSeconds
            let punctuationSplit = lastWordEndsSentence
            if pauseSplit || punctuationSplit {
                groups.append(current)
                current = [word]
            } else {
                current.append(word)
            }
            lastEnd = max(lastEnd, word.startTimeSeconds + word.durationSeconds)
            lastWordEndsSentence = endsSentence(word.text)
        }
        groups.append(current)

        let segments = groups.enumerated().compactMap { (index, group) -> TranscriptSegment? in
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
            // Drop empty phrases — Apple sometimes returns a single
            // empty-substring segment on quiet/silent audio. Emitting
            // an event with text="" pollutes transcript_events_raw
            // with rows the server stores as NULL.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            return TranscriptSegment(
                text: text,
                confidence: confidence,
                segmentIndex: index,
                durationMs: max(0, Int((span * 1000.0).rounded())),
                startTimeSeconds: firstStart
            )
        }

        // Re-index after filtering so segmentIndex remains monotonic
        // 0, 1, 2, ... without gaps from dropped empty phrases.
        return segments.enumerated().map { newIndex, seg in
            TranscriptSegment(
                text: seg.text,
                confidence: seg.confidence,
                segmentIndex: newIndex,
                durationMs: seg.durationMs,
                startTimeSeconds: seg.startTimeSeconds
            )
        }
    }

    /// Does the word's text end with a sentence-ending punctuation
    /// mark? Apple inserts these when `addsPunctuation = true`, so
    /// they're the strongest signal we have for sentence boundaries
    /// when word timestamps are normalized tight (file-based path).
    private static func endsSentence(_ text: String) -> Bool {
        guard let lastChar = text.trimmingCharacters(in: .whitespaces).last else {
            return false
        }
        return sentenceTerminators.contains(lastChar)
    }
}
