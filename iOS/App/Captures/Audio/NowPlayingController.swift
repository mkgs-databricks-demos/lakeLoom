import Foundation
import MediaPlayer

/// Drives the lock-screen + Control Center "Now Playing" surface
/// while a capture is recording.
///
/// Why this exists: with `UIBackgroundModes = audio` declared, the
/// audio engine keeps running when the phone is locked or the user
/// swipes away to another app. Without a Now Playing entry, iOS shows
/// nothing on the lock screen and the user has no way to stop the
/// recording without unlocking. With it, they see "Recording — <label>"
/// with a live timer and a Stop button.
///
/// Why the protocol seam: `MPNowPlayingInfoCenter` /
/// `MPRemoteCommandCenter` are process-wide singletons, so the only
/// way to unit-test the wire-up is to abstract behind a protocol and
/// inject a spy. The protocol surface is intentionally tiny — every
/// call corresponds to a meaningful capture-lifecycle moment.
@MainActor
public protocol NowPlayingControlling: Sendable {

    /// Start displaying the Now Playing entry. `label` is the
    /// capture's user-supplied label (nil/empty → "Recording").
    /// `startedAt` anchors the elapsed-time timer. `onStop` fires
    /// when the user taps Stop from the lock screen / Control
    /// Center; the caller starts a Task and invokes
    /// `LiveCaptureService.stopCapture()`.
    func start(
        label: String?,
        startedAt: Date,
        onStop: @escaping @Sendable () -> Void
    )

    /// Update the elapsed-time display. The caller (LiveCaptureService)
    /// ticks this every second from a background Task so the
    /// lock-screen timer doesn't go stale.
    func update(elapsedSeconds: TimeInterval)

    /// Surface interruption state so the lock-screen UI reflects
    /// when the recorder is paused (e.g., phone call). `true` =
    /// paused, `false` = recording. Implementation flips
    /// `MPNowPlayingInfoPropertyPlaybackRate` between 0.0 and 1.0
    /// — that's what iOS uses to render the play/pause state on
    /// the lock-screen widget.
    func setInterrupted(_ interrupted: Bool)

    /// Tear down. Clears the Now Playing entry and the registered
    /// stop-handler. Idempotent so callers can invoke unconditionally
    /// from any capture-end path (stop, cancel, failed).
    func stop()
}

extension NowPlayingControlling {
    /// Convenience init for the production type. Keeps the call site
    /// in `LakeloomApp.swift` short and lets us swap in a spy in
    /// tests by passing `(any NowPlayingControlling)` directly.
    public static func live() -> any NowPlayingControlling {
        NowPlayingController()
    }
}

/// Production implementation backed by `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter`.
@MainActor
public final class NowPlayingController: NowPlayingControlling {

    private var onStopHandler: (@Sendable () -> Void)?
    private var stopCommandTarget: Any?
    private var sessionStartedAt: Date?

    public init() {}

    public func start(
        label: String?,
        startedAt: Date,
        onStop: @escaping @Sendable () -> Void
    ) {
        onStopHandler = onStop
        sessionStartedAt = startedAt

        let title: String
        if let label, !label.isEmpty {
            title = "Recording — \(label)"
        } else {
            title = "Recording"
        }

        // Minimal payload: title + elapsed time + playback rate.
        // Earlier versions of this code set `MPNowPlayingInfoPropertyIsLiveStream`,
        // `MPNowPlayingInfoPropertyMediaType`, and an `MPMediaItemArtwork`
        // built from `UIImage(systemName: "waveform")`. On a fresh
        // install we saw an EXC_BREAKPOINT trap inside MediaPlayer on
        // the Record-tap path — almost certainly an assertion when one
        // of those richer fields was inconsistent (live-stream + finite
        // elapsed time, or the SF-symbol-derived bounds). Strip back to
        // the keys Apple's own sample code uses; we can layer richness
        // back on once the basic surface is verified on device.
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "lakeLoom",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: 0.0),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: 1.0)
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        configureRemoteCommands()
    }

    public func update(elapsedSeconds: TimeInterval) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: elapsedSeconds)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func setInterrupted(_ interrupted: Bool) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: interrupted ? 0.0 : 1.0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    public func stop() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onStopHandler = nil
        sessionStartedAt = nil
        teardownRemoteCommands()
    }

    // MARK: - Remote command center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // The Stop command is what shows the (■) button on the
        // lock-screen Now Playing widget. Bind it to our injected
        // handler so a tap kicks LiveCaptureService.stopCapture().
        center.stopCommand.isEnabled = true
        // Drop any prior target so toggling start/stop/start during
        // one process doesn't end up with stacked handlers firing.
        if let prior = stopCommandTarget {
            center.stopCommand.removeTarget(prior)
        }
        stopCommandTarget = center.stopCommand.addTarget { [weak self] _ in
            self?.onStopHandler?()
            return .success
        }

        // Disable every other transport command so iOS doesn't
        // render irrelevant Skip / Seek controls. A recorder isn't a
        // music player; the only legal action is Stop.
        let disabled: [MPRemoteCommand] = [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.nextTrackCommand,
            center.previousTrackCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.changePlaybackPositionCommand,
            center.changePlaybackRateCommand,
            center.ratingCommand,
            center.likeCommand,
            center.dislikeCommand,
            center.bookmarkCommand
        ]
        for cmd in disabled {
            cmd.isEnabled = false
        }
    }

    private func teardownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        if let prior = stopCommandTarget {
            center.stopCommand.removeTarget(prior)
            stopCommandTarget = nil
        }
        center.stopCommand.isEnabled = false
    }
}
