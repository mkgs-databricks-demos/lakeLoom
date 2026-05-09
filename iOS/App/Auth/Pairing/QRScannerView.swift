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
