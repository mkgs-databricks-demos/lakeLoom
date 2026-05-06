import CoreData
import Foundation

/// Audit row for an OutboxRecord state transition. Bounded retention
/// (last 1000 entries per session, purged on session completion per
/// Module 07 §4.2) — kept primarily for "why did this record get
/// dead-lettered?" debugging and the diagnostics screen.
@objc(OutboxStateChange)
public final class OutboxStateChange: NSManagedObject {}
