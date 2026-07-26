import MosaicCore
import SwiftUI
import UIKit

// このファイルは適用区間トラックに加えて、**タイムライン UI 共通の語彙**
// （`TimelineMetrics` / `TimelineInteraction` / `TimelineTrimPreview` /
// `TimelineTrimPreviewRelay` / `TimelineSnapHaptics`）と、クリップ帯の直上に積む
// `TimelineJointLaneView` を置いている。いずれもクリップ帯トラックと適用区間トラックの
// 両方が使う（あるいは `TimelineClipBandView.swift` が file_length に張り付いたため
// 逃がした）型で、本来は専用の .swift へ分けたいが、新規ファイルの追加には
// `xcodegen generate`（= CocoaPods 統合の再構築）が要るため後続作業に回している。

/// タイムラインの寸法（全トラックで共有。x 座標系を揃えるため 1 箇所に置く）。
enum TimelineMetrics {
    static let rulerHeight: CGFloat = 16
    /// クリップ帯の高さ。一般的な動画編集アプリのサムネ帯（56〜64pt）に合わせてある。
    static let clipHeight: CGFloat = 60
    /// モザイク適用区間トラックの高さ。18pt では端ハンドル（8×18）が HIG の最小タップ目標
    /// 44×44pt を大きく下回っていた。28pt へ広げたうえで、ハンドルの**当たり判定だけ**を
    /// 44×44 へ拡張して補う（`TimelineApplyTrackView.edgeHandle`）。
    static let applyTrackHeight: CGFloat = 28
    static let trackSpacing: CGFloat = 4
    /// トリムハンドルの**見た目の幅**。適用区間の端ハンドルとも共通（操作感を揃えるため）。
    ///
    /// **当たり判定はこの幅ではなく `minimumTapTarget`（44pt）**。見た目を 44 まで太らせると
    /// 短いクリップが端ハンドルだけで埋まるので、描画は 20pt・判定だけ 44pt に広げてある。
    static let handleWidth: CGFloat = 20
    /// 並べ替えジェスチャの判定領域を左右から削る量（片側）。
    ///
    /// **`handleWidth` と共用しないこと。** ハンドルを太らせるとこの inset も一緒に育ち、
    /// 短いクリップでは並べ替え領域（幅 − inset×2）が消えて長押し並べ替えができなくなる。
    /// 端ハンドルはトリムを優先させたいぶんだけ除ければよく、ハンドルの見た目の幅とは
    /// 変更理由が別なので独立した定数にしてある。
    static let reorderInset: CGFloat = 14
    /// サムネイル 1 枚が占める幅。
    static let thumbnailSlotWidth: CGFloat = 44
    /// 継ぎ目ボタンの一辺。レーンの高さ（`jointLaneHeight(hasJoints:)`）と必ず揃えること
    /// （ボタンがレーンからはみ出すとクリップ帯のトリムハンドルを覆う。
    /// `TimelineJointLaneView` の doc 参照）。
    static let jointButtonSize: CGFloat = 28
    /// 継ぎ目ボタン専用レーンの高さ（クリップ帯の直上。`TimelineJointLaneView` の doc 参照）。
    ///
    /// **継ぎ目が無いときは 0。** クリップが 1 本のときは押せるボタンが 1 つも無いのに
    /// 目盛り帯とクリップ帯の間へ 28pt の空白が残っていた
    /// （ユーザー報告「時間とクリップの間のスペースを埋めたい」）。
    /// 継ぎ目が生まれた時点でレーンが生え、タイムライン全体の高さも
    /// `stackHeight(hasJoints:)` 経由で連動して伸びる。
    static func jointLaneHeight(hasJoints: Bool) -> CGFloat {
        hasJoints ? jointButtonSize : 0
    }
    /// タイムライン直下の 1 段（編集ツールバー／粗さ調整バー）の高さ。
    ///
    /// **どちらが出ていても同じ高さにする。** 効果タブを開いた瞬間に段が生えると
    /// プレビューが縮む（旧 UI がまさにそれで 46% → 30% まで潰れていた）。
    static let toolbarHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 4
    /// HIG の最小タップ目標。端ハンドルの**当たり判定だけ**をこの一辺へ広げる。
    static let minimumTapTarget: CGFloat = 44

