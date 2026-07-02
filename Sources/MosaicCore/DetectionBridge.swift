import Foundation

/// 検出キャッシュ（時刻 → 検出顔リスト）から任意時刻の顔を引く「両側補間」ロジック。
///
/// もともと `MosaicEditorModel.lookupFaces` と `VideoMosaicExporter.lookupCache` に
/// ほぼ同一実装が重複していたものを共通化した。プレビュー・エクスポート・精度計測
/// （DValidVideoTests の bridgedRate）の3者が必ず同じ補間挙動になるよう、変更は
/// ここに集約する。
///
/// 挙動: 指定時刻に検出があればそれを返す。無ければ前後 `bridgeWindow` 秒以内の
/// 両側に検出がある「一時的な検出抜け」のみ直近フレームで補間する。片側にしか
/// 検出が無い場合（顔がフレームアウト／インする境界）は空を返す。さらに両側に
/// 検出があっても、before の顔が after に IoU > 0.3 で対応しない場合（アウト前の
/// 位置と別の場所に再入場した場合）は補間しない。アウト位置にモザイクが貼り付いた
/// ままになる事故を防ぐため。
public struct DetectionBridge: Sendable {
    /// ブリッジする最大の時間ギャップ（秒）。15fps プリスキャン基準で
    /// 8 フレーム ≒ 0.53 秒が既定（[DVALFRAME] タイムラインのオフラインスイープで、
    /// 5/15 → 8/15 拡大は IoU 連続性ゲートを維持したまま s3/s4 で +2〜3.4pp の
    /// 追従率上積みが得られ、これ以上広げると誤ブリッジ疑いが急増すると確認済み）。
    /// これより長い抜けは「顔自体が画面外にいる」可能性が高いので外挿しない。
    public var bridgeWindow: Double
    /// true のとき、ブリッジした顔を before の座標のまま返す（ホールド）のではなく、
    /// after 側の対応顔へ経過時間比で点単位に線形補間して返す。位置がなめらかに遷移する。
    /// 対応顔と点数が一致しないペアはホールドにフォールバック。
    public var interpolates: Bool

    public init(bridgeWindow: Double = 8.0 / 15.0, interpolates: Bool = false) {
        self.bridgeWindow = bridgeWindow
        self.interpolates = interpolates
    }

    /// `cache` から時刻 `time` の顔リストを返す。
    public func faces(in cache: [Double: [FaceLandmarkSet]], at time: Double) -> [FaceLandmarkSet] {
        if let exact = cache[time], !exact.isEmpty { return exact }
        var before: (dist: Double, faces: [FaceLandmarkSet])?
        var after: (dist: Double, faces: [FaceLandmarkSet])?
        for (t, faces) in cache where !faces.isEmpty {
            let d = abs(t - time)
            guard d <= bridgeWindow else { continue }
            if t <= time {
                if before == nil || d < before!.dist { before = (d, faces) }
            } else {
                if after == nil || d < after!.dist { after = (d, faces) }
            }
        }
        guard let before, let after else { return [] }
        // before の顔のうち、after にも「同じ位置 (IoU > 0.3)」で対応する顔があるものだけ補間に使う。
        // 対応しない顔（アウト前の位置のまま、インでは別の場所に出た）は除外。
        if interpolates {
            let denom = before.dist + after.dist
            let alpha = denom > 0 ? Float(before.dist / denom) : 0
            return before.faces.compactMap { face in
                guard let match = face.counterpart(in: after.faces) else { return nil }
                return face.interpolated(to: match, alpha: alpha)
            }
        }
        return before.faces.filter { $0.hasCounterpart(in: after.faces) }
    }
}
