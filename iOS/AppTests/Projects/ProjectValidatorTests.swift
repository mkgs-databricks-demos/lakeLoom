import Foundation
import Testing

@testable import LakeloomApp

@Suite("ProjectValidator.validateName")
struct ProjectValidatorNameTests {

    @Test("trims whitespace")
    func trimsWhitespace() throws {
        let result = try ProjectValidator.validateName("  Customer 360  ")
        #expect(result == "Customer 360")
    }

    @Test("rejects empty string")
    func rejectsEmpty() {
        do {
            _ = try ProjectValidator.validateName("")
            Issue.record("expected validationFailed")
        } catch ProjectError.validationFailed {
            #expect(Bool(true))
        } catch {
            Issue.record("expected ProjectError.validationFailed, got \(error)")
        }
    }

    @Test("rejects whitespace-only string")
    func rejectsWhitespaceOnly() {
        do {
            _ = try ProjectValidator.validateName("   \n\t  ")
            Issue.record("expected validationFailed")
        } catch ProjectError.validationFailed {
            #expect(Bool(true))
        } catch {
            Issue.record("expected ProjectError.validationFailed, got \(error)")
        }
    }

    @Test("rejects names over 200 characters")
    func rejectsOversizeName() {
        let longName = String(repeating: "a", count: 201)
        do {
            _ = try ProjectValidator.validateName(longName)
            Issue.record("expected validationFailed")
        } catch ProjectError.validationFailed {
            #expect(Bool(true))
        } catch {
            Issue.record("got \(error)")
        }
    }

    @Test("accepts allowed special characters")
    func acceptsAllowedChars() throws {
        let result = try ProjectValidator.validateName("Customer 360 / ACME (prod) - v1_2024.q3 & beyond")
        #expect(!result.isEmpty)
    }

    @Test("rejects newlines and tabs in the middle")
    func rejectsControlChars() {
        do {
            _ = try ProjectValidator.validateName("foo\nbar")
            Issue.record("expected validationFailed for embedded newline")
        } catch ProjectError.validationFailed {
            #expect(Bool(true))
        } catch {
            Issue.record("got \(error)")
        }
    }
}

@Suite("ProjectValidator.validateDescription")
struct ProjectValidatorDescriptionTests {

    @Test("nil and empty become nil")
    func nilAndEmptyReturnNil() throws {
        #expect(try ProjectValidator.validateDescription(nil) == nil)
        #expect(try ProjectValidator.validateDescription("") == nil)
        #expect(try ProjectValidator.validateDescription("   ") == nil)
    }

    @Test("trims whitespace and preserves content")
    func trimsContent() throws {
        let result = try ProjectValidator.validateDescription("  hello world  ")
        #expect(result == "hello world")
    }

    @Test("rejects descriptions over 2000 characters")
    func rejectsOversizeDescription() {
        let long = String(repeating: "x", count: 2_001)
        do {
            _ = try ProjectValidator.validateDescription(long)
            Issue.record("expected validationFailed")
        } catch ProjectError.validationFailed {
            #expect(Bool(true))
        } catch {
            Issue.record("got \(error)")
        }
    }
}
