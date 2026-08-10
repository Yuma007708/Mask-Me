import CoreGraphics
import Foundation

/// 物体マスクを「画面に描く矩形」まで解く純関数。
///
/// プレビュー 2 経路（`MosaicEditorModel.renderPreview` / `MosaicPreviewController`）と
/// エクスポート（`VideoMosaicExporter`）が**全てこれを通る**。
/// 絞り込み・補間・レイアウト写像の 3 つを書き写さないための単一情報源である
/// （顔側の `renderLayout.remap` + キャッシュ参照が経路ごとに散っていて、
/// 境界フレームで食い違う事故を繰り返した経緯がある）。
///
/// **適用区間ゲートと素材位置の解決はここに入れない。** どちらも呼び出し側が
/// 顔と共有している状態（`MosaicApplyGate` / `resolveSourceLocation` /
/// `VideoMosaicExporter.resolveLocation`）に依存しており、ここへ持ち込むと
/// 顔とマスクで判定が二重化する。
public enum ObjectMaskResolver {
    /// 解決済みの素材位置 1 箇所ぶんの矩形を、**合成フレーム基準**で返す。
    ///
    /// - Parameters:
    ///   - clipID: クランプ済みの解決結果。**この id のマスクだけを描く**
    ///     （絞り込まないとクリップ A に置いたマスクが B にも出る）。
    ///     nil は写像不能（クリップ未構築・写真モード・テストの直接注入）で、
    ///     そのときは `.still` のマスクだけを返す。
    ///   - sourceTime: その素材ブランチが検出キャッシュに使ったのと**同じ素材時刻**。
    ///     合成時刻を渡してはならない（rate ≠ 1 で補間位置がずれる）。
    ///   - layout: 素材フレーム基準 → 合成フレーム基準のレイアウト写像。
    ///   - tracks: 自動追跡の結果（マスク id 引き）。**キーフレームが一致する軌跡だけ**
    ///     が使われる（`ObjectTrack.matches(_:)`）。軌跡が無い時刻・古い軌跡は
    ///     キーフレーム補間へフォールバックする。
    public static func rects(_ masks: [ObjectMask], tracks: [UUID: ObjectTrack] = [:],
                             clipID: UUID?, sourceTime: Double,
                             layout: TimelineRenderLayout) -> [CGRect] {
        guard let clipID else {
            // 静止画編集には時間軸が無いので追跡もない。
            return masks.filter(\.anchor.isStill).map { $0.rect(atSourceTime: 0) }
        }
        return masks.filter { $0.anchor.clipID == clipID }
            .map { layout.remap(rect(of: $0, tracks: tracks, atSourceTime: sourceTime), clipID: clipID) }
    }

    /// 1 マスクぶんの**素材フレーム基準**の矩形。追跡を優先し、無ければキーフレーム補間。
    ///
    /// ここが「自動追跡とユーザーのキーフレームのどちらを採るか」を決める唯一の場所である。
    /// 軌跡は `ObjectTrackAssembler` のドリフト補正でキーフレームへ誤差ゼロで着地するため、
    /// **キーフレーム時刻では両者が一致する**（どちらを採っても同じ）。つまりここでの
    /// 「追跡優先」は、キーフレームとキーフレームの間を直線で結ぶか、実際の動きで結ぶかの
    /// 選択でしかなく、ユーザーの指定を上書きすることは無い。
    public static func rect(of mask: ObjectMask, tracks: [UUID: ObjectTrack],
                            atSourceTime sourceTime: Double) -> CGRect {
        if let track = tracks[mask.id], track.matches(mask),
           let tracked = track.rect(atSourceTime: sourceTime) {
            return tracked
        }
        return mask.rect(atSourceTime: sourceTime)
    }
}
