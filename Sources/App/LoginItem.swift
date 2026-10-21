import ServiceManagement

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registering fails for an app that isn't in /Applications; the switch then simply stays off.
    static func set(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }
}
