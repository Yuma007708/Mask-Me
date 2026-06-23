import UIKit
import XCTest

/// Locates the fixture images / model bundled into the test target.
///
/// Real face photos are intentionally NOT committed (privacy / licensing); the
/// developer drops their own into `App/MaskMeTests/Fixtures/` (see the README
/// there). When a fixture or the MediaPipe model is missing, tests `throw
/// XCTSkip` rather than fail, so the suite stays green on machines without them.
enum FixtureLoader {
    /// Path to the bundled `face_landmarker.task`, or `nil` if absent.
    static func modelPath() -> String? {
        Bundle(for: BundleToken.self).path(forResource: "face_landmarker", ofType: "task")
    }

    /// Images under `Fixtures/<subdirectory>` (e.g. "faces", "nonfaces").
    static func images(in subdirectory: String) -> [UIImage] {
        let bundle = Bundle(for: BundleToken.self)
        var urls: [URL] = []
        for ext in ["jpg", "jpeg", "png", "heic"] {
            urls += bundle.urls(
                forResourcesWithExtension: ext,
                subdirectory: "Fixtures/\(subdirectory)"
            ) ?? []
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { UIImage(data: $0) }
    }

    /// URL of a bundled fixture video, or `nil` if absent.
    static func videoURL(named name: String, ext: String = "mov") -> URL? {
        Bundle(for: BundleToken.self).url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Fixtures"
        )
    }
}

/// Anchors `Bundle(for:)` to the test bundle.
private final class BundleToken {}
