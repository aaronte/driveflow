import Foundation

enum AppError: LocalizedError, Identifiable {
    case notConfigured
    case authCancelled
    case authFailed(String)
    case authRevoked(String)
    case licenseRequired(email: String?)
    case tokenExpired
    case network(String)
    case driveAPI(String)
    case folderPickRequiresFiles
    case destinationUnavailable
    case insufficientSpace(needed: Int64, available: Int64)
    case volumeWarning(String)
    case rcloneMissing
    case rcloneFailed(String)
    case unknown(String)

    var id: String { localizedDescription }

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google sign-in isn’t set up yet. Add Desktop OAuth credentials via env vars or oauth-client.json (see README)."
        case .authCancelled:
            return "Sign-in was cancelled."
        case .authFailed(let detail):
            return "Couldn’t sign in to Google. \(detail)"
        case .authRevoked:
            return "Google revoked Driveflow’s access. Sign in again to continue."
        case .licenseRequired(let email):
            if let email, !email.isEmpty {
                return "No Driveflow license for \(email). Buy a license with this email to continue."
            }
            return "No Driveflow license for this Google account. Buy a license with this email to continue."
        case .tokenExpired:
            return "Your Google session expired. Sign in again."
        case .network(let detail):
            return "Network problem. \(detail)"
        case .driveAPI(let detail):
            return "Google Drive returned an error. \(detail)"
        case .folderPickRequiresFiles:
            return "That folder can’t be downloaded with Driveflow’s Google access. Pick the files inside the folder, not just the folder."
        case .destinationUnavailable:
            return "That destination isn’t available. Choose another folder or reconnect the drive."
        case .insufficientSpace(let needed, let available):
            return "Not enough free space. Need \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), have \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))."
        case .volumeWarning(let detail):
            return detail
        case .rcloneMissing:
            return "The download engine is missing from the app bundle. Reinstall Driveflow."
        case .rcloneFailed(let detail):
            return "Download engine error. \(detail)"
        case .unknown(let detail):
            return detail
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            return "Copy oauth-client.example.json to oauth-client.json, or set DRIVEFLOW_GOOGLE_CLIENT_ID and DRIVEFLOW_GOOGLE_CLIENT_SECRET."
        case .licenseRequired:
            return "Purchase at usedriveflow.app using this Google email, then sign in again."
        case .authCancelled, .authFailed, .authRevoked, .tokenExpired:
            return "Choose Sign in with Google to try again."
        case .network, .driveAPI:
            return "Check your connection and retry."
        case .folderPickRequiresFiles:
            return "Open Google’s file picker again and select the individual files you want."
        case .destinationUnavailable, .insufficientSpace, .volumeWarning:
            return "Pick a different destination volume."
        case .rcloneMissing:
            return "Download a fresh build from the website or GitHub Releases."
        case .rcloneFailed:
            return "Resume the transfer when ready. Already-downloaded files will be skipped."
        case .unknown:
            return nil
        }
    }
}
