import Foundation
import ServiceManagement

/// Applies the user's launch-at-login preference using ServiceManagement.
public enum LaunchAtLoginController {
    /// Enables or disables launch at login for the main app.
    public static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The setting remains persisted so a signed app can apply it when ServiceManagement allows.
        }
    }
}
