import Foundation

/// モザイクを適用する素材時刻の区間（半開区間 [sourceStart, sourceEnd)）。
///
/// 検出キャッシュと同じ理屈で**素材時刻アンカー**にしてあるため、
/// クリップの分割・並べ替え・速度変更後も区間を更新せずに自動追従する。
/// UI が扱う合成時刻の区間は `MosaicApplyGate.ranges(addingCompositionInterval:...)` で
/// 素材アンカーへ分解してから保存する（合成時刻のまま保存する誤実装を禁止）。
///
/// **区間の編集も素材時刻で行うこと。** 「合成時刻の区間列から作り直す」実装は、
/// クリップ使用範囲外の素材区間（トリムで一時的に外れた区間など）を必ず落とす
/// （実測: A=source[0,2)・B=source[3,5) に対し区間 source[1,4) のハンドルに
/// 触っただけで source[2,3) が消滅）。編集の入口は
/// `MosaicApplyGate.ranges(replacingRangeID:clipID:...)` の 1 本だけ。
///
/// **写真素材の適用区間はクリップ全体（素材 [0, sourceEnd)）を覆う。**
/// 写真クリップの素材時刻は `TimelineState.clampedSourceTime` が常に 0 へ丸めるため、
/// 合成時刻由来の素材アンカー（例 [1,2)）を保存すると `isActive` が 0 を見て
/// **絶対にヒットしない**。静止画に対する秒単位の ON/OFF を捨てる代わりに、
/// 「素材時刻アンカー」という不変条件を全素材で保つ。
///
/// **どのクリップの使用範囲とも交差しなくなった区間（孤児区間）は消さずに温存する。**
/// トリム・分割で一時的に外れただけの区間を消すと、トリムを戻しても undo しても
/// 復活しないからである。代わりに**ゲート判定の側で除外**する
/// （`MosaicApplyGate.effectiveRanges(_:mapping:)`）。この分担により
/// 「画面に見えている帯（`TimelineBandLayout.applySpans`）とゲートの挙動が必ず一致する」
/// という不変条件（I1）が保たれる。
/// ただし**クリップ削除だけは区間も一緒に消す**（`TimelineState.removing(clipID:)`）:
/// `clipID` は復活しないので、温存すると永久に不可視・削除不能なゴミになる。
/// undo は `EditSnapshot.timeline` が状態ごと戻すので復元性は落ちない。
///
/// **アンカーは `clipID` + `sourceID` + 素材時刻**（S11）。時刻を素材アンカーのまま
/// 保つことで速度変更・トリムが区間を書き換えずに済む。`clipID` は「その区間がどの
/// クリップに属するか」のスコープにだけ使う。これが無いと、同一素材を分割した隣接
/// クリップ A/B で A にだけ置いた区間が、B を A の区間へ被る位置まで
/// トリムしただけで B にも効いてしまう。
public struct MosaicApplyRange: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// この区間が属するクリップの識別子（`TimelineClip.id`）。
    ///
    /// **既定値を置かないこと。** 渡し忘れをコンパイルエラーにするためであり、
    /// `UUID()` の既定値やデコード時の `?? UUID()` は「どのクリップとも一致しない
    /// sentinel が黙って残る」＝その区間が永久に効かない事故になる。
    /// 旧 JSON（schemaVersion 1）の吸収は `TimelineState.init(from:)` の責務。
    public let clipID: UUID
    /// 素材の識別子（`TimelineClip.sourceID` と同じ空間）。
    public let sourceID: UUID
    /// 素材内での適用開始位置（秒）。
    public var sourceStart: Double
    /// 素材内での適用終了位置（秒）。この時刻ちょうどは区間外（半開区間）。
    public var sourceEnd: Double

    public init(id: UUID = UUID(), clipID: UUID, sourceID: UUID,
                sourceStart: Double, sourceEnd: Double) {
        self.id = id
        self.clipID = clipID
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}

/// UI が指定する合成時刻の半開区間 [start, end)。
///
/// `Range<Double>` を使わないのは、`lowerBound > upperBound` で実行時トラップする
/// （ジェスチャ由来の値では起こり得る）ため。この型は不正な区間をそのまま持てて、
/// 受け側（`TimelineState.replacingApplyRange`）が捨てる。
public struct CompositionInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// 有限かつ start < end。
    public var isValid: Bool { start.isFinite && end.isFinite && start < end }
}

