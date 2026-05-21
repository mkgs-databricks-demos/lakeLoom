import Foundation

/// Formats an elapsed `TimeInterval` as a wall-clock readout string.
///
/// Used by ``RecordingView``'s `TimelineView` to render the running
/// timer during a capture session. Pure function — no view state,
/// trivially unit-testable.
///
/// Format rules:
/// * Negative durations clamp to `0:00`.
/// * Sub-minute → `0:SS`.
/// * Under one hour → `M:SS` with no leading zero on minutes.
/// * One hour or more → `H:MM:SS`.
enum ElapsedTimer {

    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
