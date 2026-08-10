import Foundation
import MosaicCore
import UIKit

/// 顔画像から人物署名（`FaceSignature`）を作る層。
///
/// `MMFaceEmbedder`（OpticalFlowKit 内の SFace ラッパー）とコアの純ロジックを繋ぐだけの
/// 薄い接着剤。`MediaPipeFaceLandmarkerAdapter` が MediaPipe 型をコアの値型へ直すのと
/// 同じ役目で、**コア側は SFace も OpenCV も知らないまま**でいられる。
///
/// モデル読み込みが重いので `shared` を使い回す。`MMFaceEmbedder` の中身は
/// OpenCV の DNN で**スレッド安全ではない**ため、推論はロックで直列化する。
/// 事前スキャン・書き出し・カメラが同時に叩きうる（実際、事前スキャンは
/// バックグラウンドで走りながらプレビューが描画する）。
final class FaceSignatureProvider {
    static let shared = FaceSignatureProvider()

    private let embedder: MMFaceEmbedder?
    private let lock = NSLock()

    /// モデルが積まれていない環境（fixture 無しの CI 等）では nil のまま動く。
    /// 署名が作れなければ判断は位置追跡へ落ち、最終的に安全側（隠す）になる。
    var isAvailable: Bool { embedder != nil }

    init(modelName: String = "sface", bundle: Bundle = .main) {
        if let path = bundle.path(forResource: modelName, ofType: "onnx") {
            embedder = MMFaceEmbedder(modelPath: path)
        } else {
            embedder = nil
        }
    }

    /// 顔 1 つ分の署名と、それを信じてよいかの計測をまとめて返す。
    ///
    /// 品質ゲートで落ちた顔は**埋め込みを計算しない**。無駄な推論を避けるためだけでなく、
    /// 信用できない署名を後段へ渡さないため（渡すと 0.2 台の類似度で「別人」と
    /// 誤判定され、選んだ人が素で映る）。
    func measure(_ set: FaceLandmarkSet, in image: UIImage) -> (
        signature: FaceSignature?, quality: FaceSignatureQuality?
    ) {
        let pixelSize = CGSize(width: image.size.width * image.scale,
                               height: image.size.height * image.scale)
        guard let quality = FaceSignatureQuality.measure(set, imageSize: pixelSize) else {
            return (nil, nil)
        }
        guard quality.isTrustworthy else { return (nil, quality) }
        return (signature(for: set, in: image, pixelSize: pixelSize), quality)
    }

    /// 1 フレーム分の顔すべての署名。**`faces` と同じ順・同じ件数**を返す
    /// （`FaceSignatureCache` が添字の対応で顔と結びつけるため、間引いてはいけない）。
    /// 品質ゲートを通らなかった顔は nil。
    func signatures(for faces: [FaceLandmarkSet], in image: UIImage) -> [FaceSignature?] {
        faces.map { measure($0, in: image).signature }
    }

    /// ライブ検出（プレビュー / カメラ）1 フレーム分の署名。
    ///
    /// **署名と品質判定は原寸から行う。** `FaceSignatureQuality.minimumFacePixelWidth`(80)
    /// は SFace の入力 112×112 に対する実解像度の下限なので、検出用に縮小した 640px の
    /// 画像から測ると実素材が軒並み落ちる（実測: probe_crowd_04 は 640px で 0/11 通過、
    /// 原寸で 9/11 通過。同じ顔・同じ検出で 0% ↔ 82% が入れ替わる）。初期スキャンは
    /// 元から原寸を渡していたので、ライブ経路だけがこの取りこぼしをしていた。
    ///
    /// - Parameters:
    ///   - detection: 検出に使った縮小画像。原寸が取れなかったときの退避先
    ///     （署名なしで位置追跡へ落とすより、品質ゲートに掛けたほうが安全側に寄る）。
    ///   - native: 原寸フレームの取り出し口。**この関数が呼ばれたときだけ**評価される
    ///     （毎検出で原寸変換すると 10Hz で全解像度のコピーが走る）。
    func signatures(for faces: [FaceLandmarkSet], detection: UIImage,
                    native: () -> CGImage?) -> [FaceSignature?] {
        signatures(for: faces, in: native().map { UIImage(cgImage: $0) } ?? detection)
    }

    /// 品質ゲートを通さずに署名だけを作る（較正・計測用）。
    func signature(for set: FaceLandmarkSet, in image: UIImage) -> FaceSignature? {
        let pixelSize = CGSize(width: image.size.width * image.scale,
                               height: image.size.height * image.scale)
        return signature(for: set, in: image, pixelSize: pixelSize)
    }

    private func signature(for set: FaceLandmarkSet, in image: UIImage,
                           pixelSize: CGSize) -> FaceSignature? {
        guard let embedder,
              let points = FaceAlignmentPoints.extract(from: set, in: pixelSize)
        else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let values = embedder.embedding(for: image,
                                              alignmentPoints: points.map { NSValue(cgPoint: $0) })
        else { return nil }
        return FaceSignature(rawValues: values.map { $0.floatValue })
    }
}
