import Foundation
import Testing

@testable import LakeloomApp

/// Unit tests for the pure-function helpers on
/// `EngineAudioRecordingEngine`. The actor itself drives real
/// `AVAudioEngine` + `AVAudioFile` and can't be unit-tested without
/// hardware; rotation is exercised end-to-end via the device test
/// plan (PR A piece 4 step 2 onward).
@Suite("EngineAudioRecordingEngine — per-chunk URL helpers")
struct EngineAudioRecordingEngineTests {

    private static let cafSeed = URL(fileURLWithPath: "/tmp/Captures/cap-1/audio-20260529T120000Z.caf")
    private static let m4aSeed = URL(fileURLWithPath: "/tmp/Captures/cap-1/audio-20260529T120000Z.m4a")

    @Test("single-chunk mode returns the seed URL unchanged for CAF")
    func cafSingleChunkPreservesSeed() {
        let url = EngineAudioRecordingEngine.chunkIntermediateURL(
            seed: Self.cafSeed,
            chunkIndex: 0,
            chunked: false
        )
        #expect(url == Self.cafSeed)
    }

    @Test("single-chunk mode returns the seed URL unchanged for M4A")
    func m4aSingleChunkPreservesSeed() {
        let url = EngineAudioRecordingEngine.chunkFinalURL(
            seed: Self.m4aSeed,
            chunkIndex: 0,
            chunked: false
        )
        #expect(url == Self.m4aSeed)
    }

    @Test("chunked mode appends -chunkN before the extension for CAF")
    func cafChunkedAppendsSuffix() {
        let url0 = EngineAudioRecordingEngine.chunkIntermediateURL(
            seed: Self.cafSeed,
            chunkIndex: 0,
            chunked: true
        )
        let url17 = EngineAudioRecordingEngine.chunkIntermediateURL(
            seed: Self.cafSeed,
            chunkIndex: 17,
            chunked: true
        )
        #expect(url0.lastPathComponent == "audio-20260529T120000Z-chunk0.caf")
        #expect(url17.lastPathComponent == "audio-20260529T120000Z-chunk17.caf")
        // Same parent directory as the seed.
        #expect(url0.deletingLastPathComponent() == Self.cafSeed.deletingLastPathComponent())
    }

    @Test("chunked mode appends -chunkN before the extension for M4A")
    func m4aChunkedAppendsSuffix() {
        let url = EngineAudioRecordingEngine.chunkFinalURL(
            seed: Self.m4aSeed,
            chunkIndex: 3,
            chunked: true
        )
        #expect(url.lastPathComponent == "audio-20260529T120000Z-chunk3.m4a")
        #expect(url.deletingLastPathComponent() == Self.m4aSeed.deletingLastPathComponent())
    }

    @Test("CAF + M4A per-chunk URLs share stem, differ only in extension")
    func cafAndM4APerChunkShareStem() {
        for index in 0..<5 {
            let caf = EngineAudioRecordingEngine.chunkIntermediateURL(
                seed: Self.cafSeed,
                chunkIndex: index,
                chunked: true
            )
            let m4a = EngineAudioRecordingEngine.chunkFinalURL(
                seed: Self.m4aSeed,
                chunkIndex: index,
                chunked: true
            )
            #expect(caf.deletingPathExtension().lastPathComponent
                    == m4a.deletingPathExtension().lastPathComponent)
            #expect(caf.pathExtension == "caf")
            #expect(m4a.pathExtension == "m4a")
        }
    }
}
