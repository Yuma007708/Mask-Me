import Foundation

/// タイムライン編集の単一情報源となる状態（クリップ列 + トランジション + モザイク適用範囲）。
///
/// 編集操作は `TimelineEditOperations` を内部で呼びつつ、クリップ列の変化に合わせて
/// トランジションの整合（付け替え・破棄・duration クランプ）を保つラッパとして提供する。
/// 各操作は失敗時に self をそのまま返す（`TimelineEditOperations` の契約を透過するため、
/// 呼び出し側は「変更されたかどうか」を状態比較だけで判定できる）。
public struct TimelineState: Codable, Equatable, Sendable {
    public var clips: [TimelineClip]
    /// クリップ境界のトランジション。キーは**先行（outgoing）クリップの id**。
    ///
    /// **書き込み経路（S9 時点）**: 編集 API（`settingTransition(afterClipID:kind:duration:)` /
    /// `removingTransition(afterClipID:)`）、下書き v2 のデコード、この `var` への直接代入（テスト・
    /// `MosaicEditorModel.setTimelineForTesting`）。
    ///
    /// クリップ列を変える編集（split / delete / move / trim）を通したときの付け替え・破棄・duration クランプは
    /// `normalizingTransitions` が面倒を見ている。編集 API 側は `maximumTransitionDuration(afterClipID:)` で
    /// 同じ制約へクランプする（UI のスライダー上限もこれを使う）。
    public var transitions: [UUID: TransitionSpec]
    /// モザイク適用範囲（`clipID` + 素材時刻アンカー）。
    ///
    /// **空なら適用なし（全区間 OFF）**。S11 で意味が反転した（旧: 空 = 全区間適用）。新規プロジェクト・素材追加では
    /// `MosaicApplyGate.fullCoverRanges(for:)` が「クリップ全体を覆う区間」を 1 本ずつ自動生成するため、区間 0 本に
    /// 到達する経路は**ユーザーの削除操作だけ**である（不変条件 I5: 自動生成は「新しいクリップが生まれる瞬間」以外で
    /// 走らせないこと）。
    public var applyRanges: [MosaicApplyRange]
    /// 素材メタ情報（キーは素材ID = `TimelineClip.sourceID`）。エントリが無い素材は
    /// 動画（`TimelineSource.Kind.video`）として扱う（kind 導入前のデータとの互換）。
    public var sources: [UUID: TimelineSource]

    public init(clips: [TimelineClip] = [],
                transitions: [UUID: TransitionSpec] = [:],
                applyRanges: [MosaicApplyRange] = [],
                sources: [UUID: TimelineSource] = [:]) {
        self.clips = clips
        self.transitions = transitions
        self.applyRanges = applyRanges
        self.sources = sources
    }

    // MARK: - Codable（後方互換）

    private enum CodingKeys: String, CodingKey {
        case clips, transitions, applyRanges, sources, schemaVersion
    }

    /// 現在の永続化スキーマ版。
    ///
    /// - v1: `MosaicApplyRange` に `clipID` が無く、**空 = 全区間適用**だった。
    /// - v2: `MosaicApplyRange` が `clipID` を持ち、**空 = 適用なし（全区間 OFF）**。
    public static let currentSchemaVersion = 2

    /// `clipID` を持たない v1 の適用区間（デコード専用）。
    ///
    /// `MosaicApplyRange` 自身の Codable に旧形式フォールバックを入れてはならない
    /// （`decodeIfPresent ?? UUID()` はどのクリップとも一致しない sentinel を黙って残す）。
    /// 旧形式の吸収はこの型 + `migratedApplyRanges(legacy:clips:)` の 1 経路だけ。
    private struct LegacyApplyRange: Decodable {
        let id: UUID
        let sourceID: UUID
        let sourceStart: Double
        let sourceEnd: Double
    }

