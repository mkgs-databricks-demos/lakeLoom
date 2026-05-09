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

        let auth = AuthService(
            config: AuthConfig(clientID: AppConfig.oauthClientID),
            oauth: LiveOAuthClient(),
            keychain: LiveKeychainStore(),
            identity: LiveDatabricksIdentityClient()
        )
        let endpointResolver = LiveAppEndpointResolver()
        let projects = ProjectService(
            auth: auth,
            endpointResolver: endpointResolver
        )

        _coordinator = State(
            wrappedValue: AppCoordinator(
                auth: auth,
                projects: projects,
                coreDataStack: coreDataStack
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .task { await coordinator.bootstrap() }
        }
    }
}

/// App-level configuration baked at build time.
enum AppConfig {
    /// Published Databricks OAuth client ID for U2M flows. The
    /// `databricks-cli` client is registered with `http://localhost`
    /// loopback redirects only, which is why we run an in-app
    /// `LoopbackCallbackListener` instead of a custom URL scheme.
    /// See Module 01 §11 for the redirect URI strategy.
    static let oauthClientID: String = "databricks-cli"
}
