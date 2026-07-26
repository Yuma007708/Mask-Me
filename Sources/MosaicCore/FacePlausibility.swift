import CoreGraphics
import Foundation

/// Geometric plausibility check that rejects spurious "faces" the landmarker
/// sometimes reports on non-face regions (e.g. a torso in dim light). Works on
/// the normalized landmark coordinates, so it needs no image size and is pure /
/// unit-testable. A set that fails this should be treated as "no face".
extension FaceLandmarkSet {
    /// Tunable bounds for what counts as a plausible human face.
    public enum Plausibility {
        /// Face bounding box (normalized) must be at least this on its larger side.
        public static let minSpan: CGFloat = 0.02          // 遠距離・広角ショットの小さい顔を拾えるよう緩和
        /// …and no larger than this (a real face never exceeds the frame much).
        public static let maxSpan: CGFloat = 1.6
        /// Face height / width (**正規化座標**) must fall in this range.
        /// 画像サイズが分からない呼び出し（`isPlausibleFace` の引数なし版など）専用の
        /// フォールバック。正規化比には動画・写真のアスペクト比がそのまま混入するので
        /// （16:9 横長なら正方形の顔が h/w≈1.78、9:16 縦長なら h/w≈0.56 になる）、
        /// 素材の向きを問わず通す必要があり、この幅では体誤フィットをほとんど弾けない。
        /// **画像サイズが分かるなら必ず `pixelAspectRange` 側を使うこと。**
        public static let aspectRange: ClosedRange<CGFloat> = 0.4...3.0
        /// Face height / width (**ピクセル換算**) の主ゲート。素材のアスペクト比が
        /// 除かれるので、実顔の形そのものを判定できる。
        /// 実測（probe 静止画 24 枚 + 実素材クリップ 12 本の全採用検出）では
        /// ピクセル h/w は 0.80〜1.40 に収まった。roll した顔（軸平行 bbox が正方形〜
        /// 横長になる）と横顔（幅が縮んで縦長になる）に十分な余裕を残しつつ、
        /// 体・首・胸への縦長フィット（実測 2.5 以上）を弾ける値として 0.5...2.0 を採る。
        /// `maxPixelAspect`(1.4) は低 confidence 救済経路専用のより厳しい体ゲートで、
        /// 本レンジは全経路が通る主ゲートなので意図的に緩く取っている。
        public static let pixelAspectRange: ClosedRange<CGFloat> = 0.5...2.0
        /// Inter-ocular distance / face width must fall in this range.
        public static let eyeWidthRatioRange: ClosedRange<CGFloat> = 0.10...0.95  // 斜め向きの顔を許容するよう緩和
        /// ピクセル換算の顔 bbox 縦横比 (h/w) の上限。実顔の oval はピクセル座標で
        /// h/w ≈ 1.1〜1.4 に収まり、これを超える縦長フィットは首・胸・体への
        /// 誤フィット（low-confidence 走査で頻発）とみなして棄却する。
        /// DValid ライブ経路検証（bright/dim/backlight/beach 20本）の bodyFP 判定と同値。
        public static let maxPixelAspect: CGFloat = 1.4
    }

