import Foundation
import Testing

@testable import LakeloomApp

@Suite("LogValue rendering")
struct LogValueRenderingTests {

    @Test("string and primitive scalars render directly")
    func scalarsRenderDirectly() {
        #expect(LogValue.string("hello").render() == "hello")
        #expect(LogValue.int(42).render() == "42")
        #expect(LogValue.bool(true).render() == "true")
        #expect(LogValue.bool(false).render() == "false")
    }

    @Test("redacted always renders as <<redacted: label>>")
    func redactedRenders() {
        #expect(LogValue.redacted(label: "token").render() == "<<redacted: token>>")
        #expect(LogValue.redacted(label: "workspace_url").render() == "<<redacted: workspace_url>>")
    }

    @Test("uuidPrefix takes the first 8 characters and adds an ellipsis when truncated")
    func uuidPrefixTruncation() {
        let full = "01975e4f-3a7c-7890-b1c2-d4e5f6a7b8c9"
        #expect(LogValue.uuidPrefix(full).render() == "01975e4f…")

        let short = "abcd"
        #expect(LogValue.uuidPrefix(short).render() == "abcd")
    }

    @Test("errorCode renders the case name unmodified")
    func errorCodeRenders() {
        #expect(LogValue.errorCode("refreshFailed").render() == "refreshFailed")
        #expect(LogValue.errorCode("http_503").render() == "http_503")
    }

    @Test("duration renders as `<seconds>.<nanos>s`")
    func durationRenders() {
        let zero = LogValue.duration(.zero)
        #expect(zero.render() == "0.000000000s")
        let oneSecond = LogValue.duration(.seconds(1))
        #expect(oneSecond.render().hasPrefix("1."))
    }
}

@Suite("LogValue Codable round-trip")
struct LogValueCodableTests {

    private func roundTrip(_ value: LogValue) throws -> LogValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(LogValue.self, from: data)
    }

    @Test("every variant survives encode → decode")
    func roundTripAllCases() throws {
        let cases: [LogValue] = [
            .string("safe"),
            .int(42),
            .double(3.14),
            .bool(true),
            .duration(.milliseconds(500)),
            .redacted(label: "token"),
            .uuidPrefix("01975e4f-3a7c"),
            .errorCode("refreshFailed")
        ]
        for value in cases {
            let result = try roundTrip(value)
            #expect(result == value)
        }
    }

    @Test("decode rejects unknown kind")
    func unknownKindRejected() throws {
        let json = """
        {"kind":"new_kind_we_dont_support","value":"x"}
        """.data(using: .utf8) ?? Data()
        do {
            _ = try JSONDecoder().decode(LogValue.self, from: json)
            Issue.record("expected decode failure for unknown kind")
        } catch is DecodingError {
            #expect(Bool(true))
        }
    }
}

@Suite("LogMetadata")
struct LogMetadataTests {

    @Test("dictionary literal preserves insertion order")
    func dictionaryLiteralOrder() {
        let m: LogMetadata = [
            "alpha": .int(1),
            "beta": .int(2),
            "gamma": .int(3)
        ]
        #expect(m.entries.map(\.key) == ["alpha", "beta", "gamma"])
    }

    @Test("renderInline produces stable key=value joined by spaces")
    func renderInline() {
        let m: LogMetadata = [
            "code": .string("ok"),
            "duration": .int(143),
            "token": .redacted(label: "token")
        ]
        #expect(m.renderInline() == "code=ok duration=143 token=<<redacted: token>>")
    }

    @Test("isEmpty is true for default-constructed metadata")
    func emptyMetadata() {
        let m = LogMetadata()
        #expect(m.isEmpty == true)
        let literal: LogMetadata = [:]
        #expect(literal.isEmpty == true)
    }
}
