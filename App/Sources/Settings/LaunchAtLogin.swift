import ServiceManagement

/// Live view over SMAppService. Status is never cached — System Settings
/// can flip it behind us, so every read goes to the service. Callers should
/// read `status` once per decision: each access is a synchronous round trip
/// to the SM daemon, and separate reads can disagree.
enum LaunchAtLogin {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else if ![.notRegistered, .notFound].contains(status) {
            // unregister() throws when nothing is registered; off is
            // already the outcome the caller wants.
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