    /// 顔 oval bbox のピクセル換算縦横比 (h/w) を返す。正規化座標の縦横比には
    /// 動画自体のアスペクト比が混入する（16:9 横長動画では正方形の顔が h/w≈1.78
    /// になる）ため、体誤検知の判定は必ずこのピクセル換算値で行うこと。
    /// oval が退化している場合は nil。
    public func pixelAspectRatio(in imageSize: CGSize) -> CGFloat? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let oval = polygon(for: .faceOval, in: imageSize)
        guard oval.count >= 3 else { return nil }
        var minX = oval[0].x, maxX = oval[0].x
        var minY = oval[0].y, maxY = oval[0].y
        for point in oval.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0 else { return nil }
        return height / width
    }

    /// 低 confidence 救済経路専用の体形状ゲート。ピクセル換算 h/w が
    /// `Plausibility.maxPixelAspect` を超える縦長フィットを「体」と判定する。
    public func isBodyLikeShape(in imageSize: CGSize) -> Bool {
        guard let aspect = pixelAspectRatio(in: imageSize) else { return true }
        return aspect > Plausibility.maxPixelAspect
    }

    /// 体誤フィット検証（タイト crop 再検出）に回すべき「疑わしい候補」かどうか。
    /// 画面下半分（`midY > suspectMidY`）は従来どおり位置で疑う。
    /// それに加えて、画面上半分でも縦長の体誤フィット形状（`isBodyLikeShape`）なら疑わしいと
    /// 判定する。位置だけで判定すると、体・首・肩への誤フィットが画面上部で起きたときに
    /// 検証パスをすり抜けてしまうため。
    public func isSuspectBodyRegion(in imageSize: CGSize, suspectMidY: CGFloat) -> Bool {
        boundingBox.midY > suspectMidY || isBodyLikeShape(in: imageSize)
    }

    /// `true` when the landmarks form a geometrically plausible face.
    /// Uses the static `Plausibility` defaults — call `isPlausibleFace(minSpan:eyeRatioRange:)`
    /// to override them with user-defined settings.
    public var isPlausibleFace: Bool {
        isPlausibleFace(minSpan: Plausibility.minSpan,
                        eyeRatioRange: Plausibility.eyeWidthRatioRange)
    }

    /// Parameterized variant — used by `MediaPipeFaceLandmarkerAdapter` to apply
    /// user-configured `DetectionSettings` without coupling MosaicCore to the app layer.
    public func isPlausibleFace(
        minSpan: CGFloat,
        eyeRatioRange: ClosedRange<CGFloat>,
        imageSize: CGSize? = nil
    ) -> Bool {
        plausibilityScore(minSpan: minSpan,
                          eyeRatioRange: eyeRatioRange,
                          imageSize: imageSize) > 0
    }

    /// 縦横比ゲート。画像サイズが分かるならピクセル換算で判定する（正規化比には
    /// 素材のアスペクト比が混入し、縦長素材と横長素材で同じ形の顔が別の値になるため）。
    /// - Parameter normalizedAspect: 正規化座標での顔 oval bbox の h/w。
    static func passesAspectGate(_ normalizedAspect: CGFloat, imageSize: CGSize?) -> Bool {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return Plausibility.aspectRange.contains(normalizedAspect)
        }
        let pixelAspect = normalizedAspect * imageSize.height / imageSize.width
        return Plausibility.pixelAspectRange.contains(pixelAspect)
    }

    /// 幾何学的妥当性を 0...1 の連続スコアで返す。0 は完全棄却、1 は正面 478点顔。
    /// `eyeRatioRange` の下限を下回った境界顔（横顔・小顔）は完全棄却ではなく低スコアで
    /// 残し、`LandmarkSmoother`/`DetectionBridge`/`TrackingEvaluator` の EMA が均せる。
    /// 完全に棄却する条件: 面数不足、span/aspect の物理的破綻、目が口より下（顔向き逆）。
    /// - Parameter imageSize: 元画像のピクセルサイズ。渡すと縦横比ゲートを
    ///   ピクセル換算（`Plausibility.pixelAspectRange`）で判定する。`nil` のときだけ
    ///   素材アスペクト比が混入する正規化比（`Plausibility.aspectRange`）に退避する。
    public func plausibilityScore(
        minSpan: CGFloat,
        eyeRatioRange: ClosedRange<CGFloat>,
        imageSize: CGSize? = nil
    ) -> Float {
        let unit = CGSize(width: 1, height: 1)
        let oval = polygon(for: .faceOval, in: unit)
        guard oval.count >= 3 else { return 0 }
        guard points.count > Self.leftEyeOuterIndex else { return 0 }

        var minX = oval[0].x, maxX = oval[0].x
        var minY = oval[0].y, maxY = oval[0].y
        for point in oval.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return 0 }

        let span = max(width, height)
        guard span >= minSpan, span <= Plausibility.maxSpan else { return 0 }

        guard Self.passesAspectGate(height / width, imageSize: imageSize) else { return 0 }

        let rightEye = points[Self.rightEyeOuterIndex].point(in: unit)
        let leftEye = points[Self.leftEyeOuterIndex].point(in: unit)
        let eyeDistance = hypot(leftEye.x - rightEye.x, leftEye.y - rightEye.y)
        let eyeRatio = eyeDistance / width

        // Eyes must sit above the mouth (image y grows downward). この幾何は妥協しない。
        let mouth = polygon(for: .lips, in: unit)
        guard mouth.count >= 3 else { return 0 }
        let mouthY = mouth.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(mouth.count)
        let eyeY = (rightEye.y + leftEye.y) / 2
        guard eyeY < mouthY else { return 0 }

        // 目間比のソフトマージン: 下限をわずかに割った候補は 0.3〜1.0 のスコアで残し、
        // 大きく外れた（下限×0.6 未満）候補は完全棄却する。
        if eyeRatioRange.contains(eyeRatio) {
            return 1.0
        }
        let softLower = eyeRatioRange.lowerBound * 0.6
        if eyeRatio < softLower { return 0 }
        // 線形補間: softLower → 0.3、lowerBound → 1.0
        let t = (eyeRatio - softLower) / (eyeRatioRange.lowerBound - softLower)
        return Float(max(0.3, min(1.0, 0.3 + 0.7 * t)))
    }
}
