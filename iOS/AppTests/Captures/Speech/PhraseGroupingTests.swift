import Foundation
import Testing

@testable import LakeloomApp

@Suite("PhraseGrouper")
struct PhraseGroupingTests {

    private static func word(
        _ text: String,
        start: TimeInterval,
        duration: TimeInterval = 0.3,
        confidence: Float = 0.9
    ) -> WordTiming {
        WordTiming(
            text: text,
            startTimeSeconds: start,
            durationSeconds: duration,
            confidence: confidence
        )
    }

    // MARK: - Basic shape

    @Test("empty input → empty output")
    func emptyInput() {
        #expect(PhraseGrouper.phrases(from: []).isEmpty)
    }

    @Test("single word → single phrase containing that word")
    func singleWord() {
        let words = [Self.word("hello", start: 0.0, duration: 0.4)]
        let phrases = PhraseGrouper.phrases(from: words)
        #expect(phrases.count == 1)
        #expect(phrases[0].text == "hello")
        #expect(phrases[0].segmentIndex == 0)
        #expect(phrases[0].startTimeSeconds == 0.0)
        #expect(phrases[0].durationMs == 400)
    }

    // MARK: - Grouping behavior

    @Test("consecutive words under the pause threshold → single phrase")
    func tightCadenceGroups() {
        // "hello how are you" — each word 0.3s long, 0.1s gaps.
        let words = [
            Self.word("hello", start: 0.0),
            Self.word("how",   start: 0.4),
            Self.word("are",   start: 0.8),
            Self.word("you",   start: 1.2)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.count == 1)
        #expect(phrases[0].text == "hello how are you")
        #expect(phrases[0].startTimeSeconds == 0.0)
        // Last word ends at 1.2 + 0.3 = 1.5 → 1500ms span
        #expect(phrases[0].durationMs == 1500)
    }

    @Test("gap >= threshold splits the phrase boundary")
    func pauseSplitsPhrases() {
        // Two phrases separated by a 1.8s pause:
        // "hello how"    [0.0, 0.7]
        // "general kenobi" [2.5, 3.4]
        let words = [
            Self.word("hello",   start: 0.0),  // ends 0.3
            Self.word("how",     start: 0.4),  // ends 0.7
            Self.word("general", start: 2.5),  // ends 2.8 — gap from 0.7 = 1.8s
            Self.word("kenobi",  start: 3.1)   // ends 3.4
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.count == 2)
        #expect(phrases[0].text == "hello how")
        #expect(phrases[0].segmentIndex == 0)
        #expect(phrases[1].text == "general kenobi")
        #expect(phrases[1].segmentIndex == 1)
        #expect(phrases[1].startTimeSeconds == 2.5)
    }

    @Test("gap exactly at threshold splits (>= comparison)")
    func gapAtThresholdSplits() {
        // First word ends at 0.3; second word starts at 1.0 → exactly 0.7s gap
        let words = [
            Self.word("first",  start: 0.0, duration: 0.3),
            Self.word("second", start: 1.0, duration: 0.3)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.count == 2)
    }

    @Test("gap just under threshold groups together")
    func gapJustUnderThresholdGroups() {
        // gap = 0.69s → under 0.7s threshold
        let words = [
            Self.word("first",  start: 0.0, duration: 0.3),
            Self.word("second", start: 0.99, duration: 0.3)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.count == 1)
    }

    @Test("three phrases via two gaps")
    func multipleGapsProduceMultiplePhrases() {
        let words = [
            Self.word("a", start: 0.0),
            Self.word("b", start: 0.4),
            Self.word("c", start: 2.0),     // gap from prev end (0.7) = 1.3s
            Self.word("d", start: 4.0),     // gap from prev end (2.3) = 1.7s
            Self.word("e", start: 4.4)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.count == 3)
        #expect(phrases.map(\.text) == ["a b", "c", "d e"])
        #expect(phrases.map(\.segmentIndex) == [0, 1, 2])
    }

    // MARK: - Confidence aggregation

    @Test("confidence is the mean of non-zero word confidences")
    func confidenceMean() {
        let words = [
            Self.word("a", start: 0.0, confidence: 0.8),
            Self.word("b", start: 0.4, confidence: 0.9),
            Self.word("c", start: 0.8, confidence: 1.0)
        ]
        let phrases = PhraseGrouper.phrases(from: words)
        #expect(phrases.count == 1)
        let conf = try? #require(phrases.first?.confidence)
        // Mean of 0.8 / 0.9 / 1.0 = 0.9
        #expect(conf.map { abs($0 - 0.9) < 0.0001 } == true)
    }

