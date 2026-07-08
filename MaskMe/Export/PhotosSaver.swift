import Photos
import UIKit

/// Saves processed media to the user's photo library.
public enum PhotosSaver {
    public enum SaveError: Error {
        case notAuthorized
        case failed
    }

    /// Saves a still image, requesting add-only authorization if needed.
    public static func save(image: UIImage) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Saves a video file at `url`.
    public static func save(videoURL url: URL) async throws {
        try await ensureAuthorized()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    private static func ensureAuthorized() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else {
                throw SaveError.notAuthorized
            }
        default:
            throw SaveError.notAuthorized
        }
    }
}
