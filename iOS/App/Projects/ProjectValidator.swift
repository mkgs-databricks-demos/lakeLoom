import Foundation

/// Client-side validation for project create / update inputs.
///
/// The Databricks App is the authoritative validator (it returns HTTP
/// 400 with `validation_failed` if our checks miss something). These
/// rules exist so iOS fails fast on obvious mistakes without a network
/// roundtrip.
///
/// Per Module 06 §8.
public enum ProjectValidator {

    /// Trim, length-check, and character-class-check the project name.
    /// Returns the normalized form on success.
    public static func validateName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectError.validationFailed(reason: "Name cannot be empty.")
        }
        guard trimmed.count <= 200 else {
            throw ProjectError.validationFailed(reason: "Name must be 200 characters or fewer.")
        }
        guard trimmed.unicodeScalars.allSatisfy(Self.isAllowedInName) else {
            throw ProjectError.validationFailed(reason: "Name contains invalid characters.")
        }
        return trimmed
    }

    /// Trim, length-check the optional description. Empty/whitespace-only
    /// inputs normalize to nil so we don't send "" to the App.
    public static func validateDescription(_ raw: String?) throws -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.count <= 2_000 else {
            throw ProjectError.validationFailed(reason: "Description must be 2000 characters or fewer.")
        }
        return trimmed
    }

    private static func isAllowedInName(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        // Whitespace allowed, but not control characters or newlines —
        // those are rejected (we trimmed leading/trailing whitespace
        // already; embedded tabs / newlines aren't wanted).
        if scalar == " " { return true }
        if "-_./()&".unicodeScalars.contains(scalar) { return true }
        return false
    }
}
