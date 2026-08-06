import Foundation

/// Stable handles for the panel's elements, for automation to query by.
///
/// Separate from `accessibilityLabel`, which is user-facing copy and changes
/// when the copy does — a single change rewrote the HUD, banner and toast
/// strings across three surfaces, and anything selecting on those labels would
/// have broken on a correct edit. These never change, so a test written against
/// one keeps passing while the words move.
///
/// Not localized, not shown to anyone, and deliberately dotted rather than
/// camelCased so a dump of the tree groups by surface when sorted.
enum PanelAccessibilityID {
    static let searchField = "panel.search"
    static let menuButton = "panel.menu"
    static let noteList = "panel.list"
    static let composer = "panel.composer"
    static let emptyState = "panel.emptyState"
    /// The transient toast. Its severity is not encoded here — a test asserting
    /// "this is a refusal" should read the rendered symbol, or the identifier
    /// would have to be kept in step with the severity to stay true.
    static let toast = "panel.toast"
    static let storageBanner = "panel.storageBanner"
    static let storageBannerReveal = "panel.storageBanner.reveal"
    static let permissionBanner = "panel.permissionBanner"
    static let permissionBannerEnable = "panel.permissionBanner.enable"
    static let shortcutGuide = "panel.shortcutGuide"

    /// Rows carry the item's id so a test can address the note it just added
    /// rather than a position — an index would silently retarget whenever a
    /// filter, a sort or an external edit moved the row.
    static func noteRow(_ id: UUID) -> String {
        "\(noteRowPrefix)\(id.uuidString)"
    }

    /// Fixed part of a row's identifier, for matching every row at once.
    /// `noteRow` is built from it so the two cannot drift.
    static let noteRowPrefix = "panel.row."
}