/// モザイク適用範囲のゲート判定と区間編集の純関数群。
///
/// ゲートは検出 lookup の**後段・描画直前**に置く（区間外でもライブ検出は継続して
/// キャッシュを埋める設計のため、lookup 側に入れてはならない）。
public enum MosaicApplyGate {
    /// 同一クリップ内の区間マージで「隣接」とみなす許容誤差（秒）。
    /// クリップ分割由来の区間は境界が浮動小数点誤差でずれ得るため厳密一致にしない。
    private static let mergeTolerance: Double = 1e-9

    /// **交差判定の唯一の実体（不変条件 I3）**。
    ///
    /// 「区間 `range` がクリップ `clip` の使用範囲と交差するか」を判定し、交差するなら
    /// クリップ使用範囲でクリップした素材時刻区間を返す。判定式は
    /// `clip.id == range.clipID && clip.sourceID == range.sourceID &&`
    /// `max(range.sourceStart, clip.sourceStart) < min(range.sourceEnd, clip.sourceEnd)`
    /// （両端が有限）。
    ///
    /// **`effectiveRanges` / `TimelineBandLayout.applySpans` / 永続化マイグレーション
    /// （`TimelineState.init(from:)`）の 3 箇所は必ずこの関数を呼ぶこと。** 式を書き写すと
    /// 1 ulp のずれで「帯は出ているのにゲートが閉じる」事故が復活する（S8 の `Overlap.end`、
    /// S10 の孤児区間の前科）。モジュール内公開なのは 3 箇所が別ファイルにあるため。
    static func clippedInterval(clip: TimelineClip,
                                range: MosaicApplyRange) -> (start: Double, end: Double)? {
        guard clip.id == range.clipID, clip.sourceID == range.sourceID else { return nil }
        let start = max(range.sourceStart, clip.sourceStart)
        let end = min(range.sourceEnd, clip.sourceEnd)
        guard start.isFinite, end.isFinite, start < end else { return nil }
        return (start, end)
    }

    /// 「いまのタイムラインで実際に効いている適用区間」だけに絞る。
    ///
    /// **ゲート判定に渡す区間は必ずこの関数を通すこと。** 顔の素材別ゲート・合成時刻
    /// ゲート・エクスポートの 3 経路が同じ結果になる唯一の担保であり、絞り込みを
    /// 呼び出し側で書き直す（＝二重実装する）ことは禁止する。
    ///
    /// **S11 で役割が変わった点**: 新仕様（区間 0 本 = 全区間 OFF）では、孤児区間は
    /// もはやフェイルオープンの引き金ではない（`clipID` アンカーなので、そのまま通しても
    /// ON にならない）。それでも残すのは (1) **不変条件 I1 の担保**＝帯（`applySpans`）に
    /// 見えていない区間をゲートに渡さない、(2) **キャッシュ**の 2 つが理由である。
    /// **削除しないこと**（消すと 3 経路の一致担保が消える）。
    ///
    /// 計算量は O(クリップ数 × 区間数)。**毎フレーム呼ばない**こと。
    /// `MosaicEditorModel` は `timeline` の didSet で 1 回だけ計算してキャッシュし、
    /// `VideoMosaicExporter` は export 開始時に 1 回だけ計算する
    /// （実測: 50 クリップ × 100 区間で 0.14〜0.18ms／回。タイムライン変更時 1 回なら
    /// 無視できるが、30fps 描画やエクスポートの全フレームで回す量ではない）。
    public static func effectiveRanges(_ ranges: [MosaicApplyRange],
                                       mapping: TimelineMapping) -> [MosaicApplyRange] {
        guard !ranges.isEmpty else { return ranges }
        let spans = mapping.clipSpans
        guard !spans.isEmpty else { return [] }
        return ranges.filter { range in
            spans.contains { clippedInterval(clip: $0.clip, range: range) != nil }
        }
    }

