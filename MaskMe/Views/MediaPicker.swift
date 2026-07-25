import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Media picked from the photo library.
enum PickedMedia {
    case image(UIImage)
    case video(URL)
}

/// A thin SwiftUI wrapper around `PHPickerViewController`, filtered to either
/// images or videos.
struct MediaPicker: UIViewControllerRepresentable {
    enum Filter {
        case images
        case videos
        /// 動画と写真の両方（S6: タイムラインへの素材追加。写真はモデル側で
        /// `PhotoClipEncoder` により静止 mp4 へエンコードされてクリップになる）。
        case videosAndImages

        var pickerFilter: PHPickerFilter {
            switch self {
            case .images: return .images
            case .videos: return .videos
            case .videosAndImages: return .any(of: [.videos, .images])
            }
        }
    }

    let filter: Filter
    let onPick: (PickedMedia) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = filter.pickerFilter
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(filter: filter, onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let filter: Filter
        private let onPick: (PickedMedia) -> Void

        init(filter: Filter, onPick: @escaping (PickedMedia) -> Void) {
            self.filter = filter
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            switch filter {
            case .images:
                loadImage(from: provider)
            case .videos:
                loadVideo(from: provider)
            case .videosAndImages:
                // 選ばれた実体の型で振り分ける（動画は movie 型を持つ）。
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    loadVideo(from: provider)
                } else {
                    loadImage(from: provider)
                }
            }
        }

        private func loadImage(from provider: NSItemProvider) {
            guard provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { [onPick] object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { onPick(.image(image)) }
            }
        }

        private func loadVideo(from provider: NSItemProvider) {
            let typeID = UTType.movie.identifier
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [onPick] url, _ in
                guard let url else { return }
                // The provided URL is temporary; copy it before the closure returns.
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("picked-\(UUID().uuidString).mov")
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    return
                }
                DispatchQueue.main.async { onPick(.video(destination)) }
            }
        }
    }
}
