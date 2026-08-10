import Foundation

/// `TimelineState` の不変条件チェック（デバッグ/テスト用）。
///
/// 本体（`TimelineState.swift`）が file_length の閾値に張り付いているため分冊してある。
extension TimelineState {
    /// 不変条件を満たしているかを返す。
    ///
    /// - transitions のキーが実在する**非末尾**クリップであること
    /// - 各トランジションが有限の `0 < duration <= min(両クリップ合成尺)/2`（浮動小数点誤差は許容）
    /// - applyRanges が全て有限の `sourceStart < sourceEnd`
    ///   （NaN は比較を素通りしてゲート判定を黙って全滅させるため、ここで明示的に弾く）
    /// - 各適用区間の `clipID` が実在クリップを指し、その `sourceID` が一致すること
    ///   （食い違うとその区間は永久に効かない。S11 の `clipID` アンカーの不変条件）
    /// - **写真クリップの適用区間は `sourceStart == 0`**（`MosaicApplyRange` 型 doc の不変条件）。
    ///   写真の素材時刻は `clampedSourceTime` が常に 0 へ丸めるため、`sourceStart > 0` の区間は
    ///   ゲートに**絶対にヒットしない**（帯だけ出てモザイクが消える I1 違反）。
    ///   区間生成器（`fullCoverRange` / 分割追従 / v1 移行）の写真扱いの退行はここで落ちる。
    /// - 素材メタ辞書のキーが `TimelineSource.id` と一致すること
    public func validate() -> Bool {
        validateTransitions() && validateApplyRanges() && validateClipAudioMuteRanges()
            && validateClipDuckRanges() && validateAudioItems() && validateTextItems()
            && validateSources() && validateColorGrades()
    }

    /// 各クリップの色調補正が許容範囲に収まっていること。
    ///
    /// `ColorGrade` は `didSet`/`init`/`init(from:)` の 3 経路すべてでクランプしているため
    /// 通常はここで落ちることは無い安全網だが、`TimelineClip.colorGrade` へ直接代入する
    /// テストコード（フューザ等）が将来 `ColorGrade` の内部を迂回しないことの機械的な
    /// 裏取りとして置く（他の値域チェック（`validateApplyRanges` 等）と同じ立て付け）。
    private func validateColorGrades() -> Bool {
        for clip in clips {
            let grade = clip.colorGrade
            guard ColorGrade.brightnessRange.contains(grade.brightness),
                  ColorGrade.contrastRange.contains(grade.contrast),
                  ColorGrade.saturationRange.contains(grade.saturation),
                  ColorGrade.warmthRange.contains(grade.warmth) else { return false }
        }
        return true
    }

    /// トランジションのキーが実在する非末尾クリップで、長さが両隣の半分以下であること。
    private func validateTransitions() -> Bool {
        for (key, spec) in transitions {
            guard let index = clips.firstIndex(where: { $0.id == key }), index + 1 < clips.count,
                  spec.duration.isFinite, spec.duration > 0,
                  spec.duration <= min(clips[index].duration, clips[index + 1].duration) / 2 + 1e-9
            else { return false }
        }
        return true
    }

    /// 適用区間が実在クリップを指し、素材が一致し、写真は 0 始まりであること。
    private func validateApplyRanges() -> Bool {
        for range in applyRanges {
            guard range.sourceStart.isFinite, range.sourceEnd.isFinite,
                  range.sourceStart < range.sourceEnd else { return false }
            guard let clip = clips.first(where: { $0.id == range.clipID }),
                  clip.sourceID == range.sourceID else { return false }
            guard sourceKind(of: clip.sourceID) != .photo || range.sourceStart == 0 else { return false }
        }
        return true
    }

    /// 消音区間が実在クリップを指し、素材が一致し、写真は 0 始まりで、
    /// **同じクリップ内で重ならず正規化済み**であること（`ClipAudioMuteGate.merged` の契約）。
    /// 重なりを許すと、端ドラッグ・移動で片方だけ掴んだときに「消したはずの区間が
    /// 裏に残る」状態になる（`MosaicApplyRange` の同種の不変条件と同じ理由）。
    private func validateClipAudioMuteRanges() -> Bool {
        for range in clipAudioMuteRanges {
            guard range.sourceStart.isFinite, range.sourceEnd.isFinite,
                  range.sourceStart < range.sourceEnd else { return false }
            guard let clip = clips.first(where: { $0.id == range.clipID }),
                  clip.sourceID == range.sourceID else { return false }
            guard sourceKind(of: clip.sourceID) != .photo || range.sourceStart == 0 else { return false }
        }
        for (_, group) in Dictionary(grouping: clipAudioMuteRanges, by: \.clipID) {
            let sorted = group.sorted { $0.sourceStart < $1.sourceStart }
            for index in 1..<sorted.count where sorted[index].sourceStart < sorted[index - 1].sourceEnd - 1e-9 {
                return false
            }
        }
        return true
    }

