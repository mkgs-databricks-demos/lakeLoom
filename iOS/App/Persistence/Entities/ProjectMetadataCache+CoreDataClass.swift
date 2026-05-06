import CoreData
import Foundation

/// Persistent denormalization of recent project metadata so the
/// Sessions list can render project names without a network roundtrip
/// on first render. Refreshed by ProjectService events. Distinct from
/// ProjectService's in-memory 5-min TTL cache (Module 06 §10) — that
/// one is transient and lost across launches.
@objc(ProjectMetadataCache)
public final class ProjectMetadataCache: NSManagedObject {}
