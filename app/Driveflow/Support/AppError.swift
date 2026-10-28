import Foundation

enum AppError: LocalizedError, Identifiable {
    case notConfigured
    case shareAccessNotConfigured
    case shareMintUnauthorized
    case shareMintRateLimited
    case shareMintFailed
    case waitingForShare
    case folderLinkNotFolder
    case authCancelled
    case authFailed(String)
    case authRevoked(String)
    case licenseRequired(email: String?)
    case tokenExpired
    case network(String)
    case driveAPI(String)
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
        case .shareAccessNotConfigured:
            return "Drive share access isn’t set up yet. Configure a share mint URL, a local service-account key, or DRIVEFLOW_SHARE_EMAIL + DRIVEFLOW_SHARE_ACCESS_TOKEN (see README)."
        case .shareMintUnauthorized:
            return "Your Driveflow sign-in expired. Sign in again to continue."
        case .shareMintRateLimited:
            return "Driveflow is busy opening Drive access. Wait a moment and try again."
        case .shareMintFailed:
            return "Driveflow couldn’t open Drive access. Try again in a moment."
        case .waitingForShare:
            return "Still waiting for access to that folder. Share it as Viewer with your Driveflow address, and leave Notify people unchecked."
        case .folderLinkNotFolder:
            return "That link isn’t a folder. Paste a Google Drive folder link."
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
            return "Your Driveflow session expired. Sign in again."
        case .network(let detail):
            return "Network problem. \(detail)"
        case .driveAPI(let detail):
            return "Google Drive returned an error. \(detail)"
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
        case .shareAccessNotConfigured:
            return "Create a service account in GCP project driveflow-503421, enable the Drive API, and use the mint API or a gitignored local key for development."
        case .shareMintUnauthorized:
            return "Choose Sign in with Google to continue."
        case .shareMintRateLimited:
            return "The Drive session service asked Driveflow to slow down."
        case .shareMintFailed:
            return "If this keeps happening, sign out and sign in again."
        case .waitingForShare:
            return "In Google Drive: Share → paste the Driveflow email → Viewer → uncheck Notify people → Share."
        case .folderLinkNotFolder:
            return "In Google Drive, open the folder and copy its link. It looks like https://drive.google.com/drive/folders/…"
        case .licenseRequired:
            return "Purchase at usedriveflow.app using this Google email, then sign in again."
        case .authCancelled, .authFailed, .authRevoked, .tokenExpired:
            return "Choose Sign in with Google to try again."
        case .network, .driveAPI:
            return "Check your connection and retry."
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

    var requiresSignInAgain: Bool {
        switch self {
        case .shareMintUnauthorized, .licenseRequired, .tokenExpired, .authRevoked:
            return true
        case .notConfigured, .shareAccessNotConfigured, .shareMintRateLimited, .shareMintFailed,
             .waitingForShare, .folderLinkNotFolder, .authCancelled, .authFailed, .network,
             .driveAPI, .destinationUnavailable, .insufficientSpace, .volumeWarning,
             .rcloneMissing, .rcloneFailed, .unknown:
            return false
        }
    }
}