    /// `sources` キーを持たない旧 JSON（S6 より前に保存された下書き）は
    /// 空 = 全素材が動画、としてデコードする。
    ///
    /// `schemaVersion` が無い（= v1）JSON は `migratedApplyRanges(legacy:clips:)` で
    /// 新スキーマへ変換する。**v2 の JSON を v1 と誤認すると「ユーザーが全区間を削除した
    /// 状態」が「全体を覆う 1 本」に化ける**（新仕様の意味が黙って逆転する）ため、
    /// `encode(to:)` は `schemaVersion` を必ず書く。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.clips = try container.decode([TimelineClip].self, forKey: .clips)
        self.transitions = try container.decode([UUID: TransitionSpec].self, forKey: .transitions)
        self.sources = try container.decodeIfPresent([UUID: TimelineSource].self, forKey: .sources) ?? [:]
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if version >= 2 {
            self.applyRanges = try container.decode([MosaicApplyRange].self, forKey: .applyRanges)
        } else {
            let legacy = try container.decode([LegacyApplyRange].self, forKey: .applyRanges)
            self.applyRanges = Self.migratedApplyRanges(legacy: legacy, clips: clips)
        }
    }

    /// **`CodingKeys` に格納プロパティの無い case（`schemaVersion`）を足したので、
    /// Encodable の自動合成は成立しない。手書きが必須である。**
    /// ここで `schemaVersion` を書き忘れると保存した v2 が次回起動で v1 と誤認され、
    /// 区間 0 本（＝ユーザーが全削除した状態）が「全体を覆う 1 本」へ復活してしまう。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(clips, forKey: .clips)
        try container.encode(transitions, forKey: .transitions)
        try container.encode(applyRanges, forKey: .applyRanges)
        try container.encode(sources, forKey: .sources)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    }

    /// v1 の適用区間を v2（`clipID` アンカー）へ変換する。
    ///
    /// - 旧 `applyRanges` が空 → `fullCoverRanges(for: clips)`
    ///   （旧仕様の「空 = 全区間 ON」という**意味**を新スキーマで保存する）。
    /// - 非空 → 旧区間 r × クリップ c の交差を `MosaicApplyGate.clippedInterval` で判定し
    ///   （不変条件 I3 と同一式）、交差部分へ**クリップして**クリップごとに 1 本作る。
    ///   id は最初に一致したクリップだけ `r.id` を継承し、以降は新規 UUID。
    /// - どのクリップとも交差しない旧区間は**落とす**。旧実装でも `effectiveRanges` と
    ///   `applySpans` の両方で既に除外されており、帯にもゲートにも効いていなかったので
    ///   観測可能な挙動は変わらない。逆に素材範囲のまま各クリップへ複製すると、
    ///   S11 で直したバグ（隣接クリップへの染み出し）を移行時に自前で再現してしまう。
    private static func migratedApplyRanges(legacy: [LegacyApplyRange],
                                            clips: [TimelineClip]) -> [MosaicApplyRange] {
        guard !legacy.isEmpty else { return MosaicApplyGate.fullCoverRanges(for: clips) }
        var result: [MosaicApplyRange] = []
        for old in legacy {
            var inheritedID = false
            for clip in clips {
                // 交差判定は I3 と同一式にするため、候補を組み立ててから共通ヘルパへ渡す。
                let candidate = MosaicApplyRange(clipID: clip.id, sourceID: old.sourceID,
                                                 sourceStart: old.sourceStart, sourceEnd: old.sourceEnd)
                guard let clipped = MosaicApplyGate.clippedInterval(clip: clip, range: candidate) else { continue }
                result.append(MosaicApplyRange(id: inheritedID ? UUID() : old.id,
                                               clipID: clip.id, sourceID: old.sourceID,
                                               sourceStart: clipped.start, sourceEnd: clipped.end))
                inheritedID = true
            }
        }
        return result
    }

    // MARK: - 素材種別（写真クリップの時刻規則）

    /// 素材の種別。未登録の素材IDは動画として扱う。
    public func sourceKind(of sourceID: UUID) -> TimelineSource.Kind {
        sources[sourceID]?.kind ?? .video
    }

    /// 写真素材の素材ID集合（`VideoMosaicExporter` へ渡す clamp 対象）。
    public var photoSourceIDs: Set<UUID> {
        Set(sources.values.filter { $0.kind == .photo }.map(\.id))
    }

    /// 写真素材の素材時刻を 0 に clamp する（動画素材はそのまま）。
    ///
    /// 写真クリップは全フレーム同一なので、検出キャッシュは素材時刻 0 の 1 エントリ
    /// だけを正とする。lookup・ライブ検出の書き込みの入口（写像の後）でこの clamp を
    /// 通すことで、t=0 に 1 回 seed した検出が全フレームにヒットし、2 回目以降の
    /// 実検出・重複 submit が発生しない。
    public func clampedSourceTime(_ time: Double, sourceID: UUID) -> Double {
        sourceKind(of: sourceID) == .photo ? 0 : time
    }

    /// この状態に対応する写像（トランジションの重なりを含む）。
    public var mapping: TimelineMapping { TimelineMapping(clips: clips, transitions: transitions) }

    // MARK: - 編集操作

    /// 表示タイムライン（トランジションの重なり込み = `mapping` の合成時刻）の時刻で
    /// クリップを 2 分割する。**分割対象は帰属規則（重なり内は incoming 側）が決める。**
    ///
    /// 内部で `TimelineMapping.editTime(forDisplayTime:)` により編集タイムラインの時刻へ
    /// 変換してから `splitting(at:)` を呼ぶ。範囲外の時刻では self をそのまま返す。
    ///
    /// **UI からはこれを使わないこと。** トランジションの重なり区間では「選択中クリップ」と
    /// 「帰属規則が選ぶクリップ」が食い違い、選択と別のクリップが割れる（実測: 6s+6s /
    /// crossfade 2.0s の重なり [4,6) で clipA を選び 5.0 秒で分割すると clipB が割れた）。
    /// UI は対象を明示する `splitting(clipID:atDisplayTime:)` と、その活性判定
    /// `canSplit(clipID:atDisplayTime:)` を使う。
    public func splitting(atDisplayTime displayTime: Double) -> TimelineState {
        guard let editTime = mapping.editTime(forDisplayTime: displayTime) else { return self }
        return splitting(at: editTime)
    }

    /// 指定したクリップを、表示タイムラインの時刻で 2 分割する。
    ///
    /// 帰属規則に頼らず `clipID` のクリップを割るため、トランジションの重なり区間でも
    /// 「選択したクリップが割れる」ことが保証される。分割できない場合は self を返す。
    public func splitting(clipID: UUID, atDisplayTime displayTime: Double) -> TimelineState {
        guard let editTime = splitEditTime(clipID: clipID, displayTime: displayTime) else { return self }
        return splitting(at: editTime)
    }

    /// `splitting(clipID:atDisplayTime:)` が実際に分割するかどうか。
    ///
    /// **ボタンの活性判定はこれを使うこと**（判定と対象が別の規則で決まると、
    /// 押せるのに何も起きない・選択と別のクリップが割れるといった食い違いになる）。
    public func canSplit(clipID: UUID, atDisplayTime displayTime: Double) -> Bool {
        splitEditTime(clipID: clipID, displayTime: displayTime) != nil
    }

    /// 分割に使う**編集タイムライン**の時刻（分割できない場合は nil）。
    /// 判定（`canSplit`）と実行（`splitting`）の唯一の情報源。
    ///
    /// クリップ開始時刻は `TimelineEditOperations.split` が内部で使う
    /// `TimelineMapping.clipStartTime`（先頭からの `duration` 累算）と**同じ順序で
    /// 累算する**こと。別の式で作ると 1 ulp のずれで最小尺の境界ちょうどで
    /// 判定と実行が食い違う（押せるのに割れない、が復活する）。
    private func splitEditTime(clipID: UUID, displayTime: Double) -> Double? {
        guard displayTime.isFinite,
              let span = mapping.clipSpans.first(where: { $0.clip.id == clipID }) else { return nil }
        var editStart = 0.0
        for clip in clips {
            if clip.id == clipID { break }
            editStart += clip.duration
        }
        let editTime = editStart + (displayTime - span.start)
        let minimum = TimelineEditOperations.minimumClipDuration
        // split 側と同じ引き算で前半尺を出す（`editTime - editStart` が `displayTime -
        // span.start` と bit 一致するとは限らないため、こちらの値で判定する）。
        let front = editTime - editStart
        guard front >= minimum, span.clip.duration - front >= minimum else { return nil }
        return editTime
    }

    /// **編集タイムライン**（重なりを含まない = `TimelineMapping(clips:)` の写像）の合成時刻でクリップを 2 分割する。
    ///
    /// 注意: この時刻は `mapping`（重なり込みの表示タイムライン）の合成時刻とはトランジションの合計 duration 分ずれる。
    /// 表示時刻から分割する場合は `splitting(atDisplayTime:)` を使うこと。分割対象クリップが先行側だったトランジションは
    /// **後半クリップの id に付け替える**（その境界は後半と次クリップの間に残るため）。前半と後半の間には新規
    /// トランジションを付けない。分割で短くなったクリップに対しては duration 制約のクランプ/破棄も適用される。
    ///
    /// **適用区間も追従させる**（`MosaicApplyGate.ranges(splittingClipID:...)`）。区間は `clipID` アンカーなので、
    /// 分割で新しい clipID が生まれた側へ付け替えないと後半クリップの区間が丸ごと効かなくなる。
    public func splitting(at compositionTime: Double) -> TimelineState {
        let newClips = TimelineEditOperations.split(clips: clips, at: compositionTime)
        guard newClips != clips else { return self }
        let oldIDs = Set(clips.map(\.id))
        guard let backIndex = newClips.firstIndex(where: { !oldIDs.contains($0.id) }),
              backIndex > 0 else { return self }
        var newTransitions = transitions
        let front = newClips[backIndex - 1]
        let back = newClips[backIndex]
        if let spec = newTransitions.removeValue(forKey: front.id) {
            newTransitions[back.id] = spec
        }
        // 分割点の素材時刻 = 後半クリップの sourceStart（`TimelineEditOperations.split`）。
        let newRanges = MosaicApplyGate.ranges(splittingClipID: front.id,
                                               atSourceTime: back.sourceStart,
                                               frontClipID: front.id, backClipID: back.id,
                                               existing: applyRanges)
        return replacing(clips: newClips, transitions: newTransitions, applyRanges: newRanges)
            .normalizingTransitions()
    }

    /// 指定したクリップを取り除く。
    ///
    /// 削除クリップが先行側・後続側どちらであったトランジションも破棄する（削除で新たに隣接するペアへ引き継がない）。
    ///
    /// **そのクリップの適用区間も消す**（`MosaicApplyGate.ranges(removingClipID:from:)`）。トリム由来の孤児区間は
    /// 温存するのに削除だけ消すのは、`clipID` が二度と復活しないため。温存すると帯にも出ず削除もできない永久の
    /// ゴミになる。undo は `EditSnapshot.timeline` が状態ごと戻すので復元性は落ちない。
    public func removing(clipID: UUID) -> TimelineState {
        let newClips = TimelineEditOperations.remove(clips: clips, clipID: clipID)
        guard newClips != clips else { return self }
        var newTransitions = transitions
        newTransitions.removeValue(forKey: clipID)
        if let index = clips.firstIndex(where: { $0.id == clipID }), index > 0 {
            newTransitions.removeValue(forKey: clips[index - 1].id)
        }
        let newRanges = MosaicApplyGate.ranges(removingClipID: clipID, from: applyRanges)
        return replacing(clips: newClips, transitions: newTransitions, applyRanges: newRanges)
    }

    /// 指定したクリップを `toIndex` の位置へ並べ替える。
    ///
    /// 移動によって隣接ペアが分離したトランジションは全て破棄し、
    /// 移動後も「同じ先行→同じ後続」の隣接が保たれたものだけを残す。
    ///
    /// **適用区間には意図的に何もしない。** `clipID` も素材時刻も変わらないので、
    /// 区間は書き換えなくても自動追従する（`trimming` / `settingRate` も同じ）。
    public func moving(clipID: UUID, toIndex: Int) -> TimelineState {
        let newClips = TimelineEditOperations.move(clips: clips, clipID: clipID, toIndex: toIndex)
        guard newClips != clips else { return self }
        var newTransitions: [UUID: TransitionSpec] = [:]
        for (key, spec) in transitions {
            guard let oldIndex = clips.firstIndex(where: { $0.id == key }), oldIndex + 1 < clips.count,
                  let newIndex = newClips.firstIndex(where: { $0.id == key }), newIndex + 1 < newClips.count,
                  newClips[newIndex + 1].id == clips[oldIndex + 1].id else { continue }
            newTransitions[key] = spec
        }
        return replacing(clips: newClips, transitions: newTransitions)
    }

    /// 指定したクリップの素材使用範囲を変更する。
    ///
    /// クリップ尺が縮んだ結果 `duration > min(両クリップ合成尺)/2` を破るトランジションは
    /// duration をクランプし、クランプ後 `TransitionSpec.minimumDuration` 未満になるものは破棄する。
    ///
    /// **適用区間には意図的に何もしない。** `clipID` 不変・素材時刻アンカーなので、
    /// トリムで一時的にクリップ使用範囲から外れた区間はそのまま温存され
    /// （`effectiveRanges` がゲートから外す）、トリムを戻せば復活する。
    public func trimming(clipID: UUID, sourceStart: Double, sourceEnd: Double) -> TimelineState {
        let newClips = TimelineEditOperations.trim(clips: clips, clipID: clipID,
                                                   sourceStart: sourceStart, sourceEnd: sourceEnd)
        guard newClips != clips else { return self }
        return replacing(clips: newClips, transitions: transitions)
            .normalizingTransitions()
    }

    /// 指定したクリップの再生倍率を設定する。トランジションのクランプ規則は `trimming` と同じ。
    ///
    /// **適用区間には意図的に何もしない。** 区間は素材時刻アンカーなので、速度を変えても「素材のどこにモザイクを
    /// 掛けるか」は変わらない（合成時刻での見かけの位置だけが `applySpans` の写像で伸縮する）。
    public func settingRate(clipID: UUID, rate: Double) -> TimelineState {
        let newClips = TimelineEditOperations.setRate(clips: clips, clipID: clipID, rate: rate)
        guard newClips != clips else { return self }
        return replacing(clips: newClips, transitions: transitions)
            .normalizingTransitions()
    }

    /// 指定したクリップの元音声の音量（0〜1 にクランプ）を設定する。
    ///
    /// **`normalizingTransitions()` は通さない。** 音量はクリップの合成尺（`duration`）を一切変えないので、
    /// トランジションのクランプ条件 `duration <= min(両クリップ合成尺)/2` に影響しない（通すと「音量を触っただけで
    /// 設定済みのトランジションが黙って作り直される」副作用が生まれる）。適用区間に何もしないのは `settingRate` と
    /// 同じ理由（素材時刻アンカー）。
    public func settingVolume(clipID: UUID, volume: Float) -> TimelineState {
        let newClips = TimelineEditOperations.setVolume(clips: clips, clipID: clipID, volume: volume)
        guard newClips != clips else { return self }
        return replacing(clips: newClips, transitions: transitions)
    }

    /// クリップをタイムライン末尾へ追加する（素材メタも同時登録できる）。
    ///
    /// 写真クリップの追加（`PhotoClipEncoder` でエンコード済みの静止 mp4）が主用途。使用範囲が壊れているクリップ
    /// （非有限・`sourceStart >= sourceEnd`）では self をそのまま返す（他の編集操作と同じ「失敗時は self」契約）。
    ///
    /// **追加クリップにも「全体を覆う適用区間」を 1 本自動生成する**（既定 true）。新仕様では区間 0 本 = OFF なので、
    /// 生成しないと追加素材にだけモザイクが乗らない。`appendVideoClip` が「新素材の顔が 1 つも選択されていないと
    /// その追加クリップだけモザイクが乗らない」ことを理由に追加素材の顔を全部自動選択している配慮を、区間側で
    /// 打ち消さないための対応でもある。ここは**不変条件 I5 が許す「新しいクリップが生まれる瞬間」**の 1 つ。
    ///
    /// - Parameter coveringWithApplyRange: false にすると区間を生成しない（生成点を明示的に選べるように
    ///   するためのフラグ。既定は true）。
    public func appending(clip: TimelineClip, source: TimelineSource? = nil,
                          coveringWithApplyRange: Bool = true) -> TimelineState {
        guard clip.sourceStart.isFinite, clip.sourceEnd.isFinite,
              clip.sourceStart < clip.sourceEnd else { return self }
        var result = self
        result.clips.append(clip)
        if let source { result.sources[source.id] = source }
        if coveringWithApplyRange, let range = MosaicApplyGate.fullCoverRange(for: clip) {
            result.applyRanges.append(range)
        }
        return result
    }

    // MARK: - トランジションの編集（S9）

    /// クリップ境界に設定できるトランジションの最大 duration（秒）。
    ///
    /// `= min(両クリップ合成尺)/2`。設定できない境界（`clipID` が不在・末尾クリップ・
    /// 上限が `TransitionSpec.minimumDuration` 未満）では nil を返す。
    /// UI はこれをスライダーの上限に使い、「設定したのに黙って消える」状態を避ける。
    public func maximumTransitionDuration(afterClipID clipID: UUID) -> Double? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }), index + 1 < clips.count else { return nil }
        let cap = min(clips[index].duration, clips[index + 1].duration) / 2
        guard cap.isFinite, cap >= TransitionSpec.minimumDuration else { return nil }
        return cap
    }

    /// 指定した先行クリップの直後の境界にトランジションを設定する（種類・長さの変更も同じ入口）。
    ///
    /// duration は `maximumTransitionDuration(afterClipID:)` へクランプする。
    /// クランプ後に `TransitionSpec.minimumDuration` を下回る境界では設定せず self を返す
    /// （他の編集操作と同じ「失敗時は self」契約）。
    public func settingTransition(afterClipID clipID: UUID,
                                  kind: TransitionKind,
                                  duration: Double) -> TimelineState {
        guard let cap = maximumTransitionDuration(afterClipID: clipID), duration.isFinite else { return self }
        let clamped = min(max(duration, TransitionSpec.minimumDuration), cap)
        var result = self
        result.transitions[clipID] = TransitionSpec(kind: kind, duration: clamped)
        return result
    }

    /// 指定した先行クリップの直後の境界からトランジションを取り除く。
    /// 設定が無ければ self を返す。
    public func removingTransition(afterClipID clipID: UUID) -> TimelineState {
        guard transitions[clipID] != nil else { return self }
        var result = self
        result.transitions.removeValue(forKey: clipID)
        return result
    }

    // MARK: - モザイク適用区間の編集（S9）

    /// 合成時刻の区間 [from, to) をモザイク適用区間として追加する。
    ///
    /// 素材時刻アンカーへの分解・重複マージは `MosaicApplyGate` が行う
    /// （合成時刻のまま保存する誤実装を UI 側で書けないようにするための唯一の入口）。
    public func addingApplyRange(fromCompositionTime from: Double, to: Double) -> TimelineState {
        guard from.isFinite, to.isFinite, from < to else { return self }
        var result = self
        result.applyRanges = MosaicApplyGate.ranges(addingCompositionInterval: from, to: to,
                                                    mapping: mapping, existing: applyRanges,
                                                    photoSourceIDs: photoSourceIDs)
        return result
    }

    /// 指定した適用区間を取り除く。
    public func removingApplyRange(id: UUID) -> TimelineState {
        let newRanges = MosaicApplyGate.removingRange(id: id, from: applyRanges)
        guard newRanges.count != applyRanges.count else { return self }
        var result = self
        result.applyRanges = newRanges
        return result
    }

    /// 掴んだセグメント（`id` の適用区間 × `clipID` のクリップ）を、新しい合成区間で
    /// 置き換える（端ドラッグの確定）。
    ///
    /// **差し替えは素材時刻で行う**（`MosaicApplyGate.ranges(replacingRangeID:...)`）。
    /// 当該クリップが使っている素材区間だけが置き換わり、クリップ使用範囲外の素材区間は
    /// 温存されるため、UI は掴んだセグメントの情報だけを渡せばよい。
    /// 「合成時刻の区間列から作り直す」旧実装が構造的に落としていた区間の詳細は
    /// `MosaicApplyRange` 型の doc を参照。
    ///
    /// 縮める操作も表現できる。差し替え結果が現状と同じ（ドラッグ量 0）なら self を返す。
    /// マージで id が変わり得るので、UI は id を保持し続けず編集後に引き直すこと。
    public func replacingApplyRange(id: UUID,
                                    clipID: UUID,
                                    compositionInterval interval: CompositionInterval) -> TimelineState {
        let newRanges = MosaicApplyGate.ranges(replacingRangeID: id, clipID: clipID,
                                               compositionInterval: interval,
                                               mapping: mapping, existing: applyRanges,
                                               photoSourceIDs: photoSourceIDs)
        guard newRanges != applyRanges else { return self }
        var result = self
        result.applyRanges = newRanges
        return result
    }

    /// clips / transitions（と必要なら applyRanges）を差し替えた新しい状態。
    ///
    /// 編集操作が `TimelineState(clips:transitions:applyRanges:)` を直接呼ぶと
    /// `sources`（素材メタ）が黙って落ちるため、内部の再構築はこのヘルパに集約する。
    /// `applyRanges` を省略すると現在の区間をそのまま維持する
    /// （`moving` / `trimming` / `settingRate` は区間を書き換えない）。
    private func replacing(clips newClips: [TimelineClip],
                           transitions newTransitions: [UUID: TransitionSpec],
                           applyRanges newApplyRanges: [MosaicApplyRange]? = nil) -> TimelineState {
        var result = self
        result.clips = newClips
        result.transitions = newTransitions
        if let newApplyRanges { result.applyRanges = newApplyRanges }
        return result
    }

    // MARK: - 不変条件

    /// 不変条件を満たしているかを返す（デバッグ/テスト用）。
    ///
    /// - transitions のキーが実在する**非末尾**クリップであること
    /// - 各トランジションが有限の `0 < duration <= min(両クリップ合成尺)/2`（浮動小数点誤差は許容）
    /// - applyRanges が全て有限の `sourceStart < sourceEnd`
    ///   （NaN は比較を素通りしてゲート判定を黙って全滅させるため、ここで明示的に弾く）
    /// - 各適用区間の `clipID` が実在クリップを指し、その `sourceID` が一致すること
    ///   （食い違うとその区間は永久に効かない。S11 の `clipID` アンカーの不変条件）
    public func validate() -> Bool {
        for (key, spec) in transitions {
            guard let index = clips.firstIndex(where: { $0.id == key }), index + 1 < clips.count,
                  spec.duration.isFinite, spec.duration > 0,
                  spec.duration <= min(clips[index].duration, clips[index + 1].duration) / 2 + 1e-9
            else { return false }
        }
        for range in applyRanges {
            guard range.sourceStart.isFinite, range.sourceEnd.isFinite,
                  range.sourceStart < range.sourceEnd else { return false }
            guard let clip = clips.first(where: { $0.id == range.clipID }),
                  clip.sourceID == range.sourceID else { return false }
        }
        // 素材メタは「キー = TimelineSource.id」で引く辞書。食い違うと kind の参照が
        // 黙って .video フォールバックに落ちるため、不変条件として明示する。
        for (key, source) in sources where source.id != key {
            return false
        }
        return true
    }

    /// トランジションを duration 制約に合わせて正規化する。
    ///
    /// ペアが実在しない（キーが末尾または不在の）ものは破棄、
    /// `duration > min(両クリップ合成尺)/2` はクランプ、
    /// クランプ後 `TransitionSpec.minimumDuration` 未満になるものは破棄する。
    private func normalizingTransitions() -> TimelineState {
        var newTransitions: [UUID: TransitionSpec] = [:]
        for (key, spec) in transitions {
            guard let index = clips.firstIndex(where: { $0.id == key }),
                  index + 1 < clips.count else { continue }
            var adjusted = spec
            adjusted.duration = min(spec.duration, min(clips[index].duration, clips[index + 1].duration) / 2)
            guard adjusted.duration >= TransitionSpec.minimumDuration else { continue }
            newTransitions[key] = adjusted
        }
        var result = self
        result.transitions = newTransitions
        return result
    }
}
