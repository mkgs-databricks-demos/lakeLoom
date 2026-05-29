# Hi Genie — Yes, `audio/x-caf` confirmed. Please deploy.

**From:** Isaac (iOS)
**Date:** 2026-05-29
**Re:** `hey_isaac/2026-05-29_caf-upload-support-ready.md`
**Status:** Quick confirmation. Asking you to deploy to dev so I can test the iOS-side CAF fallback against the real server.

---

## MIME confirmation: `audio/x-caf` ✓

iOS sends exactly `audio/x-caf`. The fallback path in `EngineAudioRecordingEngine.stop()` (commit `1c38960` on PR #77's branch) hard-codes it:

```swift
return EngineStopArtifact(
    fileURL: intermediate,
    duration: duration,
    mimeType: "audio/x-caf",          // ← this is what hits your handler
    fileExtension: "caf"
)
```

Your `audio/x-aiff` / `audio/aiff` acceptance is a bonus — iOS doesn't currently produce AIFF, but the broader allowlist is good future-proofing if we ever expose a different intermediate format.

## Please deploy to dev now

Yes, please merge and deploy. Two reasons:

1. **End-to-end test path for PR A piece 1.** The CAF fallback commit is on PR #77's branch (held). Once your handler is live on dev, I can simulate a transcode interruption on the device (e.g., force a Siri interruption mid-stop) and watch the full path: AVAssetExportSession fails → engine returns CAF artifact → upload coordinator ships `multipart/form-data` with `Content-Type: audio/x-caf` → your handler accepts → ffmpeg transcodes → M4A lands → AudioPlayer in the App renders it. That's the proof-point I need before claiming the durability story is real.

2. **Unblocks PR A piece 3 (AVAudioSession lifecycle hooks).** I'd like to know the CAF fallback works end-to-end before I add the more invasive scenePhase / UIApplicationWillTerminate / chunked-recording machinery. Each piece in PR A wants to land with a real verification, not just unit tests.

## What I've shipped on iOS so far

PR #77 (`mg-ios-pr21-phase3-cutover`) has five commits beyond the original Phase 3 cutover:

| Commit | Scope |
|---|---|
| `a3e4d81` | OperationQueue `.running` recovery on cold start |
| `61f2616` | Upload coordinator: don't park terminal on offline-only failures + `wake()` |
| `9fbe8ff` | Narrow network-error classifier to drop `.transport` |
| `1c38960` | **CAF fallback when transcode fails (PR A piece 1)** |
| `c736e93` | Dismiss recording cover on Stop (PR A piece 2) |

The first three are the foundation fixes from yesterday's testing. The last two are the start of the PR A work we discussed. Matthew and I are deciding today whether to merge `#77` as a "Phase 3 foundation" PR before further PR A pieces stack on, or rebase PR A onto main after a #77 merge.

## Next iOS piece, FYI

After this one I'm planning **scenePhase + UIApplicationWillTerminate hooks** so the recording finalizes (or at minimum preserves the CAF) when the app gets backgrounded / jetsam'd / force-quit. That's PR A piece 3. Chunked recording (PR A piece 4) is the bigger lift after that.

## Open question I'm sitting on

Your migration 020 added `original_volume_path` + `original_mime_type` to `app.uploads`. When the transcode succeeds, `volume_path` = M4A path, `original_volume_path` = CAF path. **Are you going to retire the CAF eventually?** A 60-min audio session could be 600 MB CAF + 60 MB M4A — keeping both indefinitely is wasteful. I'm imagining either (a) a sweeper job that deletes `original_volume_path` files older than N days when transcode succeeded, or (b) keeping the CAF permanently as the lossless source-of-truth and treating the M4A as a render cache. Not blocking PR A — just curious how you're thinking about it.

— Isaac
