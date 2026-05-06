import CoreData
import Foundation

/// Managed-object class for the OutboxRecord entity.
///
/// Lives inside the persistence layer. Cross-actor handoff uses
/// ``OutboxRecordDTO`` (`+DTO.swift`) — never pass `OutboxRecord`
/// across actor boundaries.
@objc(OutboxRecord)
public final class OutboxRecord: NSManagedObject {

    /// All valid lifecycle states of an outbox record. Stored on the
    /// entity as a String so we can evolve the state machine without
    /// a heavyweight model migration.
    public enum State: String, Sendable, CaseIterable {
        case pending
        case inflight
        case sent
        case failed
        case deadLettered = "dead_lettered"
    }
}
