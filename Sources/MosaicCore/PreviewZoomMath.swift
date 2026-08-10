import CoreGraphics

/// プレビューのピンチズーム／パンの算術（純関数）。
///
/// `TimelineScrollMath`（`Sources/MosaicCore/Timeline/TimelineScrollMath.swift`）の形を
/// そのまま踏襲する: ジェスチャの値そのものではなく「アンカー保持」「可動域」を
/// 純関数へ切り出し、View 側には数式を持たせない。
///
/// タイムラインのズームと違い、画像のズームは**量子化しない**（連続値のまま使う）。
/// タイムラインは量子化しないと帯の再レイアウトが毎フレーム走るが、こちらは
/// 画像を再サンプリングし直す処理が無いため量子化の理由が無い。
public enum PreviewZoomMath {
    /// 最小倍率。fit より縮まない。
    public static let minimumScale: CGFloat = 1
    /// 最大倍率。
    public static let maximumScale: CGFloat = 8
    /// ダブルタップで拡大する側の倍率。
    public static let doubleTapScale: CGFloat = 3

    // MARK: - 倍率

    /// 倍率を `1...8` へ収める。非有限・0・負はすべて 1（等倍）へ倒す。
    public static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return minimumScale }
        return min(max(scale, minimumScale), maximumScale)
    }

    /// ピンチ倍率 → 新しい拡大率。
    ///
    /// **`magnification == 1` は `base` をビット同一で返す。** タイムライン側
    /// （`TimelineScrollMath.pixelsPerSecond`）が量子化で踏んだのと同じ罠が、
    /// クランプだけでも起こり得る（指を置いた瞬間、丸め誤差で倍率がわずかに動いて見える）。
    /// 非有限・0 以下の `magnification` は「倍率の情報が無い」として `base` をそのまま返す。
    public static func scale(base: CGFloat, magnification: CGFloat) -> CGFloat {
        guard magnification.isFinite, magnification > 0 else { return base }
        guard magnification != 1 else { return base }
        return clampedScale(base * magnification)
    }

    // MARK: - 可動域

    /// 指定倍率での平行移動の可動域（軸ごと、原点対称）。
    ///
    /// `fittedSize * scale` がコンテナを超えた分の半分。超えていない軸
    /// （レターボックス側）は 0 になり、中央に固定される。
    public static func maxOffset(scale: CGFloat, fittedSize: CGSize, containerSize: CGSize) -> CGSize {
        let safeScale = scale.isFinite ? scale : 0
        let width = sanitizedNonNegative(fittedSize.width) * safeScale
        let height = sanitizedNonNegative(fittedSize.height) * safeScale
        let containerWidth = sanitizedNonNegative(containerSize.width)
        let containerHeight = sanitizedNonNegative(containerSize.height)
        return CGSize(width: max(0, (width - containerWidth) / 2),
                      height: max(0, (height - containerHeight) / 2))
    }

    /// `offset` を `maxOffset` の範囲へクランプする。
    ///
    /// **ズームで観測可能な `offset` は必ずここを通すこと。** 呼び出し側が古い
    /// （倍率変更前の）値をそのまま保持していても、読み出し時にここを通せば
    /// 画像がコンテナの外へ飛んで見えることはない。
    public static func clampedOffset(_ offset: CGSize, scale: CGFloat,
                                     fittedSize: CGSize, containerSize: CGSize) -> CGSize {
        let bound = maxOffset(scale: scale, fittedSize: fittedSize, containerSize: containerSize)
        return CGSize(width: clampedComponent(offset.width, bound: bound.width),
                      height: clampedComponent(offset.height, bound: bound.height))
    }

    private static func clampedComponent(_ value: CGFloat, bound: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        guard bound.isFinite, bound > 0 else { return 0 }
        return min(max(value, -bound), bound)
    }

    private static func sanitizedNonNegative(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    // MARK: - アンカー保持

    /// 倍率変更の前後で、画面上の `anchorFromCenter`（コンテナ中心からの画面上の点）に
    /// 対応する画像上の点を変えないための、新しい `offset`（**クランプ前**）。
    ///
    /// 写像は「コンテナ中心 + offset + scale * (中心基準の fit 済み画像座標)」= 画面座標、
    /// という前提に立つ（`PreviewImageGeometry.imageRect` の作り方と一致させること）。
    /// アンカーの画像座標 `p` を旧倍率から逆算し、新倍率で同じ画面位置になる `offset` を解く:
    ///
    /// `p = (anchorFromCenter - previous) / oldScale`
    /// `newOffset = anchorFromCenter - newScale * p`
    ///
    /// クランプはここでは行わない（可動域はサイズに依存するため、呼び出し側が
    /// `clampedOffset` を続けて通すこと）。`oldScale` が 0 以下・非有限なら
    /// 逆算できないので `previous` をそのまま返す。
    public static func offsetKeepingAnchor(previous: CGSize, anchorFromCenter: CGSize,
                                           oldScale: CGFloat, newScale: CGFloat) -> CGSize {
        guard oldScale.isFinite, oldScale > 0, newScale.isFinite else { return previous }
        let ratio = newScale / oldScale
        let width = anchorFromCenter.width - ratio * (anchorFromCenter.width - previous.width)
        let height = anchorFromCenter.height - ratio * (anchorFromCenter.height - previous.height)
        guard width.isFinite, height.isFinite else { return previous }
        return CGSize(width: width, height: height)
    }

    // MARK: - ダブルタップ

    /// ダブルタップで 1 倍 ↔ 3 倍（`doubleTapScale`）をトグルする。
    ///
    /// **等倍でないときは常に等倍へ戻す**（ピンチで中途半端な倍率にした後の
    /// ダブルタップも「戻す」側として扱う。3 倍固定の往復だけを想定しない）。
    /// 拡大する側はアンカーを保ち、クランプ済みの `offset` を返す。
    public static func doubleTapped(_ current: PreviewZoom, anchorFromCenter: CGSize,
                                    fittedSize: CGSize, containerSize: CGSize) -> PreviewZoom {
        guard current.scale > minimumScale else {
            let rawOffset = offsetKeepingAnchor(previous: current.offset, anchorFromCenter: anchorFromCenter,
                                                oldScale: current.scale, newScale: doubleTapScale)
            let offset = clampedOffset(rawOffset, scale: doubleTapScale,
                                       fittedSize: fittedSize, containerSize: containerSize)
            return PreviewZoom(scale: doubleTapScale, offset: offset)
        }
        return .identity
    }
}
