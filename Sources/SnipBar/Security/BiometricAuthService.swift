import Foundation
import LocalAuthentication

public enum BiometricAuthError: LocalizedError {
    case cancelled
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authentication was cancelled."
        case .unavailable(let detail):
            return "Authentication unavailable: \(detail)"
        case .failed(let detail):
            return "Authentication failed: \(detail)"
        }
    }
}

/// Lightweight Touch ID / macOS login password confirmation service using `LocalAuthentication`.
/// WHY THIS WORKS WITH "SIGN TO RUN LOCALLY" (`CODE_SIGN_IDENTITY = "-"`):
/// Unlike `kSecUseDataProtectionKeychain`, `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`
/// requires ZERO Apple Developer provisioning profiles or Keychain entitlements.
/// It prompts Touch ID (or Apple Watch) when hardware is available, and automatically falls back
/// to the user's macOS login password on clamshell MacBooks, Mac minis, or Mac Studios.
@MainActor
public final class BiometricAuthService {
    public static let shared = BiometricAuthService()

    /// Signals `FloatingPopoverPanel` not to auto-dismiss when the system Touch ID sheet steals key focus.
    public private(set) var isPresentingPrompt: Bool = false

    private init() {}

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            let detail = authError?.localizedDescription ?? "No biometric or device passcode configured."
            throw BiometricAuthError.unavailable(detail)
        }

        isPresentingPrompt = true
        defer { isPresentingPrompt = false }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard success else {
                throw BiometricAuthError.failed("Verification did not succeed.")
            }
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                throw BiometricAuthError.cancelled
            default:
                throw BiometricAuthError.failed(laError.localizedDescription)
            }
        }
    }
}