    /// 全トラックを積んだ高さ。
    ///
    /// **継ぎ目レーンとクリップ帯は `spacing: 0` の内側 VStack で 1 段として積む**
    /// （継ぎ目ボタンは帯の継ぎ目に付くので離さない）。したがって段間の余白は
    /// 目盛り／[継ぎ目+帯]／適用区間の 2 箇所ぶんのままになる。
    ///
    /// 継ぎ目レーンが可変（`jointLaneHeight(hasJoints:)`）なので、**プレイヘッドの縦線と
    /// スクロール容器へ渡す高さは必ずこの関数から採る**（別々に計算すると線が
    /// トラックからはみ出す／足りなくなる）。
    static func stackHeight(hasJoints: Bool) -> CGFloat {
        rulerHeight + jointLaneHeight(hasJoints: hasJoints) + clipHeight + applyTrackHeight
            + trackSpacing * 2
    }
}

/// ジェスチャの**確定**（`onEnded`）で親へ渡す編集内容。
///
/// **ジェスチャ中はモデルを一切変更しない**。進行中の下書きは各トラックの
/// `@GestureState`（`TimelineClipBandView.TrimDraft` / `ReorderDraft` /
/// `TimelineApplyTrackView.ApplyDraft`）が持ち、描画専用に使う。
/// `@GestureState` はジェスチャがキャンセルされると**自動で初期値に戻る**ため、
/// 「中断で下書きが取り残されて帯が伸びたまま」という状態が原理的に作れない
/// （`@State` に持たせていた S9 初版は、横スクロールでの中断だけ回収経路が無かった）。
/// 確定は `onEnded` の 1 回だけで、そこから親がモデルの編集 API を呼ぶ。
///
/// **下書きから表示を導出するのは契約の内側**（`TimelineBandLayout.previewLayouts` /
/// `previewApplySpans` は純関数で、モデルへの書き込みを 1 バイトも増やさない）。
enum TimelineInteraction: Equatable {
    /// クリップ端のトリム（`deltaSeconds` は合成時刻の差分）。
    case trim(clipID: UUID, edge: TimelineTrimEdge, deltaSeconds: Double)
    /// 長押しドラッグでの並べ替え（`translationSeconds` は合成時刻の差分）。
    case reorder(clipID: UUID, translationSeconds: Double)
    /// モザイク適用区間の端ドラッグ（合成時刻の絶対区間）。
    /// `clipID` はどのセグメントを掴んでいるかの識別（1 本の区間は複数クリップに
    /// またがって複数セグメントに見えるため）。確定もこのセグメント単位で行う。
    case applyEdge(rangeID: UUID, clipID: UUID, start: Double, end: Double)
}

/// クリップ帯のトリム下書きから導いた**表示専用**パラメータ（クランプ済み）。
///
/// クリップ帯トラックと適用区間トラックが同じ量だけリップルするために共有する
/// （帯だけ動いて適用区間が置いていかれるのを防ぐ）。モデルは変更しない。
struct TimelineTrimPreview: Equatable {
    let clipID: UUID
    let edge: TimelineTrimEdge
    /// クランプ済みの実効差分（合成秒）。`TimelineBandLayout.previewShift` の入力。
    let effectiveDeltaSeconds: Double
    /// クランプ済みの素材使用範囲（サムネイルのコマ出しに使う）。
    let sourceStart: Double
    let sourceEnd: Double
}

/// クリップ帯のトリム下書き（表示専用の派生値）を**兄弟トラックへ中継**する箱。
///
/// トリムの `@GestureState` は `TimelineClipBandView`（子）にあるため、そのままでは
/// 兄弟の `TimelineApplyTrackView` へ流せない。かといって親（`VideoTimelineView`）の
/// `@State` に持たせると、ドラッグ中 60Hz で**親の body が再評価**され、子のジェスチャが
/// 作り直されて `@GestureState` が落ちる経路に乗る。
///
/// そこで**参照型 + `@Published`** にして、親は `@State`（= 購読しない。
/// `TimelineSnapHaptics` と同じ持ち方）で保持し、**適用区間トラックだけが
/// `@ObservedObject` で購読する**。これで再描画は追随が必要なトラックに限定され、
/// 親とクリップ帯は再評価されない。
///
/// **編集状態ではない**（モデルは 1 バイトも変わらない。`TimelineInteraction` の契約
/// 「ジェスチャ中はモデルを変更しない / 確定は `onEnded` の 1 回だけ」は保たれる）。
/// 中継の更新はクリップ帯の `.onChange(of: trimDraft)` から出すので、
/// **ジェスチャがキャンセルされたときも `@GestureState` のリセットに追随して nil へ戻る**
/// （取り残しが原理的に作れないという `@GestureState` の利点をそのまま引き継ぐ）。
final class TimelineTrimPreviewRelay: ObservableObject {
    @Published private(set) var preview: TimelineTrimPreview?