    /// 声区間（ダッキング根拠）が実在クリップを指し、素材が一致し、写真は 0 始まりで、
    /// **同じクリップ内で重ならず正規化済み**であること。`validateClipAudioMuteRanges` と
    /// 同じ規則（`ClipDuckGate.merged` の契約）。
    private func validateClipDuckRanges() -> Bool {
        for range in clipDuckRanges {
            guard range.sourceStart.isFinite, range.sourceEnd.isFinite,
                  range.sourceStart < range.sourceEnd else { return false }
            guard let clip = clips.first(where: { $0.id == range.clipID }),
                  clip.sourceID == range.sourceID else { return false }
            guard sourceKind(of: clip.sourceID) != .photo || range.sourceStart == 0 else { return false }
        }
        for (_, group) in Dictionary(grouping: clipDuckRanges, by: \.clipID) {
            let sorted = group.sorted { $0.sourceStart < $1.sourceStart }
            for index in 1..<sorted.count where sorted[index].sourceStart < sorted[index - 1].sourceEnd - 1e-9 {
                return false
            }
        }
        return true
    }

    /// BGM が昇順・非重複で、音量が 0...1 に、フェードが `duration / 2` 以下に
    /// 収まること（I-A1〜I-A4）。
    ///
    /// **合成尺との関係はここでは見ない。** クリップを消して縮んだタイムラインから
    /// はみ出した BGM は不正ではなく温存対象である（`AudioItem` 型の doc）。
    private func validateAudioItems() -> Bool {
        var previousEnd = -Double.infinity
        for item in audioItems {
            guard item.sourceStart.isFinite, item.sourceEnd.isFinite,
                  item.compositionStart.isFinite,
                  item.sourceStart >= 0, item.compositionStart >= 0,
                  item.duration >= AudioItem.minimumDuration,
                  item.volume >= 0, item.volume <= 1 else { return false }
            guard item.fadeInDuration.isFinite, item.fadeOutDuration.isFinite,
                  item.fadeInDuration >= 0, item.fadeOutDuration >= 0,
                  item.fadeInDuration <= item.duration / 2 + 1e-9,
                  item.fadeOutDuration <= item.duration / 2 + 1e-9 else { return false }
            guard item.compositionStart >= previousEnd - 1e-9 else { return false }
            previousEnd = item.compositionEnd
        }
        return true
    }

    /// テキストが昇順で、文面・位置・スタイルが有効域に収まること。
    ///
    /// **重なりは許す**（複数の文字を同時に出せる。BGM との違い）ので順序だけを見る。
    ///
    /// **`fontSize` の上限判定は `normalizedTextItems` と同じ 1 本
    /// （`TextItemRole.maximumFontSize`）を見る。** 二重に書くと「正規化は通すが
    /// validate は落ちる」状態を作れてしまう。`.sticker` は文字数も 1（書記素
    /// クラスタ 1 個）まで。
    private func validateTextItems() -> Bool {
        var previousStart = -Double.infinity
        for item in textItems {
            guard item.compositionStart.isFinite, item.duration.isFinite,
                  item.compositionStart >= 0,
                  item.duration >= TextItem.minimumDuration,
                  !item.text.isEmpty,
                  item.text.count <= TextItem.maximumTextLength,
                  item.center.isFinite,
                  item.center.x >= 0, item.center.x <= 1,
                  item.center.y >= 0, item.center.y <= 1,
                  item.style == item.style.clamped(maximumFontSize: item.role.maximumFontSize)
            else { return false }
            guard item.role != .sticker || item.text.count == 1 else { return false }
            guard item.compositionStart >= previousStart - 1e-9 else { return false }
            previousStart = item.compositionStart
        }
        return true
    }

    /// 素材メタが「キー = TimelineSource.id」で引ける辞書であること。
    /// 食い違うと kind の参照が黙って .video フォールバックに落ちる。
    private func validateSources() -> Bool {
        for (key, source) in sources where source.id != key { return false }
        return true
    }
}
