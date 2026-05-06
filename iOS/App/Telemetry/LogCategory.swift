import Foundation

/// The fixed set of logging categories. One per major architectural
/// component, plus a `network` bucket for the HTTP/gRPC transport
/// layer (which isn't itself a module).
///
/// Adding a new category is a deliberate change: it shows up in
/// Console.app's category filter, in the in-app log viewer, and in
/// the support bundle's per-category breakdown.
///
/// See Module 09 §3.2.
public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case auth        = "auth"
    case capture     = "capture"
    case ingest      = "ingest"
    case storage     = "storage"
    case projects    = "projects"
    case persistence = "persistence"
    case coordinator = "coordinator"
    case ui          = "ui"
    case network     = "network"
    case telemetry   = "telemetry"
    case appSync     = "appsync"

    /// The os.log subsystem string. Constant across categories so
    /// Console.app's "Subsystem" filter scopes to the entire app.
    public var subsystem: String {
        "com.databricks.lakeloom"
    }
}