    /// 同値なら publish しない（毎フレーム同じ値で再描画を撒かない）。
    func update(_ next: TimelineTrimPreview?) {
        guard next != preview else { return }
        preview = next
    }
}

/// 吸着ハプティクスの発火管理。
///
/// **参照型を `@State` に入れて中身を書き換えること。** `.updating` / `.onChanged` の中で
/// `@State` の値型を書くと body 再評価 → ジェスチャ再生成の経路に乗る。参照型なら
/// 中身を書き換えても SwiftUI の状態は変化せず、再描画も起きない。
///
/// iOS 16 ターゲットなので `.sensoryFeedback`（iOS 17+）は使えない。
final class TimelineSnapHaptics {
    private let generator = UIImpactFeedbackGenerator(style: .light)
    private var lastSnappedTo: Double?

    /// ジェスチャ開始時に 1 回だけ呼ぶ（`prepare()` は短時間だけ有効な準備要求）。
    func begin() {
        lastSnappedTo = nil
        generator.prepare()
    }

    func end() { lastSnappedTo = nil }

    /// 吸着先が **nil→値 / 値→別の値**に変わった瞬間だけ鳴らす
    /// （毎フレーム鳴らすと連打になる。`TimelineSnapResult.snappedTo` の doc 参照）。
    func report(snappedTo: Double?) {
        defer { lastSnappedTo = snappedTo }
        guard let snappedTo, snappedTo != lastSnappedTo else { return }
        generator.impactOccurred()
    }

    /// 長押し成立（並べ替え開始）の 1 発。
    func longPressImpact() {
        generator.prepare()
        generator.impactOccurred()
    }
}

/// モザイク適用区間トラック（クリップ帯の下）。
///
/// **座標系**: UI 操作はすべて**合成時刻**で行い、保存は
/// `MosaicApplyGate` / `TimelineState.addingApplyRange` が素材時刻アンカーへ写す。
/// 表示は逆写像 `TimelineBandLayout.applySpans(ranges:mapping:)` の結果を描くだけで、
/// この View は素材時刻を一切扱わない。
///
/// **1 区間は最大 1 セグメントにしか写らない**（不変条件 I2）。適用区間は S11 で
/// `clipID` アンカーになり、`clipID` は一意だからである（旧仕様では同じ素材を使う
/// クリップの数だけ同じ `rangeID` のセグメントが現れた）。確定は掴んだセグメント単位で
/// 行い、差し替えは素材時刻で走る（クリップ使用範囲外の素材区間はコア層が温存する。
/// `TimelineState.replacingApplyRange(id:clipID:compositionInterval:)` 参照）。
///
/// **写真クリップのセグメントには端ハンドルを出さない**
/// （`TimelineApplySpan.isEdgeAdjustable == false`）。写真の素材時刻は常に 0 へ丸められ、
/// 区間が必ずクリップ全体になるため端ドラッグが構造的に no-op になる。ハンドルを出すと
/// 「掴んで動かせるのに指を離すと必ず元へ戻る」という無言の失敗になる。
struct TimelineApplyTrackView: View {
    /// 端ドラッグの下書き（ジェスチャ中だけ非 nil）。
    /// `@GestureState` なのでキャンセルで自動的に初期値へ戻る。
    struct ApplyDraft: Equatable {
        let rangeID: UUID
        let clipID: UUID
        let start: Double
        let end: Double
    }

