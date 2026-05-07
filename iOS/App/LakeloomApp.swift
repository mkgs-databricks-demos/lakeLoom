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
            config: AuthConfig(
                clientID: AppConfig.oauthClientID,
                redirectURI: AppConfig.redirectURI
            ),
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
    /// Published Databricks OAuth client ID. Replace before TestFlight
    /// — pulled from a build-config setting per Module 10 §5.4.
    /// Empty string here keeps the coordinator wired without committing
    /// a real client ID to the repo.
    static let oauthClientID: String = ""

    /// Custom URL scheme registered in Info.plist for the OAuth
    /// callback. Matches the value the published OAuth app expects.
    static let redirectURI: URL = URL(string: "lakeloom://oauth/callback") ?? URL(fileURLWithPath: "/")
}
