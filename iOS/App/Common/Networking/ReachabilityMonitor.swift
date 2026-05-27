import Foundation
import Network

/// Observable network-reachability state for the UI layer.
///
/// Backed by ``NWPathMonitor`` — Apple's recommended API for
/// "is the device online" since iOS 12 (`SCNetworkReachability` is
/// effectively deprecated). The monitor classifies the current path
/// as either ``online`` (any usable interface, regardless of medium)
/// or ``offline`` (no path or `.unsatisfied`).
///
/// **Why not a more fine-grained signal?** A real reachability layer
/// could distinguish cellular vs Wi-Fi, expensive interfaces,
/// constrained mode, and so on — useful for upload gating, large-
/// file uploads on metered networks, etc. Phase 1's job is just to
/// tell the user "you're offline; don't expect this to work right
/// now," which is binary. Future phases (cellular throttling, Wi-Fi-
/// only uploads) can subscribe to a richer `Path` snapshot directly
/// off this same monitor.
///
/// Surface: a `@MainActor`-isolated `ReachabilityMonitor` whose
/// `state` is `@Published`-style via SwiftUI's `@Observable` macro,
/// so any view holding the monitor can simply read `state` and
/// SwiftUI re-renders on transitions. AppCoordinator owns one
/// instance and exposes it; HomeContainerView reads it.
///
/// Lifecycle: `start()` once at app boot (idempotent), `stop()` only
/// if the app intentionally tears down (we don't bother in v1 —
/// the monitor is cheap and lives for the app's lifetime).
@MainActor
@Observable
public final class ReachabilityMonitor {

    /// Snapshot of the current network reachability. `unknown` is
    /// the initial state before the first `NWPathMonitor` callback
    /// fires; we treat it as `online` for UI purposes (don't show
    /// an "Offline" banner during the few-ms boot window).
    public enum State: Sendable, Equatable {
        case unknown
        case online
        case offline
    }

    public private(set) var state: State = .unknown

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var didStart = false
    /// Fan-out for non-UI subscribers (e.g. the OperationQueue wake
    /// hook). UI surfaces just read `state` via @Observable; this
    /// stream exists so the LakeloomApp `.task` block can wake the
    /// outbox on online transitions without polling.
    private var subscriptions: [UUID: AsyncStream<State>.Continuation] = [:]

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "lakeloom.reachability", qos: .utility)
    }

    /// Begin observing path updates. Idempotent. Safe to call from
    /// `LakeloomApp.init()` — the monitor delivers its first
    /// callback within a few hundred ms typically.
    public func start() {
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            let newState: State = path.status == .satisfied ? .online : .offline
            // pathUpdateHandler fires on the monitor's queue;
            // hop to MainActor to mutate the observable state so
            // SwiftUI views re-render correctly.
            Task { @MainActor [weak self] in
                self?.state = newState
                self?.broadcast(newState)
            }
        }
        monitor.start(queue: queue)
    }

    /// Subscribe to every transition in `state`. The stream replays
    /// the current value as its first yield so a late subscriber
    /// (the LakeloomApp `.task` block runs after `start()`) gets the
    /// initial state immediately.
    public func stateUpdates() -> AsyncStream<State> {
        AsyncStream { continuation in
            let id = UUID()
            subscriptions[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.subscriptions[id] = nil
                }
            }
        }
    }

    private func broadcast(_ next: State) {
        for continuation in subscriptions.values {
            continuation.yield(next)
        }
    }

    /// Convenience predicate. UI code that wants to gate a
    /// network-dependent affordance can read this and treat
    /// `.unknown` as online (the conservative default during the
    /// brief startup window).
    public var isOnline: Bool {
        switch state {
        case .online, .unknown: return true
        case .offline:           return false
        }
    }
}