    /// 指定したクリップ・素材時刻にモザイクを適用すべきかを返す。
    ///
    /// `ranges` には `effectiveRanges(_:mapping:)` の結果を渡すこと。
    ///
    /// **判定順序 ①②③ が仕様そのものである。入れ替えないこと。**
    ///
    /// 1. `clipID` が nil（写像不能 = どのクリップにも解決できない）→ **フェイルオープン**。
    ///    ② を先に置くと、クリップ未構築の窓（動画ロード中・写真モード）で顔だけ
    ///    モザイクが外れる。
    /// 2. `ranges` が空 → **OFF**（S11 の新仕様: 区間 0 本 = 全区間 OFF）。
    /// 3. `sourceTime` が非有限（写像破損）→ **フェイルオープン**。③ を ② より前に
    ///    置くと、ユーザーが全区間を削除した状態で NaN 時刻だけ ON に戻る。
    ///
    /// フェイルオープンの方向は合成時刻ゲート（`gateState`）と必ず揃えること（I4）。
    /// 片方だけ倒すと「顔は素通しだが手動矩形と背景だけモザイク」という絵になる。
    /// 判定は半開区間 [sourceStart, sourceEnd)。
    ///
    /// - Parameter clipID: この素材時刻を解決したクリップの id。**nil = 写像不能**。
    ///   クランプ済みの解決結果（`MosaicEditorModel.resolveSourceLocation(atComposition:)` /
    ///   `VideoMosaicExporter.resolveLocation(_:at:)`）の clipID を渡すこと。
    ///   未クランプの `mapping.sourceLocation(at:)?.clipID` を渡すと、終端フレームだけ
    ///   プレビューがフェイルオープンしてエクスポートと食い違う。
    public static func isActive(ranges: [MosaicApplyRange],
                                clipID: UUID?,
                                sourceID: UUID, sourceTime: Double) -> Bool {
        guard let clipID else { return true }
        guard !ranges.isEmpty else { return false }
        guard sourceTime.isFinite else { return true }
        return ranges.contains {
            $0.clipID == clipID && $0.sourceID == sourceID
                && $0.sourceStart <= sourceTime && sourceTime < $0.sourceEnd
        }
    }

    /// 指定した**合成時刻**でモザイクを適用すべきかを返す（S10）。
    ///
    /// 素材アンカーを持たない効果——手動矩形（`manualRegions`）と背景モザイク——の
    /// 唯一の判定入口である。判定規則は
    ///
    /// > **その合成時刻に映っている素材のうち、1 つでも適用区間内なら適用する。**
    ///
    /// トランジションの重なり区間（2 素材が同時に映る）で片方だけ区間内のときは
    /// 適用側へ倒す近似になる。重なりは高々トランジション尺であり、かつ
    /// **モザイクの過剰適用は安全側・不足は事故**なのでこの方向で確定させる。
    ///
    /// 顔ランドマークはこの関数を通さない。顔は素材ごとに引くので
    /// `isActive(ranges:clipID:sourceID:sourceTime:)` で**素材別に**ゲートできる
    /// （`MosaicEditorModel.displayFaces(at:matching:)`）。
    ///
    /// **フェイルオープンする条件は「写像が 1 つも解決できない」ときだけ**
    /// （クリップ未構築・非有限時刻・空タイムライン）。**区間 0 本は OFF** である
    /// （S11 の新仕様。旧仕様の「空 = 全区間 ON」は逆転した）。
    ///
    /// **顔の素材別ゲート（`isActive(ranges:clipID:sourceID:sourceTime:)`）もフェイル方向が
    /// これと揃っている**（clipID が解決できないときだけフェイルオープン、区間 0 本は OFF）。
    /// 片方だけフェイルクローズだと「顔にはモザイクが乗らないが手動矩形と背景モザイクは
    /// 乗る」という中途半端な絵になる（不変条件 I4）。
    ///
    /// 写像範囲外の有限時刻（合成尺ちょうどの終端・負値。再生終端や AVPlayer の実測
    /// 時刻の揺らぎで日常的に発生する）はタイムラインの端へクランプしてから写像する。
    /// これは `MosaicEditorModel.resolveSourceTime(atComposition:)` および
    /// `VideoMosaicExporter.resolveLocation(_:at:)` と**同じ規則**である
    /// （ここだけ規則が違うと終端フレームでプレビューとエクスポートの ON/OFF が食い違う）。
    ///
    /// **既知の解像度限界**: rate < 1 のクリップでは、区間終端 `to` の直前 2 ulp
    /// （実測 7.105e-15 秒）が OFF になることがある。合成時刻→素材時刻の写像が
    /// double 解像度で単射でないためで、ゲートの誤りではない（実フレームの PTS が
    /// そこに当たることは事実上ない）。
    ///
    /// - Parameter ranges: `effectiveRanges(_:mapping:)` を通した区間。
    /// - Parameter photoSourceIDs: 写真素材の素材ID集合。素材時刻を 0 へ clamp する
    ///   （`TimelineState.clampedSourceTime` と同じ規則。写真の適用区間は
    ///   `MosaicApplyRange` 型の doc どおり素材 [0, sourceEnd) を覆う）。
    ///   **既定値は置かない**: 渡し漏れると同一写真素材の複数クリップ構成で判定が
    ///   無言で反転する（実測で true ⇄ false が入れ替わる）ため、渡し忘れを
    ///   コンパイルエラーにする。
    public static func isActive(ranges: [MosaicApplyRange],
                                mapping: TimelineMapping,
                                compositionTime: Double,
                                photoSourceIDs: Set<UUID>) -> Bool {
        gateState(ranges: ranges, mapping: mapping, compositionTime: compositionTime,
                  photoSourceIDs: photoSourceIDs).isActive
    }

