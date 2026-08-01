import Foundation
import Testing

/// Test-scoped UserDefaults, removed afterwards — each suite is a real
/// CFPreferences domain that would otherwise flush a plist into
/// ~/Library/Preferences on every run.
func withTestDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let name = "pewter-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    return try body(defaults)
}
