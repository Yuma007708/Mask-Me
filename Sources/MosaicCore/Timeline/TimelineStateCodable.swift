import Foundation

/// `TimelineState` の永続化（スキーマ版付き Codable）と v1 → v2 移行。
///
/// 状態そのものの編集規則（`TimelineState.swift`）と保存形式の後方互換は
/// 変更理由が別なので、ファイルを分けてある。
extension TimelineState {
    // MARK: - Codable（後方互換）

    private enum CodingKeys: String, CodingKey {
        case clips, transitions, applyRanges, audioItems, textItems, sources, aspectRatio, schemaVersion
    }

    /// `clipID` を持たない v1 の適用区間（デコード専用）。
    ///
    /// `MosaicApplyRange` 自身の Codable に旧形式フォールバックを入れてはならない
    /// （`decodeIfPresent ?? UUID()` はどのクリップとも一致しない sentinel を黙って残す）。
    /// 旧形式の吸収はこの型 + `migratedApplyRanges(legacy:clips:photoSourceIDs:)` の 1 経路だけ。
    private struct LegacyApplyRange: Decodable {
        let id: UUID
        let sourceID: UUID
        let sourceStart: Double
        let sourceEnd: Double
    }

    /// `sources` キーを持たない旧 JSON（S6 より前に保存された下書き）は
    /// 空 = 全素材が動画、としてデコードする。
    ///
    /// `schemaVersion` が無い（= v1）JSON は `migratedApplyRanges(legacy:clips:photoSourceIDs:)` で
    /// 新スキーマへ変換する。**v2 の JSON を v1 と誤認すると「ユーザーが全区間を削除した
    /// 状態」が「全体を覆う 1 本」に化ける**（新仕様の意味が黙って逆転する）ため、
    /// `encode(to:)` は `schemaVersion` を必ず書く。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.clips = try container.decode([TimelineClip].self, forKey: .clips)
        self.transitions = try container.decode([UUID: TransitionSpec].self, forKey: .transitions)
        self.sources = try container.decodeIfPresent([UUID: TimelineSource].self, forKey: .sources) ?? [:]
        // BGM（v3 で追加）。v2 以前の JSON には無いので「BGM 無し」で復元する。
        // **正規化を通すこと。** 手で書き換えられた下書き・将来の不整合が、重なった
        // BGM としてそのまま実行系（composition の insertTimeRange）へ流れないようにする。
        self.audioItems = Self.normalizedAudioItems(
            try container.decodeIfPresent([AudioItem].self, forKey: .audioItems) ?? [])
        // テキスト（v4 で追加）。v3 以前の JSON には無いので「テキスト無し」で復元する。
        // BGM と同じく正規化を通す（手で書き換えられた下書きを実行系へ流さない）。
        self.textItems = Self.normalizedTextItems(
            try container.decodeIfPresent([TextItem].self, forKey: .textItems) ?? [])
        // 出力の画面比率（v5 で追加）。**キーが無い旧下書きは `.source`（素材に合わせる
        // ＝ 従来挙動）で復元する。** 未知の文字列（手書き・将来版で保存された下書き）も
        // `.source` に倒す: ここで throw すると下書きが丸ごと開けなくなるうえ、
        // 出力枠の指定は「見た目の枠」であって欠けても編集内容は失われないため。
        let decodedAspectRatio: TimelineAspectRatio?? = try? container.decodeIfPresent(
            TimelineAspectRatio.self, forKey: .aspectRatio)
        self.aspectRatio = (decodedAspectRatio ?? .source) ?? .source
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if version >= 2 {
            self.applyRanges = try container.decode([MosaicApplyRange].self, forKey: .applyRanges)
        } else {
            let legacy = try container.decode([LegacyApplyRange].self, forKey: .applyRanges)
            self.applyRanges = Self.migratedApplyRanges(
                legacy: legacy, clips: clips, photoSourceIDs: Self.photoSourceIDs(in: sources))
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
        try container.encode(audioItems, forKey: .audioItems)
        try container.encode(textItems, forKey: .textItems)
        try container.encode(sources, forKey: .sources)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
    }

    /// v1 の適用区間を v2（`clipID` アンカー）へ変換する。
    ///
    /// - 旧 `applyRanges` が空 → `fullCoverRanges(for:photoSourceIDs:)`
    ///   （旧仕様の「空 = 全区間 ON」という**意味**を新スキーマで保存する）。
    /// - 非空 → 旧区間 r × クリップ c の交差を `MosaicApplyGate.clippedInterval` で判定し
    ///   （不変条件 I3 と同一式）、交差部分へ**クリップして**クリップごとに 1 本作る。
    ///   id は最初に一致したクリップだけ `r.id` を継承し、以降は新規 UUID。
    /// - どのクリップとも交差しない旧区間は**落とす**。旧実装でも `effectiveRanges` と
    ///   `applySpans` の両方で既に除外されており、帯にもゲートにも効いていなかったので
    ///   観測可能な挙動は変わらない。逆に素材範囲のまま各クリップへ複製すると、
    ///   S11 で直したバグ（隣接クリップへの染み出し）を移行時に自前で再現してしまう。
    ///
    /// **写真クリップだけは交差部分ではなく `[0, clip.sourceEnd)` を作る**（クリップあたり
    /// 1 本まで）。交差部分をそのまま保存すると素材時刻 0 へ丸めるゲートに永久に
    /// ヒットせず、「意味を保存する」はずの移行でモザイクが減る（実測: v1 の写真
    /// クリップ [0,1.5)/[1.5,3.0) を復元すると合成 1.5 秒以降が全 OFF）。
    private static func migratedApplyRanges(legacy: [LegacyApplyRange],
                                            clips: [TimelineClip],
                                            photoSourceIDs: Set<UUID>) -> [MosaicApplyRange] {
        guard !legacy.isEmpty else {
            return MosaicApplyGate.fullCoverRanges(for: clips, photoSourceIDs: photoSourceIDs)
        }
        var result: [MosaicApplyRange] = []
        var coveredPhotoClipIDs: Set<UUID> = []
        for old in legacy {
            var inheritedID = false
            for clip in clips {
                // 交差判定は I3 と同一式にするため、候補を組み立ててから共通ヘルパへ渡す。
                let candidate = MosaicApplyRange(clipID: clip.id, sourceID: old.sourceID,
                                                 sourceStart: old.sourceStart, sourceEnd: old.sourceEnd)
                guard let clipped = MosaicApplyGate.clippedInterval(clip: clip, range: candidate) else { continue }
                let isPhoto = photoSourceIDs.contains(clip.sourceID)
                if isPhoto, !coveredPhotoClipIDs.insert(clip.id).inserted { continue }
                result.append(MosaicApplyRange(id: inheritedID ? UUID() : old.id,
                                               clipID: clip.id, sourceID: old.sourceID,
                                               sourceStart: isPhoto ? 0 : clipped.start,
                                               sourceEnd: isPhoto ? clip.sourceEnd : clipped.end))
                inheritedID = true
            }
        }
        return result
    }
}
