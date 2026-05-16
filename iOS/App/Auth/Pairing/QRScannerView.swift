@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Camera-backed QR scanner. Wraps an `AVCaptureSession` configured
/// for QR metadata detection and surfaces the decoded string via
/// `onCodeScanned`.
///
/// The view handles its own camera permission flow:
///   - `.notDetermined` → in-flow request prompt
///   - `.denied` / `.restricted` → settings-deeplink CTA
///   - `.authorized` → live preview + scan
///
/// Tear-down is handled in `onDisappear` so the camera doesn't keep
/// running when the user navigates away.
public struct QRScannerView: View {

    public let prompt: String
    public let onCodeScanned: @MainActor (String) -> Void

    @State private var permission: PermissionState = .checking
    @State private var lastScanned: String?

    public init(
        prompt: String = "Point your camera at the QR code shown in the lakeLoom Databricks App.",
        onCodeScanned: @escaping @MainActor (String) -> Void
    ) {
        self.prompt = prompt
        self.onCodeScanned = onCodeScanned
    }

    public var body: some View {
        ZStack {
            switch permission {
            case .checking:
                ProgressView()
            case .denied, .restricted:
                PermissionDeniedView()
            case .authorized:
                CameraPreview(onCodeScanned: { code in
                    // Debounce repeated scans of the same code while
                    // the camera is still pointed at it.
                    if code != lastScanned {
                        lastScanned = code
                        onCodeScanned(code)
                    }
                })
                ScannerOverlay(prompt: prompt)
            }

            #if DEBUG
            // Simulators have no real camera, and even on a device
            // it's useful to bypass the QR optics during repro work
            // (paste the exact payload from the pair-event response).
            // The overlay layers on top of every permission state so
            // it works whether or not camera access has been granted.
            DebugPastePayloadOverlay { code in
                if code != lastScanned {
                    lastScanned = code
                    onCodeScanned(code)
                }
            }
            #endif
        }
        .task {
            await checkOrRequestPermission()
        }
    }

    @MainActor
    private func checkOrRequestPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .authorized : .denied
        case .denied:
            permission = .denied
        case .restricted:
            permission = .restricted
        @unknown default:
            permission = .denied
        }
    }

    private enum PermissionState: Equatable {
        case checking
        case authorized
        case denied
        case restricted
    }
}

// MARK: - Camera preview (AVFoundation bridge)

private struct CameraPreview: UIViewControllerRepresentable {
    let onCodeScanned: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> CameraPreviewController {
        let controller = CameraPreviewController()
        controller.onCodeScanned = onCodeScanned
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraPreviewController, context: Context) {}
}

private final class CameraPreviewController: UIViewController {

    var onCodeScanned: (@MainActor (String) -> Void)?
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var metadataDelegate: MetadataDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [captureSession] in
                captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        let delegate = MetadataDelegate { [weak self] code in
            self?.onCodeScanned?(code)
        }
        metadataDelegate = delegate

        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(delegate, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
    }
}

/// Lives outside `CameraPreviewController` so the delegate method can
/// satisfy `AVCaptureMetadataOutputObjectsDelegate`'s nonisolated
/// requirement without fighting `UIViewController`'s implicit
/// `@MainActor` isolation.
private final class MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {

    private let onCode: @MainActor (String) -> Void

    init(onCode: @escaping @MainActor (String) -> Void) {
        self.onCode = onCode
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let string = object.stringValue
        else { return }
        Task { @MainActor [onCode] in onCode(string) }
    }
}

// MARK: - UI chrome

private struct ScannerOverlay: View {
    let prompt: String

    var body: some View {
        VStack {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3))
                    .frame(width: 260, height: 260)
                    .shadow(color: .black.opacity(0.3), radius: 8)
            }
            Spacer()
            Text(prompt)
                .font(.callout)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding()
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
    }
}

private struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Camera access required")
                .font(.title3.bold())
            Text("lakeLoom needs camera access to scan the pairing QR code from the Databricks App.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .padding()
    }
}

#Preview {
    // Preview won't have camera access; falls through to the
    // permission-denied state, which is the only state safe to render
    // from a preview anyway.
    QRScannerView { code in
        print("scanned: \(code)")
    }
}

// MARK: - Debug paste affordance

#if DEBUG
/// Floats a small "Paste payload" button in the top-right of the
/// scanner. Tapping opens a sheet with a multiline text editor and a
/// "Use this" submit button that fires the same `onCodeScanned`
/// callback the camera path uses. Excluded from Release builds at
/// the compiler level via `#if DEBUG`.
private struct DebugPastePayloadOverlay: View {
    let onCodeScanned: @MainActor (String) -> Void

    @State private var showingSheet = false

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    showingSheet = true
                } label: {
                    Label("Paste payload", systemImage: "doc.on.clipboard")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
            }
            Spacer()
        }
        .sheet(isPresented: $showingSheet) {
            DebugPastePayloadSheet(
                onSubmit: { text in
                    showingSheet = false
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCodeScanned(trimmed)
                },
                onCancel: { showingSheet = false }
            )
        }
    }
}

private struct DebugPastePayloadSheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var payload: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste the pairing payload (the `data:application/json;base64,...` text the Databricks App returns when it generates a QR).")
                    .font(.callout)
                    .foregroundColor(.secondary)

                TextEditor(text: $payload)
                    .font(.system(.footnote, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 200)

                Button {
                    if let str = UIPasteboard.general.string {
                        payload = str
                    }
                } label: {
                    Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("DEBUG: Paste QR payload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this") {
                        onSubmit(payload)
                    }
                    .disabled(payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