    @Test("zero-confidence words are excluded from the mean")
    func zeroConfidenceExcluded() {
        let words = [
            Self.word("a", start: 0.0, confidence: 0.8),
            Self.word("b", start: 0.4, confidence: 0.0),
            Self.word("c", start: 0.8, confidence: 1.0)
        ]
        let phrases = PhraseGrouper.phrases(from: words)
        let conf = try? #require(phrases.first?.confidence)
        // Mean of 0.8 and 1.0 = 0.9 (ignoring the 0.0)
        #expect(conf.map { abs($0 - 0.9) < 0.0001 } == true)
    }

    @Test("all-zero confidences → nil phrase confidence")
    func allZeroConfidenceIsNil() {
        let words = [
            Self.word("a", start: 0.0, confidence: 0.0),
            Self.word("b", start: 0.4, confidence: 0.0)
        ]
        let phrases = PhraseGrouper.phrases(from: words)
        #expect(phrases.first?.confidence == nil)
    }

    // MARK: - Spans

    @Test("phrase duration is the span from first start to last end")
    func phraseDurationIsSpan() {
        let words = [
            Self.word("a", start: 1.0, duration: 0.5),  // 1.0 → 1.5
            Self.word("b", start: 2.0, duration: 0.5)   // 2.0 → 2.5
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.count == 1)
        // Span 1.0 → 2.5 = 1500ms
        #expect(phrases[0].durationMs == 1500)
        #expect(phrases[0].startTimeSeconds == 1.0)
    }

    // MARK: - PR 8f: empty-phrase filter

    @Test("a single empty-text word produces zero phrases — not one bogus event")
    func emptyTextWordIsDropped() {
        let words = [
            Self.word("", start: 0.0, duration: 0.0, confidence: 0.0)
        ]
        let phrases = PhraseGrouper.phrases(from: words)
        #expect(phrases.isEmpty)
    }

    @Test("a phrase that joins to all-whitespace is dropped")
    func whitespaceOnlyPhraseIsDropped() {
        let words = [
            Self.word("   ", start: 0.0, duration: 0.1),
            Self.word("\t", start: 0.2, duration: 0.1)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.isEmpty)
    }

    @Test("mixed empty + real phrases drop the empty one and re-index the rest from 0")
    func emptyPhraseDroppedAndReindexed() {
        let words = [
            Self.word("hello",  start: 0.0),
            // 2s gap → next phrase
            Self.word("",       start: 2.0, duration: 0.0, confidence: 0.0),
            // 2s gap → next phrase
            Self.word("world",  start: 4.0)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 0.7)
        #expect(phrases.count == 2)
        // Middle empty phrase is dropped; remaining phrases re-indexed 0, 1.
        #expect(phrases.map(\.text) == ["hello", "world"])
        #expect(phrases.map(\.segmentIndex) == [0, 1])
    }

    // MARK: - PR 8f: punctuation-based split

    @Test("sentence-ending period splits the phrase even with no pause gap")
    func periodSplitsTightlyTimedPhrases() {
        // Tight cadence (~0.1s gaps) but Apple inserted a period
        // at the end of the first sentence — should split.
        let words = [
            Self.word("hello.", start: 0.0, duration: 0.3),
            Self.word("how",    start: 0.4, duration: 0.2),
            Self.word("are",    start: 0.7, duration: 0.2),
            Self.word("you?",   start: 1.0, duration: 0.3)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 5.0)
        #expect(phrases.count == 2)
        #expect(phrases.map(\.text) == ["hello.", "how are you?"])
    }

    @Test("question mark + exclamation also trigger phrase boundaries")
    func questionAndExclamationSplit() {
        let words = [
            Self.word("hi!",    start: 0.0, duration: 0.2),
            Self.word("really?", start: 0.3, duration: 0.4),
            Self.word("yes",    start: 0.8, duration: 0.3)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 5.0)
        #expect(phrases.count == 3)
        #expect(phrases.map(\.text) == ["hi!", "really?", "yes"])
    }

    @Test("comma does NOT trigger a phrase boundary — too soft a signal")
    func commaDoesNotSplit() {
        let words = [
            Self.word("first,", start: 0.0, duration: 0.3),
            Self.word("then",   start: 0.4, duration: 0.3),
            Self.word("done.",  start: 0.8, duration: 0.4)
        ]
        let phrases = PhraseGrouper.phrases(from: words, pauseThresholdSeconds: 5.0)
        // "first, then done." is one phrase (the period at the end
        // doesn't split because there are no following words).
        #expect(phrases.count == 1)
        #expect(phrases[0].text == "first, then done.")
    }
}
