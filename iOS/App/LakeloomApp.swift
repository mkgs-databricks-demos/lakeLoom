import SwiftUI

@main
struct LakeloomApp: App {

    @State private var coordinator: AppCoordinator

    init() {
        // Construct the live dependency graph at app start. CoreDataStack
        // initialization is async but the coordinator's bootstrap() runs
        // it on first launch — failures route through phase = .error.
        let coreDataStack: any CoreDataStacking
        do {
            coreDataStack = try CoreDataStack()
        } catch {
            // Falling back to in-memory keeps the app launchable even on
            // a broken filesystem; the coordinator will surface the
            // initialize() failure through its error phase if it
            // happens later.
            // swiftlint:disable:next force_try
            coreDataStack = try! CoreDataStack(inMemory: true)
        }

        let deviceKeyStore = LiveDeviceKeyStore()
        let m2mTokenClient = LiveM2MTokenClient()
        let requestSigner = RequestSigner(keyStore: deviceKeyStore)
        let lakeloomApp = LiveLakeloomAppClient(
            m2mTokenClient: m2mTokenClient,
            requestSigner: requestSigner
        )
        let auth = AuthService(
            lakeloomApp: lakeloomApp,
            deviceKeyStore: deviceKeyStore,
            keychain: LiveKeychainStore()
        )
        let endpointResolver = LiveAppEndpointResolver()
        let projects = ProjectService(
            auth: auth,
            endpointResolver: endpointResolver
        )
        let captureAPI = LiveCaptureAPIClient(lakeloomApp: lakeloomApp)

        // Upload pipeline. Worker loop is started from the App's
        // `.task` modifier below so the queue rehydration happens on
        // every cold launch, not only when bootstrap() runs.
        let uploadCoordinator: (any UploadCoordinator)?
        do {
            let queueStore = try UploadQueueStore.makeDefault()
            uploadCoordinator = LiveUploadCoordinator(
                lakeloomApp: lakeloomApp,
                queueStore: queueStore
            )
        } catch {
            // Persistence init failure shouldn't block the app —
            // capture features just won't be available until the
            // filesystem is healthy enough to host the queue file.
            uploadCoordinator = nil
        }

        let photoCapture = LivePhotoCapture()

        _coordinator = State(
            wrappedValue: AppCoordinator(
                auth: auth,
                projects: projects,
                coreDataStack: coreDataStack,
                endpointResolver: endpointResolver,
                captureAPI: captureAPI,
                uploadCoordinator: uploadCoordinator,
                photoCapture: photoCapture
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .task {
                    await coordinator.bootstrap()
                    if let uploads = coordinator.uploadCoordinator {
                        await uploads.start()
                    }
                }
        }
    }
}

/// App-level configuration baked at build time.
///
/// Most auth-related config is no longer needed here — Xcode SPN
/// credentials, workspace URL, and App base URL all arrive via the
/// QR payload at pairing time, not from build config.
enum AppConfig {
}
