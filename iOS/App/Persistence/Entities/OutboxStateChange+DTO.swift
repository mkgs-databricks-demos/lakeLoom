import CoreData
import Foundation

public struct OutboxStateChangeDTO: Sendable, Equatable, Hashable {
    public let id: String
    public let recordUUID: String
    public let fromState: String
    public let toState: String
    public let reason: String?
    public let at: Date

    public init(
        id: String,
        recordUUID: String,
        fromState: String,
        toState: String,
        reason: String?,
        at: Date
    ) {
        self.id = id
        self.recordUUID = recordUUID
        self.fromState = fromState
        self.toState = toState
        self.reason = reason
        self.at = at
    }
}

extension OutboxStateChange {

    public func toDTO() -> OutboxStateChangeDTO {
        OutboxStateChangeDTO(
            id: id,
            recordUUID: recordUUID,
            fromState: fromState,
            toState: toState,
            reason: reason,
            at: at
        )
    }

    public func apply(_ dto: OutboxStateChangeDTO) {
        id = dto.id
        recordUUID = dto.recordUUID
        fromState = dto.fromState
        toState = dto.toState
        reason = dto.reason
        at = dto.at
    }
}
