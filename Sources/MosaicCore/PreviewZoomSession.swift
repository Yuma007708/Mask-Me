import CoreGraphics

/// プレビューのピンチズーム／パン／ダブルタップのジェスチャ状態機械。
///
/// `PreviewZoomMath` の純関数を「ジェスチャの時系列」へ組み立てる層。View 側は
/// `MagnifyGesture` 等のコールバックをそのままここへ渡すだけにし、
/// アンカー保持・クランプ・「2 回目のピンチが現在倍率から始まる」といった
/// 状態の持ち方をここへ閉じ込める（`TimelineScrollContainer` がスクロール側で
/// 同じ役割を担っているのと同じ形）。
public struct PreviewZoomSession: Equatable, Sendable {
    /// 現在のズーム値（クランプ済み）。ピンチが終わっても保持される。
    public private(set) var zoom: PreviewZoom
    /// ピンチが指を置いてから離すまでの間かどうか。
    public private(set) var isActive: Bool

    /// ピンチ開始時点の倍率。`changed(magnification:)` はこれを `base` にする。
    ///
    /// **`began` の時点で `zoom.scale` を焼き込む。** `changed` が毎回
    /// `zoom.scale` を読み直す作りだと、`changed` 自身が `zoom` を更新するため
    /// 「今の倍率」と「ジェスチャ開始時の倍率」が同じ変数に混ざり、
    /// 2 回目以降のピンチが `magnification` をそのまま倍率として使ってしまう
    /// （＝指を置いた瞬間に絵が跳ぶ）。
    private var gestureBaseScale: CGFloat
    /// ピンチ開始時点の offset。パンのクランプ計算の起点。
    private var gestureBaseOffset: CGSize

    public init() {
        self.zoom = .identity
        self.isActive = false
        self.gestureBaseScale = 1
        self.gestureBaseOffset = .zero
    }

    /// ピンチ開始。**倍率の基準は現在の `zoom.scale`**（`reset()` 直後なら 1）。
    ///
    /// `anchorFromCenter` は今回このメソッドでは使わない（`changed` 側がアンカー保持を
    /// 都度計算するため）が、将来ジェスチャ開始位置を起点にする実装へ寄せられるよう
    /// シグネチャに残す（`PreviewZoomMath.offsetKeepingAnchor` と対称にするため）。
    public mutating func began(anchorFromCenter: CGSize) {
        _ = anchorFromCenter
        gestureBaseScale = zoom.scale
        gestureBaseOffset = zoom.offset
        isActive = true
    }

    /// ピンチ中の更新。`magnification` は `began` 時点からの累積倍率（1 が変化なし）。
    ///
    /// - Parameters:
    ///   - magnification: `MagnifyGesture` 相当の累積倍率。
    ///   - translation: `began` 時点からの累積パン量（pt）。
    ///   - fittedSize: `PreviewImageGeometry.fittedRect.size`。
    ///   - containerSize: プレビューのコンテナサイズ。
    public mutating func changed(magnification: CGFloat, translation: CGSize,
                                 fittedSize: CGSize, containerSize: CGSize) {
        let newScale = PreviewZoomMath.scale(base: gestureBaseScale, magnification: magnification)
        let rawOffset = CGSize(width: gestureBaseOffset.width + translation.width,
                               height: gestureBaseOffset.height + translation.height)
        let clamped = PreviewZoomMath.clampedOffset(rawOffset, scale: newScale,
                                                     fittedSize: fittedSize, containerSize: containerSize)
        zoom = PreviewZoom(scale: newScale, offset: clamped)
    }

    /// 指を離す。倍率・offset はそのまま残す（次の `began` の基準になる）。
    public mutating func ended() {
        isActive = false
    }

    /// ダブルタップ。1 倍 ↔ 3 倍のトグル。
    public mutating func doubleTapped(anchorFromCenter: CGSize, fittedSize: CGSize, containerSize: CGSize) {
        zoom = PreviewZoomMath.doubleTapped(zoom, anchorFromCenter: anchorFromCenter,
                                            fittedSize: fittedSize, containerSize: containerSize)
    }

    /// 等倍・非アクティブへ完全に戻す。
    public mutating func reset() {
        zoom = .identity
        isActive = false
        gestureBaseScale = 1
        gestureBaseOffset = .zero
    }
}
