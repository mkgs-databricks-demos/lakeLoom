import SwiftUI

@main
struct LakeloomApp: App {

    @State private var coordinator: AppCoordinator

    init() {
        // Register DM Sans + DM Mono with the per-process font
        // manager before any SwiftUI view that uses
        // `Font.custom(...)` renders. Done here (synchronously, on
        // the main thread) so the first frame already has the
        // brand faces available — otherwise SwiftUI caches a
        // fallback resolution for the first few labels.
        BrandFontRegistration.registerAll()

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
        let deviceIdentity = LiveDeviceIdentityStore()
        let auth = AuthService(
            lakeloomApp: lakeloomApp,
            deviceKeyStore: deviceKeyStore,
            keychain: LiveKeychainStore(),
            deviceIdentity: deviceIdentity
        )
        let endpointResolver = LiveAppEndpointResolver()
        // PR 9b: route ProjectService through LakeloomAppClient so
        // `/api/v1/projects*` calls carry the Layer 2 headers the
        // server's `dualAuth` middleware now requires. Without this,
        // bare-SPN requests get 401 — see
        // `architecture/hey_isaac/2026-05-24_ios-layer2-on-project-endpoints.md`.
        let projectAPI = LiveProjectAPIClient(lakeloomApp: lakeloomApp)
        // PR #16 Phase 1: disk-persistent project list so a cold
        // launch without network still renders the user's last-seen
        // projects. Construction can throw on a broken filesystem;
        // fall back to nil so the rest of the wiring still proceeds
        // (the service degrades to in-memory-cache-only, which is
        // the pre-PR behavior).
        let projectListStore = try? ProjectListStore.makeDefault()
        let projects = ProjectService(
            auth: auth,
            endpointResolver: endpointResolver,
            api: projectAPI,
            listStore: projectListStore
        )
        let captureAPI = LiveCaptureAPIClient(lakeloomApp: lakeloomApp)
        let transcriptEvents = LiveTranscriptEventsClient(lakeloomApp: lakeloomApp)
        let speechTranscriber = LiveSpeechTranscriber()
        let transcriptStreamer = LiveTranscriptStreamer(events: transcriptEvents)
        // PR 9b: share one EngineAudioRecordingEngine instance —
        // LiveAudioRecorder uses it as the recording backend, AND
        // LiveCaptureService subscribes to its live PCM buffer
        // stream for the streaming speech recognizer. Single mic
        // owner, two consumers (file writer + recognizer) feeding
        // off the same input tap.
        let engineRecordingEngine = EngineAudioRecordingEngine()
        let streamingRecognizer = LiveStreamingSpeechRecognizer()

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
        let mediaContent = LiveMediaContentService(lakeloomApp: lakeloomApp)

        // PR #16 Phase 1: reachability monitor for the offline
        // banner. Started immediately so the first frame already
        // has an accurate state — NWPathMonitor delivers its first
        // callback within a few ms, but we don't want any UI
        // flicker during the boot window.
        let reachability = ReachabilityMonitor()
        reachability.start()

        // PR 21 (Phase 3 cutover): control-plane outbox. Holds queued
        // capture-create + state-PATCH ops while the device is
        // offline; drains them in FIFO order when the queue's worker
        // sees a reachable network. Same store-as-the-source-of-truth
        // pattern as the upload coordinator. Construction can throw
        // on filesystem failure — fall through to nil so the rest of
        // the wiring proceeds (LiveCaptureService falls back to its
        // legacy direct-call path).
        let operationQueueStore: OperationQueueStore? = try? OperationQueueStore.makeDefault()
        let operationQueue: (any OperationQueueing)?
        if let operationQueueStore {
            let executor = OperationExecutor.make(
                captureAPI: captureAPI,
                projects: projects
            )
            operationQueue = LiveOperationQueue(
                queueStore: operationQueueStore,
                execute: executor
            )
        } else {
            operationQueue = nil
        }

        // Capture orchestrator. Bundles captureAPI + a shared
        // AudioRecorder + the upload coordinator + the
        // capture-context store so app-killed-mid-capture
        // recoveries happen automatically on next launch.
        let captureService: (any CaptureService)?
        if let uploadCoordinator {
            let contextStore: CaptureContextStore?
            do { contextStore = try CaptureContextStore.makeDefault() }
            catch { contextStore = nil }
            // Closure that the capture service awaits when it's
            // about to emit transcript events. We can't snapshot the
            // paired_session_id at app-launch time — the user may
            // not be paired yet — so the service polls when it's
            // ready to send. Sendable closure captures `auth` by
            // reference; AuthServicing is Sendable.
            let pairedSessionIDProvider: @Sendable () async -> String? = { [auth] in
                await auth.activeWorkspace?.authMethod.pairedSessionID
            }
            // PR 19: same engine instance also publishes interruption
            // events. NowPlayingController owns the lock-screen +
            // Control Center surface; it's @MainActor so the actor
            // can hop into it via `await`.
            let nowPlayingController = NowPlayingController()
            captureService = LiveCaptureService(
                captureAPI: captureAPI,
                recorder: LiveAudioRecorder(engine: engineRecordingEngine),
                uploadCoordinator: uploadCoordinator,
                contextStore: contextStore,
                deviceIdentity: deviceIdentity,
                speechTranscriber: speechTranscriber,
                transcriptStreamer: transcriptStreamer,
                streamingRecognizer: streamingRecognizer,
                audioBufferSource: engineRecordingEngine,
                interruptionPublisher: engineRecordingEngine,
                nowPlaying: nowPlayingController,
                operationQueue: operationQueue,
                photoCapture: photoCapture,
                pairedSessionIDProvider: pairedSessionIDProvider
            )
        } else {
            // Without an upload coordinator the capture flow has
            // nothing to drain into; surface nil so the UI hides
            // capture affordances rather than half-instantiating.
            captureService = nil
        }

        _coordinator = State(
            wrappedValue: AppCoordinator(
                auth: auth,
                projects: projects,
                coreDataStack: coreDataStack,
                endpointResolver: endpointResolver,
                captureAPI: captureAPI,
                uploadCoordinator: uploadCoordinator,
                photoCapture: photoCapture,
                captureService: captureService,
                transcriptEvents: transcriptEvents,
                deviceIdentity: deviceIdentity,
                mediaContent: mediaContent,
                reachability: reachability,
                operationQueue: operationQueue
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .task {
                    await coordinator.bootstrap()
                    // captureService.start() rehydrates the upload
                    // queue (via uploadCoordinator.start()) AND
                    // reconciles the persisted capture context, so
                    // a single call covers both recovery paths.
                    if let captureService = coordinator.captureService {
                        await captureService.start()
                    } else if let uploads = coordinator.uploadCoordinator {
                        // Belt-and-suspenders: if the captureService
                        // wasn't wired (e.g., uploadCoordinator init
                        // failed earlier and we left captureService
                        // nil), still kick the upload coordinator
                        // directly so any queued uploads from a
                        // previous run can drain.
                        await uploads.start()
                    }
                    // PR 21 (Phase 3): start the control-plane outbox
                    // so any ops queued from a prior launch (or that
                    // accumulated while the user was offline) drain
                    // immediately on cold start.
                    if let operationQueue = coordinator.operationQueue {
                        await operationQueue.start()
                    }
                }
                .task {
                    // PR 21 (Phase 3): nudge the operation queue AND
                    // the upload coordinator whenever the device
                    // transitions back online so a backlog of
                    // capture-create / state-PATCH ops + data-plane
                    // multipart uploads drains right away instead of
                    // waiting out the current backoff window.
                    // Without the uploadCoordinator wake, an offline
                    // session longer than `sum(backoff)` seconds would
                    // park audio uploads terminal-failed permanent
                    // before reachability returned — see the network-
                    // error handling in `LiveUploadCoordinator.handleFailure`.
                    guard let reachability = coordinator.reachability else { return }
                    let operationQueue = coordinator.operationQueue
                    let uploadCoordinator = coordinator.uploadCoordinator
                    for await state in reachability.stateUpdates() {
                        if state == .online {
                            if let operationQueue { await operationQueue.wake() }
                            if let uploadCoordinator { await uploadCoordinator.wake() }
                        }
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
