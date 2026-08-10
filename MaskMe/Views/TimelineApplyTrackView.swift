import MosaicCore
import SwiftUI
import UIKit

// トラック本体（帯の描画・選択・端ドラッグ）は `TimelineLayerTrackView.swift` へ
// 切り出した。このファイルには**タイムライン UI 共通の語彙**
// （`TimelineMetrics` / `TimelineInteraction` / `TimelineTrimPreview` /
// `TimelineTrimPreviewRelay` / `TimelineSnapHaptics`）と、クリップ帯の直上に積む
// `TimelineJointLaneView` だけが残る。いずれもクリップ帯トラックとレイヤートラックの
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
    /// 44×44 へ拡張して補う（`TimelineLayerTrackView.edgeHandle`）。
    static let applyTrackHeight: CGFloat = 28
    static let trackSpacing: CGFloat = 4
    /// レイヤー段 1 本の高さ。モザイク段（＝旧・適用区間トラック）と揃える
    /// （揃えないと、同じ「上に載る段」なのに音声だけ厚い、という見え方になる）。
    static let layerRowHeight: CGFloat = applyTrackHeight
    /// レイヤー段の左端に置く固定アイコン列の幅。
    static let layerRailWidth: CGFloat = 30
    /// レイヤー段が見えている高さ。**2 段ぶん**。
    ///
    /// ここを段数ぶんに広げてはいけない。段は今後も増える（音声・テキスト・
    /// キャプション…）ので、広げるとそのぶん必ずプレビューが縮む。
    /// 見えるのは 2 段までにして、残りは縦スクロールで辿る（VLLO と同じ）。
    static let layerViewportHeight: CGFloat = layerRowHeight * 2 + trackSpacing
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
    /// モザイク区間の本体ドラッグで「横（移動）」と「縦（段の送り）」を排他的に確定する
    /// しきい値（px、累積 translation）。
    ///
    /// 段の高さ（`layerRowHeight` = 28pt）しかない領域で指は純粋な水平移動を作れないため、
    /// 最初の動きだけで方向を 1 回に決め、以後は変えない。値は
    /// **祖先の段送りジェスチャ（`layerScrollGesture`, `minimumDistance: 4`）より大きく**、
    /// **この移動ジェスチャ自身の `DragGesture(minimumDistance: 1)`（祖先より先に認識を
    /// 取るため `edgeHandle` と同じ値にしてある）より十分大きい** 6pt にした。
    /// 4pt 以下だと祖先の段送りが実際に動き出す量より先に確定してしまい体感とずれ、
    /// 1pt に近いと指の震え・タップの微小なブレだけで方向が決まってしまう。
    static let applyMoveAxisLockThreshold: CGFloat = 6
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
    /// 目盛り／[継ぎ目+帯]／レイヤー段の 2 箇所ぶんのままになる。
    ///
    /// **レイヤー段は段数によらず `layerViewportHeight` で固定**（はみ出しは縦スクロール）。
    /// 段が増えるたびにここが伸びると、そのぶんプレビューが縮んでいく。
    ///
    /// 継ぎ目レーンが可変（`jointLaneHeight(hasJoints:)`）なので、**プレイヘッドの縦線と
    /// スクロール容器へ渡す高さは必ずこの関数から採る**（別々に計算すると線が
    /// トラックからはみ出す／足りなくなる）。
    static func stackHeight(hasJoints: Bool) -> CGFloat {
        rulerHeight + jointLaneHeight(hasJoints: hasJoints) + clipHeight + layerViewportHeight
            + trackSpacing * 2
    }
}

/// ジェスチャの**確定**（`onEnded`）で親へ渡す編集内容。
///
/// **ジェスチャ中はモデルを一切変更しない**。進行中の下書きは各トラックの
/// `@GestureState`（`TimelineClipBandView.TrimDraft` / `ReorderDraft` /
/// `TimelineLayerTrackView.ApplyDraft`）が持ち、描画専用に使う。
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
    /// モザイク適用区間の本体ドラッグ（平行移動）。`deltaSeconds` は合成時刻の移動量で、
    /// `MosaicEditorModel.moveMosaicApplyRange(id:clipID:byCompositionDelta:)`
    /// （`TimelineState.movingApplyRange`）へそのまま渡す。
    /// `start` / `end` はドラッグ表示と同じ最終位置（確定後の選択引き直し用の目安）。
    case applyMove(rangeID: UUID, clipID: UUID, deltaSeconds: Double, start: Double, end: Double)
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
/// 兄弟の `TimelineLayerTrackView` へ流せない。かといって親（`VideoTimelineView`）の
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
                        .fill(joint.kind == nil ? Color.white.opacity(0.85) : TimelinePalette.structure)
                )
        }
        .buttonStyle(.plain)
        .offset(x: geometry.x(forTime: joint.time) - size / 2)
    }
}