    /// 合成時刻ゲートの判定結果と、その内訳（どの素材が適用対象か）。
    public struct CompositionGateState: Equatable, Sendable {
        /// 素材アンカーを持たない効果（手動矩形・背景モザイク）を適用するか。
        public let isActive: Bool
        /// その合成時刻に映っている素材のうち、適用区間内と判定されたものの素材ID集合。
        /// フェイルオープン時（写像不能）は空集合。
        /// **区間 0 本（＝全区間 OFF）のときも空集合にすること。** ここで「映っている
        /// 素材すべて」を返すと、エクスポートの `gateChanged` が「区間なし → 区間あり」の
        /// 遷移を検出できなくなる。
        ///
        /// **用途**: トランジションの重なり区間で片方の素材だけ ON→OFF に変わった
        /// フレームを検出するため。`isActive` は「どれか 1 つでも ON」なので、
        /// 重なり中に片側が落ちても真偽値は true のまま変わらず、エクスポートの
        /// 強制再検出（`gateChanged`）が発火しない＝古い union が居座る。
        public let activeSourceIDs: Set<UUID>

        public init(isActive: Bool, activeSourceIDs: Set<UUID>) {
            self.isActive = isActive
            self.activeSourceIDs = activeSourceIDs
        }
    }

    /// `isActive(ranges:mapping:compositionTime:photoSourceIDs:)` と同じ判定を、
    /// 内訳（適用対象の素材ID集合）付きで返す。判定規則の実体はこの 1 本だけ。
    public static func gateState(ranges: [MosaicApplyRange],
                                 mapping: TimelineMapping,
                                 compositionTime: Double,
                                 photoSourceIDs: Set<UUID>) -> CompositionGateState {
        var locations = mapping.sourceLocations(at: compositionTime)
        if locations.isEmpty, compositionTime.isFinite, mapping.totalDuration > 0 {
            let clamped = min(max(compositionTime, 0), mapping.totalDuration.nextDown)
            locations = mapping.sourceLocations(at: clamped)
        }
        // 判定順序（I4）: ① 写像不能 → フェイルオープン、② 区間 0 本 → OFF。
        // 素材別ゲート `isActive(ranges:clipID:sourceID:sourceTime:)` の ①② と同じ順序。
        guard !locations.isEmpty else { return CompositionGateState(isActive: true, activeSourceIDs: []) }
        guard !ranges.isEmpty else { return CompositionGateState(isActive: false, activeSourceIDs: []) }
        var active: Set<UUID> = []
        for entry in locations {
            let sourceID = entry.location.sourceID
            let sourceTime = photoSourceIDs.contains(sourceID) ? 0 : entry.location.time
            if isActive(ranges: ranges, clipID: entry.location.clipID,
                        sourceID: sourceID, sourceTime: sourceTime) {
                active.insert(sourceID)
            }
        }
        return CompositionGateState(isActive: !active.isEmpty, activeSourceIDs: active)
    }

