import AppKit

/// Apps whose captures prefer the pasteboard tier. Browsers carry rich
/// pasteboard flavors worth converting, their Cmd+C is dependable, and
/// their accessibility selection is the weakest read available — plain
/// text with block boundaries mashed together.
enum RichSourceApps {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "company.thebrowser.Browser",
        "org.chromium.Chromium",
        "app.zen-browser.zen",
        "net.imput.helium",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.google.Chrome.dev",
    ]

    @MainActor
    static func frontmostIsRichSource() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return browserBundleIDs.contains(bundleID)
    }
}
