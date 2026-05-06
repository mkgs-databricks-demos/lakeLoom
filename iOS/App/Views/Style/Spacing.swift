import CoreFoundation

/// Spacing scale used across the app. Per Module 08 §9.3, every layout uses
/// these constants instead of ad-hoc CGFloats so the visual rhythm stays
/// consistent and we have a single place to retune it.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}
