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
/// 「画面のここに、この傾きで描く」まで解けた物体マスク 1 個。
///
/// 矩形と角度を**別々に返さない**のは、呼び出し側が 2 本の配列を添字で突き合わせる
/// ことになり、片方だけ絞り込んだ瞬間に別のマスクの角度を使うため。
public struct ObjectMaskPlacement: Equatable, Sendable {
    /// 合成フレーム基準の正規化矩形。
    public let rect: CGRect
    /// **ピクセル空間での**傾き（ラジアン、時計回り）。
    ///
    /// レターボックスの配置写像だけなら角度は変わらない。あの写像は正規化空間では
    /// 縦横で別々の倍率になるが、ピクセル空間で見ると素材の縦横比を保った等方の
    /// 拡大縮小だからである（`TimelineRenderLayout.remap` の doc）。
    /// **ただしクリップの向き（`ClipOrientation`）は角度を変える**ので、
    /// `TimelineRenderLayout.remapAngle` を必ず通すこと（90 度回すと矩形の傾きも
    /// 90 度回らなければ、傾けた矩形が素材からずれて素通しになる）。
    /// **アスペクト比を変える配置を許すようになったら、そこでも角度を写す必要がある。**
    public let angle: Double

    public init(rect: CGRect, angle: Double) {
        self.rect = rect
        self.angle = angle
    }
}

/// 物体マスクが「いま追えているか」の状態。UI が枠の線種・ラベルを選ぶために使う。
///
/// **`ObjectTrack.rect(atSourceTime:) != nil` を「追跡中」と読んではいけない。**
/// 末尾・先頭の clamp（`ObjectTrack.rect(atSourceTime:)` の doc）は、追跡が終わった後も
/// 最後の位置を返し続けるので非 nil になる。素朴に実装すると「追跡が止まっているのに
/// ずっと追跡中と表示される」。**セグメントに含まれるか**で判定すること
/// （`ObjectMaskResolver.resolve` の判定順を参照）。
public enum ObjectMaskFollowState: Equatable, Sendable {
    /// 静止画編集の固定マスク。追跡の概念が無い。
    case fixed
    /// 軌跡が最新で、いまの時刻がその軌跡のセグメント内。
    case tracking
    /// 軌跡が無い/古いが、そのクリップの追跡タスクが走行中。
    case computing
    /// 上記以外（セグメントの穴・末尾 clamp・軌跡なしでタスクも無し）。
    case untracked
}

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
    public static func placements(_ masks: [ObjectMask], tracks: [UUID: ObjectTrack] = [:],
                                  clipID: UUID?, sourceTime: Double,
                                  layout: TimelineRenderLayout) -> [ObjectMaskPlacement] {
        guard let clipID else {
            // 静止画編集には時間軸が無いので追跡もない。
            return masks.filter(\.anchor.isStill).map {
                ObjectMaskPlacement(rect: $0.rect(atSourceTime: 0), angle: $0.angle(atSourceTime: 0))
            }
        }
        return masks.filter { $0.anchor.clipID == clipID }.map { mask in
            ObjectMaskPlacement(
                rect: layout.remap(rect(of: mask, tracks: tracks, atSourceTime: sourceTime),
                                   clipID: clipID),
                // **角度は追跡ではなくキーフレームから採る。** 追跡（オプティカルフロー）は
                // 矩形の平行移動しか追わないので、角度を持っていない。被写体が回り込んでも
                // 傾きは置いたときのまま固定される（この割り切りはユーザー合意済み）。
                // **クリップの向きだけは写す**（矩形と角度が別々の空間になるのを防ぐ）。
                angle: layout.remapAngle(mask.angle(atSourceTime: sourceTime), clipID: clipID))
        }
    }

    /// 1 マスクぶんの**素材フレーム基準**の矩形。追跡を優先し、無ければキーフレーム補間。
    ///
    /// ここが「自動追跡とユーザーのキーフレームのどちらを採るか」を決める唯一の場所である。
    /// 軌跡は `ObjectTrackAssembler` のドリフト補正でキーフレームへ誤差ゼロで着地するため、
    /// **キーフレーム時刻では両者が一致する**（どちらを採っても同じ）。つまりここでの
    /// 「追跡優先」は、キーフレームとキーフレームの間を直線で結ぶか、実際の動きで結ぶかの
    /// 選択でしかなく、ユーザーの指定を上書きすることは無い。
    ///
    /// `resolve(...).rect` を返す薄いラッパ。矩形の分岐を 2 箇所に書き写すと、
    /// そこがそのままモザイクの退行になる（S1 の設計判断）。
    public static func rect(of mask: ObjectMask, tracks: [UUID: ObjectTrack],
                            atSourceTime sourceTime: Double) -> CGRect {
        resolve(of: mask, tracks: tracks, atSourceTime: sourceTime, isTrackingRunning: false).rect
    }

    /// 1 マスクぶんの矩形と「いま追えているか」の状態を、**同じ分岐**でまとめて返す。
    ///
    /// 判定順（この順序が仕様）:
    ///
    /// 1. `mask.anchor.isStill` → `.fixed`、rect はキーフレーム
    /// 2. `tracks[mask.id]` があり `track.matches(mask)` が真:
    ///    - いまの時刻がその軌跡のセグメントに含まれる → `.tracking`、rect は軌跡
    ///    - 含まれない（末尾 clamp・穴） → `.untracked`、rect は
    ///      `track.rect(atSourceTime:) ?? mask.rect(atSourceTime:)`（＝ `rect(of:tracks:atSourceTime:)`
    ///      と同じ値。状態判定を足しても矩形は変えない）
    /// 3. 軌跡が無い/古い:
    ///    - `isTrackingRunning` なら `.computing`
    ///    - そうでなければ `.untracked`
    ///    どちらも rect はキーフレーム補間
    ///
    /// - Parameter isTrackingRunning: そのマスクが属するクリップの追跡タスクが走行中か。
    ///   **rect には一切影響しない**（`ObjectMaskFollowStateTests.test_状態判定を足しても矩形は変わらない` で固定）。
    public static func resolve(of mask: ObjectMask, tracks: [UUID: ObjectTrack],
                               atSourceTime sourceTime: Double,
                               isTrackingRunning: Bool)
        -> (rect: CGRect, state: ObjectMaskFollowState) {
        if mask.anchor.isStill {
            return (mask.rect(atSourceTime: sourceTime), .fixed)
        }
        if let track = tracks[mask.id], track.matches(mask) {
            // 包含の式は `Segment.contains` を借りる。ここに同じ不等式を書き写すと、
            // `ObjectTrack.rect(atSourceTime:)`（同じく `contains` で区間を選ぶ）と
            // 判定がずれたとき、状態だけが嘘になる。
            let inSegment = track.segments.contains { $0.contains(sourceTime) }
            if inSegment, let tracked = track.rect(atSourceTime: sourceTime) {
                return (tracked, .tracking)
            }
            let fallback = track.rect(atSourceTime: sourceTime) ?? mask.rect(atSourceTime: sourceTime)
            return (fallback, .untracked)
        }
        let rect = mask.rect(atSourceTime: sourceTime)
        return (rect, isTrackingRunning ? .computing : .untracked)
    }
}