    /// UI が指定した合成時刻の区間 [from, to) を素材アンカーへ分解して `existing` に追加する。
    ///
    /// 区間が複数クリップを跨ぐ場合はクリップごとのセグメントに分割される。
    /// 追加後、同一 clipID の重複・隣接区間はマージして正規化する。
    /// マージ結果の id は**入力順で最初に現れた区間**の id を引き継ぐ
    /// （前方に伸ばす操作でも UI の選択が飛ばない）。
    /// `from >= to` の場合は `existing` をそのまま返す。
    ///
    /// - Parameter photoSourceIDs: 写真素材の素材ID集合（`TimelineState.photoSourceIDs`）。
    ///   該当クリップに触れる区間は素材 [0, sourceEnd) に丸める（型の doc 参照）。
    public static func ranges(addingCompositionInterval from: Double, to: Double,
                              mapping: TimelineMapping,
                              existing: [MosaicApplyRange],
                              photoSourceIDs: Set<UUID> = []) -> [MosaicApplyRange] {
        guard from < to else { return existing }
        var result = existing
        for span in mapping.clipSpans {
            guard let interval = sourceInterval(in: span, from: from, to: to,
                                                isPhoto: photoSourceIDs.contains(span.clip.sourceID))
            else { continue }
            result.append(MosaicApplyRange(clipID: span.clip.id,
                                           sourceID: span.clip.sourceID,
                                           sourceStart: interval.start,
                                           sourceEnd: interval.end))
        }
        return merged(result)
    }

    /// 掴んだセグメント（`rangeID` × `clipID`）の素材区間だけを差し替える（端ドラッグの確定）。
    ///
    /// **合成時刻での作り直しをしない理由**は `MosaicApplyRange` 型の doc を参照。
    /// 当該クリップの使用範囲と交差する部分だけを新区間へ置き換え、クリップ使用範囲の
    /// 外にある素材区間はそのまま残す。結果は同一 clipID 内でマージ・正規化される。
    ///
    /// 次の場合は `existing` をそのまま返す（他の編集操作と同じ「失敗時は無変更」契約）:
    /// - 区間が不正（`CompositionInterval.isValid` が false）
    /// - `rangeID` / `clipID` が不在、または両者の素材が食い違う
    /// - 差し替え結果が現在の素材区間と一致する（ハンドルに触っただけのドラッグ量 0。
    ///   ここで弾かないと id 再発行だけで `Equatable` が differ になり、undo 履歴が汚れる）
    public static func ranges(replacingRangeID id: UUID,
                              clipID: UUID,
                              compositionInterval interval: CompositionInterval,
                              mapping: TimelineMapping,
                              existing: [MosaicApplyRange],
                              photoSourceIDs: Set<UUID> = []) -> [MosaicApplyRange] {
        guard interval.isValid,
              let index = existing.firstIndex(where: { $0.id == id }),
              let span = mapping.clipSpans.first(where: { $0.clip.id == clipID }),
              existing[index].clipID == clipID,
              let replacement = sourceInterval(in: span, from: interval.start, to: interval.end,
                                               isPhoto: photoSourceIDs.contains(span.clip.sourceID))
        else { return existing }
        let range = existing[index]
        // 当該クリップが使っている素材区間（= 掴んだセグメントの実体）。
        let occupiedStart = max(range.sourceStart, span.clip.sourceStart)
        let occupiedEnd = min(range.sourceEnd, span.clip.sourceEnd)
        var pieces: [(start: Double, end: Double)] = []
        if occupiedStart < occupiedEnd {
            if abs(occupiedStart - replacement.start) <= mergeTolerance,
               abs(occupiedEnd - replacement.end) <= mergeTolerance { return existing }
            if range.sourceStart < occupiedStart { pieces.append((range.sourceStart, occupiedStart)) }
            if occupiedEnd < range.sourceEnd { pieces.append((occupiedEnd, range.sourceEnd)) }
        } else {
            pieces.append((range.sourceStart, range.sourceEnd))
        }
        pieces.append(replacement)
        pieces.sort { $0.start < $1.start }
        // 元の id は先頭の断片へ継がせる（マージ後も id 継承の先勝ちで保たれ、
        // UI の選択と undo の差分が最小になる）。位置も元の index のまま差し替えることで
        // `merged` の並び（sourceID の初出順）が変わらない。
        let rebuilt = pieces.enumerated().map { offset, piece in
            MosaicApplyRange(id: offset == 0 ? range.id : UUID(),
                             clipID: range.clipID, sourceID: range.sourceID,
                             sourceStart: piece.start, sourceEnd: piece.end)
        }
        var result = existing
        result.replaceSubrange(index...index, with: rebuilt)
        return merged(result)
    }

