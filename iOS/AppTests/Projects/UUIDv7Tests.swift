import Foundation
import Testing

@testable import LakeloomApp

@Suite("UUIDv7")
struct UUIDv7Tests {

    @Test("produces canonical 8-4-4-4-12 hex format")
    func canonicalFormat() {
        let id = UUIDv7.generate()
        let parts = id.split(separator: "-")
        #expect(parts.count == 5)
        #expect(parts[0].count == 8)
        #expect(parts[1].count == 4)
        #expect(parts[2].count == 4)
        #expect(parts[3].count == 4)
        #expect(parts[4].count == 12)
    }

    @Test("version nibble is 7")
    func versionIsSeven() {
        let id = UUIDv7.generate()
        // Version is the high nibble of the third group's first character.
        let third = id.split(separator: "-")[2]
        #expect(third.first == "7")
    }

    @Test("variant bits are 10xx (first char of 4th group is 8/9/a/b)")
    func variantBitsAreCorrect() {
        let id = UUIDv7.generate()
        let fourth = id.split(separator: "-")[3]
        let variantSet: Set<Character> = ["8", "9", "a", "b"]
        #expect(variantSet.contains(fourth.first ?? "?"))
    }

    @Test("two consecutive generations produce different ids")
    func twoGenerationsDiffer() {
        let a = UUIDv7.generate()
        let b = UUIDv7.generate()
        #expect(a != b)
    }

    @Test("ids generated later sort lexicographically after ids generated earlier")
    func timeOrderingIsLexicographic() {
        let early = UUIDv7.generate(now: Date(timeIntervalSince1970: 1_000_000))
        let later = UUIDv7.generate(now: Date(timeIntervalSince1970: 2_000_000))
        #expect(early < later)
    }
}
