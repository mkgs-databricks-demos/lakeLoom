import Foundation

/// Privacy-consent versioning + persistence. The consent string the
/// user agrees to at onboarding is versioned so future privacy
/// changes can require re-consent. Currently a no-op gate; the
/// re-consent trigger lands when the privacy policy actually changes.
public enum ConsentVersion {

    /// Bump when the consent text or coverage materially changes.
    public static let current: String = "1.0"

    /// `UserDefaults` key for the version string the user consented to.
    private static let acknowledgedVersionKey = "consent.acknowledged.version"

    /// `UserDefaults` key for the timestamp of the most recent
    /// acknowledgement. Embedded in every ZeroBus record's headers
    /// (Module 01 §3.2 schema) for audit.
    private static let acknowledgedAtKey = "consent.acknowledged.at"

    /// Read the acknowledged version, if any.
    public static var acknowledgedVersion: String? {
        UserDefaults.standard.string(forKey: acknowledgedVersionKey)
    }

    /// Read the acknowledged-at timestamp, if any.
    public static var acknowledgedAt: Date? {
        UserDefaults.standard.object(forKey: acknowledgedAtKey) as? Date
    }

    /// True when the user has acknowledged a version that's at least
    /// the current one. Future re-consent triggers compare versions
    /// here.
    public static var hasAcknowledgedCurrent: Bool {
        acknowledgedVersion == current
    }

    /// Persist that the user acknowledged the current version at
    /// `now`. ``AppCoordinator/acknowledgeConsent()`` calls this
    /// before advancing to the workspace URL step.
    public static func recordAcknowledgement(at now: Date = Date()) {
        UserDefaults.standard.set(current, forKey: acknowledgedVersionKey)
        UserDefaults.standard.set(now, forKey: acknowledgedAtKey)
    }
}
