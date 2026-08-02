import os

/// One logger per category, under a single subsystem constant, so
/// every call site stays greppable with the same predicate. The
/// `mise run logs` predicate hardcodes the same subsystem string.
public extension Logger {
    private static let pewterSubsystem = "com.oakoss.Pewter"

    static let capture = Logger(subsystem: pewterSubsystem, category: "capture")
    static let panel = Logger(subsystem: pewterSubsystem, category: "panel")
    static let storage = Logger(subsystem: pewterSubsystem, category: "storage")
    static let settings = Logger(subsystem: pewterSubsystem, category: "settings")
    static let hotkey = Logger(subsystem: pewterSubsystem, category: "hotkey")
}
