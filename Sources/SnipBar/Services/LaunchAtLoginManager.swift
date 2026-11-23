import Foundation
import ServiceManagement

/// Manages macOS 13+ Login Item registration via `SMAppService.mainApp`.
/// CAVEAT SOLVED: Users can toggle background/login items externally inside
/// `System Settings → General → Login Items`. Storing a boolean in `UserDefaults`
/// drifts out of sync! Instead, we query `SMAppService.mainApp.status` as the single
/// source of truth and reconcile whenever the settings view appears.
@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var requiresSystemSettingsApproval: Bool = false
    @Published public private(set) var lastErrorMessage: String?

    private init() {
        refreshStatus()
    }

    public func refreshStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            requiresSystemSettingsApproval = false
        case .requiresApproval:
            isEnabled = false
            requiresSystemSettingsApproval = true
        case .notRegistered, .notFound:
            isEnabled = false
            requiresSystemSettingsApproval = false
        @unknown default:
            isEnabled = false
            requiresSystemSettingsApproval = false
        }
    }

    public func setEnabled(_ shouldEnable: Bool) {
        lastErrorMessage = nil
        do {
            if shouldEnable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        refreshStatus()
    }

    public func openSystemLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
