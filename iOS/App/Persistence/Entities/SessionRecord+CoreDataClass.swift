import CoreData
import Foundation

/// Managed-object class for the SessionRecord entity. One row per
/// captured session — durable across app restarts so the Sessions
/// list keeps its history and so the upload coordinator can resume
/// pending uploads.
///
/// Cross-actor handoff uses ``SessionRecordDTO`` (`+DTO.swift`).
@objc(SessionRecord)
public final class SessionRecord: NSManagedObject {

    public enum UploadState: String, Sendable, CaseIterable {
        case pending
        case wifiWaiting = "wifi_waiting"
        case uploading
        case verifying
        case uploaded
        case purged
        case failed
        case deadLettered = "dead_lettered"
        case noAudio = "no_audio"
    }

    public enum CaptureMode: String, Sendable, CaseIterable {
        case quickCapture = "quick_capture"
        case meeting
    }
}
