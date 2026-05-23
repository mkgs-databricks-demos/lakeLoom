import SwiftUI

/// Pill that renders a ``CaptureSession.State`` as a colored label.
/// Used in both the sessions list (one badge per row) and the
/// capture detail header.
///
/// Color mapping aligns with Genie's brand semantics:
/// * `.active`    → Lava (in-progress action)
/// * `.completed` → Green (success)
/// * `.cancelled` → Gray (neutral / dismissed)
struct CaptureStateBadge: View {
    let state: CaptureSession.State

    var body: some View {
        Text(label)
            .font(BrandTypography.captionMedium)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(foreground.opacity(0.25), lineWidth: 0.5)
            )
    }

    private var label: String {
        switch state {
        case .active:    return "Recording"
        case .completed: return "Saved"
        case .cancelled: return "Cancelled"
        }
    }

    private var foreground: Color {
        switch state {
        case .active:    return BrandColors.accentPrimary
        case .completed: return BrandColors.statusSuccess
        case .cancelled: return BrandColors.textSecondary
        }
    }

    private var background: Color {
        foreground.opacity(0.12)
    }
}
