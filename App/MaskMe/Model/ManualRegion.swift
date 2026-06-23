import CoreGraphics
import Foundation

/// ユーザーが手動で指定した矩形領域。画像座標系で正規化（0-1）。
/// ドラッグ完了時に検出を試み、成功すれば FaceTarget に昇格される。
/// 検出失敗時はそのまま矩形マスクとして使われる。
public struct ManualRegion: Identifiable {
    public let id: UUID
    public var normalizedRect: CGRect

    public init(id: UUID, normalizedRect: CGRect) {
        self.id = id
        self.normalizedRect = normalizedRect
    }
}