    /// 指定した id の区間を取り除く。見つからない場合は変更なし。
    public static func removingRange(id: UUID, from ranges: [MosaicApplyRange]) -> [MosaicApplyRange] {
        ranges.filter { $0.id != id }
    }

    /// 合成時刻区間 [from, to) と 1 クリップの交差を素材時刻区間へ写す。
    /// 交差しない場合と潰れた区間は nil。写真素材はクリップ全体を覆う区間に丸める。
    private static func sourceInterval(in span: TimelineMapping.ClipSpan,
                                       from: Double, to: Double,
                                       isPhoto: Bool) -> (start: Double, end: Double)? {
        let overlapStart = max(from, span.start)
        let overlapEnd = min(to, span.end)
        guard overlapStart < overlapEnd else { return nil }
        let clip = span.clip
        guard !isPhoto else { return clip.sourceEnd > 0 ? (0, clip.sourceEnd) : nil }
        let rawStart = clip.sourceStart + (overlapStart - span.start) * clip.rate
        let rawEnd = clip.sourceStart + (overlapEnd - span.start) * clip.rate
        let sourceStart = min(max(rawStart, clip.sourceStart), clip.sourceEnd)
        let sourceEnd = min(max(rawEnd, clip.sourceStart), clip.sourceEnd)
        guard sourceStart < sourceEnd else { return nil }
        return (sourceStart, sourceEnd)
    }

    /// マージ中の 1 区間の作業状態。`index` は入力配列内の位置（id の先勝ち判定に使う）。
    private struct MergeAccumulator {
        var index: Int
        var id: UUID
        var sourceID: UUID
        var start: Double
        var end: Double
    }

    /// **同一 clipID** の重複・隣接区間をマージして正規化する。
    ///
    /// ⚠️ **グループキーは `clipID` であって `sourceID` ではない。** sourceID で束ねると、
    /// 同一素材を分割した隣接 2 クリップの区間が境界で 1 本にマージされ、
    /// 片方の clipID が消える（＝S11 で直したバグが別経路で復活する）。
    ///
    /// マージ結果の id は入力順で最初（`index` 最小）の区間の id を引き継ぐ。
    /// 結果は clipID の初出順・各 clipID 内は sourceStart 昇順で並ぶ。
    /// ソートは同値の sourceStart を入力順でタイブレークし決定的にする
    /// （`sorted(by:)` の安定性は言語仕様上保証されないため）。
    private static func merged(_ ranges: [MosaicApplyRange]) -> [MosaicApplyRange] {
        var order: [UUID] = []
        var groups: [UUID: [(index: Int, range: MosaicApplyRange)]] = [:]
        for (index, range) in ranges.enumerated() {
            if groups[range.clipID] == nil { order.append(range.clipID) }
            groups[range.clipID, default: []].append((index, range))
        }
        var result: [MosaicApplyRange] = []
        for clipID in order {
            guard let group = groups[clipID] else { continue }
            let sorted = group.sorted {
                $0.range.sourceStart == $1.range.sourceStart
                    ? $0.index < $1.index
                    : $0.range.sourceStart < $1.range.sourceStart
            }
            var current: MergeAccumulator?
            for member in sorted {
                if var accumulated = current, member.range.sourceStart <= accumulated.end + mergeTolerance {
                    accumulated.end = max(accumulated.end, member.range.sourceEnd)
                    if member.index < accumulated.index {
                        accumulated.index = member.index
                        accumulated.id = member.range.id
                    }
                    current = accumulated
                } else {
                    if let accumulated = current { result.append(flush(accumulated, clipID: clipID)) }
                    current = MergeAccumulator(index: member.index, id: member.range.id,
                                               sourceID: member.range.sourceID,
                                               start: member.range.sourceStart, end: member.range.sourceEnd)
                }
            }
            if let accumulated = current { result.append(flush(accumulated, clipID: clipID)) }
        }
        return result
    }

