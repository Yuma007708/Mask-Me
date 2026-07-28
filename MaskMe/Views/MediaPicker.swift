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
    /// 同時に選べる素材の上限。既定 1（新規編集セッションの開始はいつも 1 件）。
    /// タイムラインへの素材追加だけが複数（`VideoTimelineView`）を許す。
    var selectionLimit: Int = 1
    /// 取り込み失敗の通知先（iCloud 素材のダウンロード失敗・容量不足・非対応形式）。
    /// nil のときは無言。呼び出し側は既存の `errorMessage` 経路へ流すこと。
    var onFailure: ((String) -> Void)?
    /// 選ばれた素材を**ピッカーの並び順のまま**まとめて返す。
    /// キャンセル時は空配列（呼び出し側がシートの状態を畳めるように必ず呼ぶ）。
    let onPick: ([PickedMedia]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = selectionLimit
        config.filter = filter.pickerFilter
        config.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: config)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(filter: filter, onFailure: onFailure, onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let filter: Filter
        private let onFailure: ((String) -> Void)?
        private let onPick: ([PickedMedia]) -> Void

        init(filter: Filter,
             onFailure: ((String) -> Void)?,
             onPick: @escaping ([PickedMedia]) -> Void) {
            self.filter = filter
            self.onFailure = onFailure
            self.onPick = onPick
        }

        /// 複数選択の取り込み。
        ///
        /// **並び順は `results` の順（＝ピッカーで選ばれた順）を保つ。** 取り込みは
        /// provider ごとに非同期で完了順が前後するため、結果は添字つきの配列へ書き戻し、
        /// 全件そろってから 1 回だけ返す（完了順にコールバックするとタイムラインへ
        /// 並ぶ順序が非決定になる）。
        ///
        /// 1 件でも失敗したときに残りを捨てない: 成功したぶんはそのまま返し、
        /// 失敗件数だけを別途通知する（従来は `return` で全部無言に消えていた）。
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else {
                DispatchQueue.main.async { [onPick] in onPick([]) }
                return
            }
            var loaded = [PickedMedia?](repeating: nil, count: results.count)
            var failures = 0
            let lock = NSLock()
            let group = DispatchGroup()
            for (index, result) in results.enumerated() {
                group.enter()
                load(from: result.itemProvider) { media in
                    lock.lock()
                    if let media {
                        loaded[index] = media
                    } else {
                        failures += 1
                    }
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { [onPick, onFailure] in
                onPick(loaded.compactMap { $0 })
                guard failures > 0 else { return }
                onFailure?(failures == results.count
                           ? "素材を読み込めませんでした"
                           : "\(failures) 件の素材を読み込めませんでした")
            }
        }

        /// 1 件を取り込む。失敗は nil で返す（呼び出し元が件数を数えて通知する）。
        private func load(from provider: NSItemProvider,
                          completion: @escaping (PickedMedia?) -> Void) {
            switch filter {
            case .images:
                loadImage(from: provider, completion: completion)
            case .videos:
                loadVideo(from: provider, completion: completion)
            case .videosAndImages:
                // 選ばれた実体の型で振り分ける（動画は movie 型を持つ）。
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    loadVideo(from: provider, completion: completion)
                } else {
                    loadImage(from: provider, completion: completion)
                }
            }
        }

        private func loadImage(from provider: NSItemProvider,
                               completion: @escaping (PickedMedia?) -> Void) {
            guard provider.canLoadObject(ofClass: UIImage.self) else {
                completion(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else {
                    completion(nil)
                    return
                }
                completion(.image(image))
            }
        }

        private func loadVideo(from provider: NSItemProvider,
                               completion: @escaping (PickedMedia?) -> Void) {
            let typeID = UTType.movie.identifier
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                // url が nil になる代表例は iCloud 素材のダウンロード失敗。
                guard let url else {
                    completion(nil)
                    return
                }
                // The provided URL is temporary; copy it before the closure returns.
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("picked-\(UUID().uuidString).mov")
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    completion(nil)  // 容量不足など
                    return
                }
                completion(.video(destination))
            }
        }
    }
}
