import Foundation

/// Decoded form of a Databricks SCIM 2.0 `/Me` response.
///
/// We map only the fields the iOS app actually uses (`id`, `userName`,
/// `displayName`, `active`, primary email). The full SCIM schema has
/// many more fields, but we keep the surface narrow so additions
/// server-side don't break decoding.
public struct SCIMMeResponse: Sendable, Equatable, Codable {
    public let id: String
    public let userName: String
    public let displayName: String?
    public let active: Bool?
    public let emails: [Email]?

    public struct Email: Sendable, Equatable, Codable {
        public let value: String
        public let primary: Bool?
    }

    public init(id: String, userName: String, displayName: String?, active: Bool?, emails: [Email]?) {
        self.id = id
        self.userName = userName
        self.displayName = displayName
        self.active = active
        self.emails = emails
    }

    /// Best-effort primary email — first entry with `primary == true`,
    /// otherwise the first entry, otherwise nil.
    public var primaryEmail: String? {
        guard let emails, !emails.isEmpty else { return nil }
        if let primary = emails.first(where: { $0.primary == true }) {
            return primary.value
        }
        return emails.first?.value
    }
}

extension SCIMMeResponse {
    /// Project the SCIM response into the app's ``UserIdentity`` shape.
    /// Defaults: `displayName` falls back to `userName`; `active` defaults
    /// to `true` (matches Databricks' behavior when the field is absent).
    public func toUserIdentity() -> UserIdentity {
        UserIdentity(
            userID: id,
            userName: userName,
            displayName: displayName ?? userName,
            email: primaryEmail,
            active: active ?? true
        )
    }
}
