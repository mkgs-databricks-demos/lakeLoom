import CoreData
import Foundation

/// Cached non-sensitive workspace metadata so the Sessions list can
/// render workspace names without an extra Keychain read for the
/// AuthService's full WorkspaceCredential. Refreshed by AuthService
/// on sign-in / identity refresh.
@objc(WorkspaceMetadataCache)
public final class WorkspaceMetadataCache: NSManagedObject {}
