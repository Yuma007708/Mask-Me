import Foundation

/// 検出キャッシュのキー。素材内の時刻でキーする。
///
/// 合成後の時刻でキーすると、クリップを1つ削除・並べ替えただけで
/// 後続クリップの時刻が全てずれ、検出済みの顔情報が全て無効になる。
/// 素材基準でキーすることで、分割・削除・並べ替えのいずれでも
/// 検出結果が失われない。
public struct DetectionCacheKey: Hashable, Sendable {
    public let sourceID: UUID
    /// 素材内での時刻を bucketFPS で丸めた値。
    public let bucket: Double

    public init(sourceID: UUID, bucket: Double) {
        self.sourceID = sourceID
        self.bucket = bucket
    }

    /// 素材内の生の時刻からキーを作る。時刻はバケットに丸められる。
    ///
    /// 丸めを init に閉じ込めることで、呼び出し側が丸め忘れて
    /// 別エントリを作ってしまう事故を防ぐ（過去にプリスキャンと
    /// ライブ検出でキーがずれ、同一時刻が2エントリに分裂した回帰がある）。
    public init(sourceID: UUID, time: Double, bucketFPS: Double) {
        self.sourceID = sourceID
        self.bucket = (time * bucketFPS).rounded() / bucketFPS
    }
}