    let geometry: TimelineGeometry
    let spans: [TimelineApplySpan]
    let totalDuration: Double
    /// 吸着候補（`TimelineSnap.candidates`）の材料。
    ///
    /// **既定値を持たせないこと。** 省略できると「渡し忘れても動くが吸着だけ効かない」
    /// という無言の劣化になる（S12 初版は既定値のまま未配線で、クリップ帯の端・
    /// プレイヘッドへの吸着とトリム中のリップル追随が丸ごと効いていなかった）。
    let layouts: [TimelineClipLayout]
    let playheadTime: Double
    /// クリップ帯のトリム下書きへの追随（リップル）。**表示専用**。
    @ObservedObject var trimPreviewRelay: TimelineTrimPreviewRelay
    @Binding var selectedRangeID: UUID?
    let onCommit: (TimelineInteraction) -> Void

    @GestureState private var draft: ApplyDraft?
    /// 吸着ハプティクスの前回値保持（`TimelineSnapHaptics` の doc 参照）。
    @State private var haptics = TimelineSnapHaptics()

    /// 端ドラッグで潰さない最小の合成尺（秒）。
    private static let minimumSpan: Double = 0.1

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: max(geometry.width(forDuration: totalDuration), 1),
                       height: TimelineMetrics.applyTrackHeight)
            ForEach(displaySpans) { span in
                spanView(span)
            }
        }
        .frame(height: TimelineMetrics.applyTrackHeight, alignment: .topLeading)
    }

    /// 表示用スパン。クリップ帯のトリム下書き中は帯と同じ量だけ平行移動させる
    /// （忘れると帯だけ動いて区間が置いていかれる）。
    private var displaySpans: [TimelineApplySpan] {
        guard let trimPreview = trimPreviewRelay.preview else { return spans }
        return TimelineBandLayout.previewApplySpans(
            spans: spans, layouts: layouts, trimmingClipID: trimPreview.clipID,
            edge: trimPreview.edge, effectiveDeltaSeconds: trimPreview.effectiveDeltaSeconds)
    }

    @ViewBuilder
    private func spanView(_ span: TimelineApplySpan) -> some View {
        let bounds = displayBounds(span)
        let width = geometry.width(forDuration: bounds.end - bounds.start)
        let isSelected = selectedRangeID == span.rangeID

        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(isSelected ? 0.85 : 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
            )
            .frame(width: max(width, 3), height: TimelineMetrics.applyTrackHeight)
            .overlay(alignment: .leading) {
                if isSelected, span.isEdgeAdjustable { edgeHandle(span, edge: .start) }
            }
            .overlay(alignment: .trailing) {
                if isSelected, span.isEdgeAdjustable { edgeHandle(span, edge: .end) }
            }
            .offset(x: geometry.x(forTime: bounds.start))
            .contentShape(Rectangle())
            .onTapGesture { selectedRangeID = span.rangeID }
    }

    /// 端ハンドル。見た目は `handleWidth`×28 のまま、**当たり判定だけ**を HIG の 44×44 へ広げる
    /// （トラック高 28pt + 上下 8pt ずつ）。
    ///
    /// 親に `.clipped()` / `.clipShape` が無いことが前提（無いことは確認済み。
    /// ヒットテストが frame の外へ本当に届くかは**実機確認事項**で、効かなければ
    /// 28pt 化のぶんだけでも現状比 +56% になる）。
    private func edgeHandle(_ span: TimelineApplySpan, edge: TimelineTrimEdge) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: TimelineMetrics.handleWidth, height: TimelineMetrics.applyTrackHeight)
            .contentShape(Rectangle())
            .overlay(
                Color.clear
                    .frame(width: TimelineMetrics.minimumTapTarget,
                           height: TimelineMetrics.minimumTapTarget)
                    .contentShape(Rectangle())
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .updating($draft) { value, draft, _ in
                        if draft == nil { haptics.begin() }
                        let next = snappedDraft(span, edge: edge,
                                                translation: Double(value.translation.width))
                        haptics.report(snappedTo: next.snappedTo)
                        draft = next.draft
                    }
                    .onEnded { value in
                        haptics.end()
                        let committed = snappedDraft(span, edge: edge,
                                                     translation: Double(value.translation.width)).draft
                        onCommit(.applyEdge(rangeID: committed.rangeID, clipID: committed.clipID,
                                            start: committed.start, end: committed.end))
                    }
            )
    }

    /// ドラッグ量から確定候補の合成時刻区間を作る。
    ///
    /// **順序は「吸着 → クランプ」**（逆にすると吸着結果がクランプで壊れる。
    /// `TimelineSnap` の doc 参照）。適用区間の端はもともと絶対時刻なので素直に挟める。
    /// 許容量は **px 由来**にしてズーム段によらず指の感覚を一定にする。
    /// 候補からは掴んでいる区間（`rangeID`）だけを外す（クリップ帯の端は候補に残す。
    /// 適用区間をクリップ境界へ合わせるのが最も多い操作なので）。
    private func snappedDraft(_ span: TimelineApplySpan, edge: TimelineTrimEdge,
                              translation: Double) -> (draft: ApplyDraft, snappedTo: Double?) {
        let delta = geometry.time(forX: translation)
        let candidates = TimelineSnap.candidates(layouts: layouts, applySpans: spans,
                                                 playheadTime: playheadTime,
                                                 totalDuration: totalDuration,
                                                 excluding: [span.rangeID])
        let tolerance = geometry.duration(forWidth: TimelineSnap.defaultTolerancePixels)
        switch edge {
        case .start:
            let snapped = TimelineSnap.snapped(time: span.start + delta,
                                               candidates: candidates, tolerance: tolerance)
            let upper = span.end - Self.minimumSpan
            let start = min(max(snapped.time, 0), max(0, upper))
            return (ApplyDraft(rangeID: span.rangeID, clipID: span.clipID,
                               start: start, end: span.end), snapped.snappedTo)
        case .end:
            let snapped = TimelineSnap.snapped(time: span.end + delta,
                                               candidates: candidates, tolerance: tolerance)
            let lower = span.start + Self.minimumSpan
            let end = max(min(snapped.time, totalDuration), lower)
            return (ApplyDraft(rangeID: span.rangeID, clipID: span.clipID,
                               start: span.start, end: end), snapped.snappedTo)
        }
    }

    private func displayBounds(_ span: TimelineApplySpan) -> (start: Double, end: Double) {
        guard let draft, draft.rangeID == span.rangeID, draft.clipID == span.clipID else {
            return (span.start, span.end)
        }
        return (draft.start, draft.end)
    }
}

