import CoreGraphics
import Foundation

/// クロップ枠の 8 つのハンドル＋内側ドラッグ。
public enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside
}

/// クロップ矩形のドラッグ幾何。**View には一切この計算を書かせない**——
/// View は `PreviewImageGeometry` で画面 pt ⇔ 正規化の換算をするだけで、
/// 「どのハンドルを掴んだらどう形が変わるか」はここへ全部集約する。
///
/// ## 幾何の契約（崩さないこと）
///
/// 1. **正規化空間には異方性がある。** `CropAspectLock.pixelRatio(inFrame:)` の doc 参照。
///    比率固定は必ず `r * H/W` の 1 本の式（`Self.normalizedRatio`）を通す。
/// 2. **対辺固定**: 角ハンドルは対角の角、辺ハンドルは対辺が、入力の `crop.rect` の
///    値から**演算を経由せず**そのままコピーされる（浮動小数の丸めで 1bit も動かない）。
/// 3. **反転しない**: 掴んだ辺・角は `CropRect.minimumSide` を割り込む前に止まる。
///    負の幅を作って `standardized` に拾わせる、という手は使わない。
/// 4. **枠内クランプ**: 結果は必ず `[0,1]²` に収まる合法な矩形を、この関数自身が
///    組み立てる。`CropRect.init(rect:)` のクランプへ依存しない
///    （依存すると、比率固定時にクランプが比率を黙って崩す）。
/// 5. **比率固定の縮退規則**: 目標比率・固定点・`minimumSide`・枠内、の 4 条件を
///    満たす最大の矩形を返す。角・辺ハンドルは「固定点から、ドラッグが指した
///    向きへどこまで伸ばせるか」の箱（`boxWidth`×`boxHeight`）に収まる最大比率矩形
///    （`fittedSize(boxWidth:boxHeight:ratio:)`）。比率選び直し（`applying`）は
///    中心を固定点にした対称な箱（`largestFitting(anchor:ratio:inFrame:)`）。
///    どちらも「その箱に収まる最大」を計算するだけの共通ロジックへ集約してあり、
///    テストへ手順を書き写させない。
/// 6. **内側ドラッグは大きさをビット同一で保つ。** 幅・高さは `crop.rect` の値を
///    そのまま使い、原点だけを枠内へクランプする。
/// 7. **偶数スナップはここではやらない**（`CropRect.snappedRect(inFrame:)` の責務）。
///    既知のトレードオフ: 小さな枠で 16:9 等を選ぶと、スナップ後に ±1px 比率が
///    ずれることがある。
/// 8. `CropRect.minimumSide` を再定義しない。常に `CropRect.minimumSide` を参照する。
public enum CropHandleMath {
    /// ハンドルをドラッグした結果の新しいクロップ矩形。
    ///
    /// - Parameter translation: **正規化枠に対する**移動量。View は
    ///   `PreviewImageGeometry` で画面 pt の移動量を正規化へ換算してから渡すこと。
    /// - Parameter crop: ドラッグ開始時点の（変化しない）クロップ。呼び出し側は
    ///   ドラッグ中、開始時点の `crop` と累積 `translation` をこの関数へ毎回渡す
    ///   （逐次積算しない）。逐次積算すると、丸め誤差が蓄積し「対辺固定」が
    ///   じわじわ壊れる。
    public static func dragged(_ crop: CropRect, handle: CropHandle, by translation: CGSize,
                               lock: CropAspectLock, inFrame frame: CGSize) -> CropRect {
        let raw = rawCandidate(crop, handle: handle, translation: translation)
        guard handle != .inside,
              let pixelRatio = lock.pixelRatio(inFrame: frame),
              let ratio = normalizedRatio(pixelRatio: pixelRatio, inFrame: frame) else {
            return CropRect(rect: raw)
        }
        return CropRect(rect: constrainedRect(crop, handle: handle, translation: translation, ratio: ratio))
    }

    /// 比率を選び直した／リセットしたときの矩形。**中心を保った枠内最大**。
    ///
    /// `lock` が `.free`（比率制約なし）のときは、制約なしでの「最大」が
    /// 出力枠全体そのものになるため `.full` を返す（リセットの意味も兼ねる）。
    public static func applying(_ lock: CropAspectLock, to crop: CropRect, inFrame frame: CGSize) -> CropRect {
        guard let pixelRatio = lock.pixelRatio(inFrame: frame),
              let ratio = normalizedRatio(pixelRatio: pixelRatio, inFrame: frame) else {
            return .full
        }
        let anchor = CGPoint(x: crop.rect.midX, y: crop.rect.midY)
        return largestFitting(anchor: anchor, ratio: ratio, inFrame: frame)
    }

    // MARK: - 比率選び直し（中心固定・対称）

