import SwiftUI

/// Onboarding step 2 — the camera-backed QR scanner. The user opens
/// the lakeLoom Databricks App's "Pair iPhone" page on a Mac browser
/// and aims this scanner at the QR. The decoded payload string flows
/// through `onScan` into ``AppCoordinator/submitQRCode(_:)``.
struct QRScanStepView: View {

    let inProgress: Bool
    let lastError: String?
    let onScan: (String) -> Void

    var body: some View {
        ZStack {
            QRScannerView(
                prompt: "Open the lakeLoom Databricks App on your Mac and scan the pairing QR.",
                onCodeScanned: { code in
                    // Debounce + guard against repeated scans while a
                    // sign-in is already in flight.
                    guard !inProgress else { return }
                    onScan(code)
                }
            )
            .ignoresSafeArea()

            if inProgress {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("Pairing…")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white)
                }
                .padding(24)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
            }

            if let error = lastError, !inProgress {
                VStack {
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 24)
                        .padding(.top, 60)
                    Spacer()
                }
            }
        }
    }
}

#Preview {
    QRScanStepView(
        inProgress: false,
        lastError: nil,
        onScan: { code in print("scanned: \(code)") }
    )
}
