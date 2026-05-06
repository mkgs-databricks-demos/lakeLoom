import Testing

@testable import LakeloomApp

/// Smoke test that the test target compiles and the app module is importable.
/// Real per-module test suites land alongside their modules (Module 01 onward).
@Suite("Smoke")
struct SmokeTests {
    @Test("LakeloomApp module is reachable")
    func appModuleReachable() {
        // If the @testable import resolves and this test runs, the test target
        // and the app target are wired together correctly. The deliberate
        // shape of this test is "compile success is the assertion."
        #expect(Bool(true))
    }
}