    private static func flush(_ accumulated: MergeAccumulator, clipID: UUID) -> MosaicApplyRange {
        MosaicApplyRange(id: accumulated.id, clipID: clipID, sourceID: accumulated.sourceID,
                         sourceStart: accumulated.start, sourceEnd: accumulated.end)
    }

    // MARK: - 全体を覆う区間のファクトリ（S11）

    /// クリップ全体（そのクリップが使っている素材範囲）を覆う適用区間を 1 本作る。
    ///
    /// **新規プロジェクトと旧データ移行の唯一の生成器である。** アプリ層で
    /// `MosaicApplyRange(...)` を直に書かないこと。
    /// 壊れたクリップ（非有限・`sourceStart >= sourceEnd`）では nil。
    public static func fullCoverRange(for clip: TimelineClip) -> MosaicApplyRange? {
        guard clip.sourceStart.isFinite, clip.sourceEnd.isFinite,
              clip.sourceStart < clip.sourceEnd else { return nil }
        return MosaicApplyRange(clipID: clip.id, sourceID: clip.sourceID,
                                sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd)
    }

    /// `fullCoverRange(for:)` をクリップ列へ適用する（壊れたクリップは飛ばす）。
    public static func fullCoverRanges(for clips: [TimelineClip]) -> [MosaicApplyRange] {
        clips.compactMap { fullCoverRange(for: $0) }
    }

    // MARK: - 編集操作の区間追従（S11）

    /// クリップ分割に区間を追従させる。
    ///
    /// `atSourceTime`（= 後半クリップの `sourceStart`。以下 m）を境に、
    /// `splittingClipID` に属する区間を前後のクリップへ振り分ける:
    ///
    /// - `sourceEnd <= m` → 前半へ（id 据え置き）
    /// - `sourceStart >= m` → 後半へ付け替え（id 据え置き）
    /// - m をまたぐ → 2 本に割る。前半片が元 id を継承し、後半片は新規 id
    ///
    /// クリップ使用範囲の外へはみ出した部分（トリム由来で温存されている区間）も
    /// **m だけを基準に**前後へ振り分けるので温存される。他クリップの区間・順序は不変。
    public static func ranges(splittingClipID clipID: UUID,
                              atSourceTime m: Double,
                              frontClipID: UUID,
                              backClipID: UUID,
                              existing: [MosaicApplyRange]) -> [MosaicApplyRange] {
        guard m.isFinite else { return existing }
        return existing.flatMap { range -> [MosaicApplyRange] in
            guard range.clipID == clipID else { return [range] }
            if range.sourceEnd <= m {
                return [MosaicApplyRange(id: range.id, clipID: frontClipID, sourceID: range.sourceID,
                                         sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            if range.sourceStart >= m {
                return [MosaicApplyRange(id: range.id, clipID: backClipID, sourceID: range.sourceID,
                                         sourceStart: range.sourceStart, sourceEnd: range.sourceEnd)]
            }
            return [
                MosaicApplyRange(id: range.id, clipID: frontClipID, sourceID: range.sourceID,
                                 sourceStart: range.sourceStart, sourceEnd: m),
                MosaicApplyRange(clipID: backClipID, sourceID: range.sourceID,
                                 sourceStart: m, sourceEnd: range.sourceEnd)
            ]
        }
    }

    /// クリップ削除に区間を追従させる（**そのクリップの区間は消す**）。
    ///
    /// `clipID` は復活しないので、温存すると帯にも出ず削除もできない永久のゴミになる。
    /// undo は `EditSnapshot.timeline` が状態ごと戻すため復元性は落ちない。
    public static func ranges(removingClipID clipID: UUID,
                              from ranges: [MosaicApplyRange]) -> [MosaicApplyRange] {
        ranges.filter { $0.clipID != clipID }
    }
}