    /// アンカーを中心に、`[0,1]²` へ収まる最大の `ratio` 矩形。
    private static func largestFitting(anchor: CGPoint, ratio: CGFloat, inFrame frame: CGSize) -> CropRect {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return .full }
        let boxWidth = 2 * min(anchor.x, 1 - anchor.x)
        let boxHeight = 2 * min(anchor.y, 1 - anchor.y)
        var fitted = fittedSize(boxWidth: boxWidth, boxHeight: boxHeight, ratio: ratio)
        fitted = bumpToMinimum(fitted, ratio: ratio)
        let rect = CGRect(x: anchor.x - fitted.width / 2, y: anchor.y - fitted.height / 2,
                          width: fitted.width, height: fitted.height)
        return CropRect(rect: rect)
    }

    // MARK: - ドラッグ（比率制約なし）

    /// ハンドルごとの素朴な候補矩形。比率制約は掛けない。
    /// **対辺・対角は演算を経由せず、入力の値をそのまま流用する**（bit 同一の根拠）。
    private static func rawCandidate(_ crop: CropRect, handle: CropHandle, translation: CGSize) -> CGRect {
        let rect = crop.rect
        let minSide = CropRect.minimumSide
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY

        switch handle {
        case .topLeft:
            minX = clamp(rect.minX + translation.width, 0, maxX - minSide)
            minY = clamp(rect.minY + translation.height, 0, maxY - minSide)
        case .top:
            minY = clamp(rect.minY + translation.height, 0, maxY - minSide)
        case .topRight:
            maxX = clamp(rect.maxX + translation.width, minX + minSide, 1)
            minY = clamp(rect.minY + translation.height, 0, maxY - minSide)
        case .right:
            maxX = clamp(rect.maxX + translation.width, minX + minSide, 1)
        case .bottomRight:
            maxX = clamp(rect.maxX + translation.width, minX + minSide, 1)
            maxY = clamp(rect.maxY + translation.height, minY + minSide, 1)
        case .bottom:
            maxY = clamp(rect.maxY + translation.height, minY + minSide, 1)
        case .bottomLeft:
            minX = clamp(rect.minX + translation.width, 0, maxX - minSide)
            maxY = clamp(rect.maxY + translation.height, minY + minSide, 1)
        case .left:
            minX = clamp(rect.minX + translation.width, 0, maxX - minSide)
        case .inside:
            let width = rect.width, height = rect.height
            minX = clamp(rect.minX + translation.width, 0, 1 - width)
            minY = clamp(rect.minY + translation.height, 0, 1 - height)
            return CGRect(x: minX, y: minY, width: width, height: height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - ドラッグ（比率固定）

    /// 比率固定でのドラッグ結果。角ハンドルは対角、辺ハンドルは対辺が固定点で、
    /// そこから `rawCandidate` が指す向き・距離を「箱」として、その箱に収まる
    /// 最大の `ratio` 矩形を作る。辺ハンドルは交差軸を元のクロップの中心線
    /// （`rect.midX` / `rect.midY`）に対称に伸ばす——ドラッグしていない軸には
    /// 「対辺固定」に相当する単一の基準点が無いため、最も驚きの少ない基準として
    /// 交差軸の中心を採用した（このファイル固有の設計判断。他の 7 条件のような
    /// 外部確定仕様ではない）。
    private static func constrainedRect(_ crop: CropRect, handle: CropHandle,
                                        translation: CGSize, ratio: CGFloat) -> CGRect {
        let rect = crop.rect
        let raw = rawCandidate(crop, handle: handle, translation: translation)

        switch handle {
        case .inside:
            return raw // 呼び出し側で除外済み（安全側のフォールバック）。

        case .topLeft:
            return cornerRect(fixed: CGPoint(x: rect.maxX, y: rect.maxY),
                              reaching: CGPoint(x: raw.minX, y: raw.minY), ratio: ratio)
        case .topRight:
            return cornerRect(fixed: CGPoint(x: rect.minX, y: rect.maxY),
                              reaching: CGPoint(x: raw.maxX, y: raw.minY), ratio: ratio)
        case .bottomRight:
            return cornerRect(fixed: CGPoint(x: rect.minX, y: rect.minY),
                              reaching: CGPoint(x: raw.maxX, y: raw.maxY), ratio: ratio)
        case .bottomLeft:
            return cornerRect(fixed: CGPoint(x: rect.maxX, y: rect.minY),
                              reaching: CGPoint(x: raw.minX, y: raw.maxY), ratio: ratio)

        case .top:
            return edgeRect(fixedY: rect.maxY, reachingY: raw.minY, crossCenter: rect.midX,
                            fixedYIsMax: true, ratio: ratio)
        case .bottom:
            return edgeRect(fixedY: rect.minY, reachingY: raw.maxY, crossCenter: rect.midX,
                            fixedYIsMax: false, ratio: ratio)
        case .left:
            return edgeRectHorizontal(fixedX: rect.maxX, reachingX: raw.minX, crossCenter: rect.midY,
                                      fixedXIsMax: true, ratio: ratio)
        case .right:
            return edgeRectHorizontal(fixedX: rect.minX, reachingX: raw.maxX, crossCenter: rect.midY,
                                      fixedXIsMax: false, ratio: ratio)
        }
    }

    /// 角ハンドル: `fixed` が対角の固定点、`reaching` が `rawCandidate` の動く角。
    private static func cornerRect(fixed: CGPoint, reaching: CGPoint, ratio: CGFloat) -> CGRect {
        let boxWidth = abs(reaching.x - fixed.x)
        let boxHeight = abs(reaching.y - fixed.y)
        var fitted = fittedSize(boxWidth: boxWidth, boxHeight: boxHeight, ratio: ratio)
        fitted = bumpToMinimum(fitted, ratio: ratio)

        let minX = reaching.x < fixed.x ? fixed.x - fitted.width : fixed.x
        let minY = reaching.y < fixed.y ? fixed.y - fitted.height : fixed.y
        return CGRect(x: minX, y: minY, width: fitted.width, height: fitted.height)
    }

    /// 上下ハンドル: `fixedY` が対辺（固定）、`reachingY` がドラッグ後の辺の位置、
    /// 横方向は `crossCenter` を中心に対称に伸ばす。
    private static func edgeRect(fixedY: CGFloat, reachingY: CGFloat, crossCenter: CGFloat,
                                 fixedYIsMax: Bool, ratio: CGFloat) -> CGRect {
        let boxHeight = abs(reachingY - fixedY)
        let boxWidth = 2 * min(crossCenter, 1 - crossCenter)
        var fitted = fittedSize(boxWidth: boxWidth, boxHeight: boxHeight, ratio: ratio)
        fitted = bumpToMinimum(fitted, ratio: ratio)

        let minY = fixedYIsMax ? fixedY - fitted.height : fixedY
        return CGRect(x: crossCenter - fitted.width / 2, y: minY,
                      width: fitted.width, height: fitted.height)
    }

    /// 左右ハンドル: `fixedX` が対辺（固定）、`reachingX` がドラッグ後の辺の位置、
    /// 縦方向は `crossCenter` を中心に対称に伸ばす。
    private static func edgeRectHorizontal(fixedX: CGFloat, reachingX: CGFloat, crossCenter: CGFloat,
                                           fixedXIsMax: Bool, ratio: CGFloat) -> CGRect {
        let boxWidth = abs(reachingX - fixedX)
        let boxHeight = 2 * min(crossCenter, 1 - crossCenter)
        var fitted = fittedSize(boxWidth: boxWidth, boxHeight: boxHeight, ratio: ratio)
        fitted = bumpToMinimum(fitted, ratio: ratio)

        let minX = fixedXIsMax ? fixedX - fitted.width : fixedX
        return CGRect(x: minX, y: crossCenter - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    // MARK: - 共通の「箱に収まる最大」

    /// `boxWidth × boxHeight` の箱に収まる、`ratio`（w/h）の最大の矩形の寸法。
    /// 古典的な aspect-fit。**この 1 関数だけが「最大」の実体**（角・辺・比率選び直しの
    /// 3 経路が共通で通る）。
    private static func fittedSize(boxWidth: CGFloat, boxHeight: CGFloat, ratio: CGFloat) -> CGSize {
        guard boxWidth.isFinite, boxHeight.isFinite, boxWidth > 0, boxHeight > 0,
              ratio.isFinite, ratio > 0 else { return .zero }
        if boxWidth / ratio <= boxHeight {
            return CGSize(width: boxWidth, height: boxWidth / ratio)
        }
        return CGSize(width: boxHeight * ratio, height: boxHeight)
    }

    /// `minimumSide` を割り込んだ寸法を、比率を保ったまま両辺とも
    /// `minimumSide` 以上へ引き上げる。
    ///
    /// 呼び出し側の「固定点からフレーム境界までの距離」は、固定点が常に
    /// 直前の合法なクロップの角／辺だったことから `CropRect.minimumSide` 以上
    /// 保証されている（`crop.rect` は常に minimumSide 以上の辺を持つため）。
    /// そのためここでの引き上げが枠外へはみ出すことは無い
    /// （最終的に `CropRect(rect:)` を通すので、万一の丸め誤差はそこで拾われる）。
    private static func bumpToMinimum(_ size: CGSize, ratio: CGFloat) -> CGSize {
        let minSide = CropRect.minimumSide
        guard size.width < minSide || size.height < minSide else { return size }
        let byHeight = CGSize(width: minSide * ratio, height: minSide)
        if byHeight.width >= minSide { return byHeight }
        return CGSize(width: minSide, height: minSide / ratio)
    }

    // MARK: - 比率の異方性補正

    /// `CropAspectLock.pixelRatio(inFrame:)` の doc にある `r * H/W` を実体化したもの。
    private static func normalizedRatio(pixelRatio: CGFloat, inFrame frame: CGSize) -> CGFloat? {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              pixelRatio.isFinite, pixelRatio > 0 else { return nil }
        return pixelRatio * frame.height / frame.width
    }

    // MARK: -

    private static func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        guard value.isFinite else { return lo }
        guard lo <= hi else { return lo }
        return min(max(value, lo), hi)
    }
}