/// 継ぎ目（トランジション）ボタン専用のレーン。クリップ帯の**直上**に置く。
///
/// **クリップ帯の中にボタンを置いてはいけない。** 継ぎ目ボタン（`jointButtonSize` 角）は
/// トランジション未設定の継ぎ目では `joint.time == 先行クリップの bandEnd ==
/// 後続クリップの bandStart` なのでトリムハンドルと x が一致し、ハンドル上半分を覆う。
/// `Button` はドラッグを下位ビューへ転送しないため、
/// ハンドル中央から始めたトリムが無反応になっていた（先行クリップの trailing 側と
/// 後続クリップの leading 側の**両方**が食われる）。
/// y をずらす・ボタンを小さくする案はハンドルが帯の全高 52pt を占める以上、
/// x が重なる限り根治しない。レーンごと分けることで当たり判定が完全に分離する。
struct TimelineJointLaneView: View {
    let geometry: TimelineGeometry
    let joints: [TimelineJointLayout]
    let contentWidth: CGFloat
    /// 継ぎ目ボタンのタップ（引数は先行クリップの id）。
    let onJointTap: (UUID) -> Void

    private var laneHeight: CGFloat {
        TimelineMetrics.jointLaneHeight(hasJoints: !joints.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 高さは `TimelineMetrics.stackHeight(hasJoints:)` と必ず一致させる
            // （継ぎ目が無ければ 0 = 目盛り帯とクリップ帯が隣り合う）。
            Color.clear
                .frame(width: max(contentWidth, 1), height: laneHeight)
            ForEach(joints) { joint in
                jointButton(joint)
            }
        }
        .frame(height: laneHeight, alignment: .topLeading)
    }

    private func jointButton(_ joint: TimelineJointLayout) -> some View {
        let size = TimelineMetrics.jointButtonSize
        return Button {
            onJointTap(joint.outgoingClipID)
        } label: {
            Image(systemName: joint.kind == nil ? "plus" : "square.on.square.dashed")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(joint.kind == nil ? Color.white.opacity(0.85) : Color.yellow)
                )
        }
        .buttonStyle(.plain)
        .offset(x: geometry.x(forTime: joint.time) - size / 2)
    }
}
