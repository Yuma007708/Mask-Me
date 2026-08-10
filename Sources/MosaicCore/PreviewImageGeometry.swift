import CoreGraphics

/// プレビュー領域（`scaledToFit` 表示）の中で画像が実際に占める矩形と、
/// 画面座標 ⇄ 画像の正規化座標の変換。
///
/// **プレビューに何かを重ねるビューは必ずここを通す。** 同じ換算を各ビューが
/// 自前で持つと、片方だけ直したときに「矩形は正しい位置なのに顔の枠だけずれる」
/// という、画面の上では原因の分からない食い違いになる。
///
/// 画像が無いとき（読み込み中）はコンテナ全体を画像とみなす。変換が破綻するより、
/// 素通しにして「画像が出てから正しくなる」方が扱いやすい。
public struct PreviewImageGeometry: Equatable, Sendable {
    public let containerSize: CGSize
    /// 表示している画像の実寸。nil ならコンテナ全体を使う。
    public let imageSize: CGSize?

    public init(containerSize: CGSize, imageSize: CGSize?) {
        self.containerSize = containerSize
        self.imageSize = imageSize
    }

    /// コンテナ内で画像が占める矩形（レターボックス込み）。
    public var imageRect: CGRect {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width,
                        containerSize.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (containerSize.width - fitted.width) / 2,
                      y: (containerSize.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// 正規化座標 → 画面座標。
    public func screenRect(from normalized: CGRect) -> CGRect {
        let rect = imageRect
        return CGRect(x: rect.origin.x + normalized.origin.x * rect.width,
                      y: rect.origin.y + normalized.origin.y * rect.height,
                      width: normalized.width * rect.width,
                      height: normalized.height * rect.height)
    }

    /// 画面座標 → 正規化座標。**画像の外へはみ出した分は切り落とす。**
    ///
    /// 交差が空になる（画像の外だけを指した）ときは `.null` ではなく原点の
    /// 潰れた矩形を返す。`.null` は `origin` が無限大で、そのまま計算に混ぜると
    /// NaN が伝播して呼び出し側が黙って壊れる。
    public func normalizedRect(from screen: CGRect) -> CGRect {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        let clipped = screen.intersection(rect)
        guard !clipped.isNull, !clipped.isInfinite else { return .zero }
        return CGRect(x: (clipped.origin.x - rect.origin.x) / rect.width,
                      y: (clipped.origin.y - rect.origin.y) / rect.height,
                      width: clipped.width / rect.width,
                      height: clipped.height / rect.height)
    }

    /// 画面座標 → 正規化座標（点）。**画像の外は nil**。
    ///
    /// クランプして返さないのは、タップの当たり判定に使うため。レターボックスの
    /// 黒帯を押したときに端の座標へ丸めると、画像の端に居る顔が誤って選ばれる。
    public func normalizedPoint(from screen: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(screen) else { return nil }
        return CGPoint(x: (screen.x - rect.origin.x) / rect.width,
                       y: (screen.y - rect.origin.y) / rect.height)
    }

    /// 正規化座標（点） → 画面座標。`normalizedPoint(from:)` の逆写像。
    ///
    /// **テキスト（`TextItem.center`）のドラッグ配置が通る唯一の換算。** 表示枠と
    /// 出力枠のアスペクト比が違う（レターボックス）場合でも `imageRect` を経由するため
    /// `screenRect(from:)` と一致する換算になる。ここではクランプしない（呼び出し側が
    /// ドラッグ中の下書きをそのまま見せたいことがあるため。確定時のクランプは
    /// `NormalizedPoint.clamped` / `TimelineState.settingTextCenter` が担う）。
    public func screenPoint(from normalized: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.origin.x + normalized.x * rect.width,
                       y: rect.origin.y + normalized.y * rect.height)
    }

    /// 画面座標 → 正規化座標（点）。`normalizedPoint(from:)` と違い、**画像の外でも nil にせず
    /// そのまま返す**（0...1 の外に出ることがある）。
    ///
    /// テキストのドラッグ確定はこちらを使うこと。指を離した位置が画像の外（レターボックスの
    /// 黒帯や画面端）でも「見失って永久に掴めなくなる」ことがないよう、呼び出し側
    /// （`TimelineState.settingTextCenter` → `NormalizedPoint.clamped`）が最終的に 0...1 へ
    /// 収める前提で、ここでは丸めない生値を返す。`normalizedPoint(from:)` はタップの当たり判定
    /// （＝画像の外を押したら無視したい）に使うので用途が異なる。
    public func rawNormalizedPoint(from screen: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(x: (screen.x - rect.origin.x) / rect.width,
                       y: (screen.y - rect.origin.y) / rect.height)
    }
}
