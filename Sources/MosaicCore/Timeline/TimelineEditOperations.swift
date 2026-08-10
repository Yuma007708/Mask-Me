import Foundation

/// タイムラインのクリップ配列に対する編集操作の純関数群。
///
/// すべての関数は入力配列を変更せず、新しい配列を返す。
/// 操作が不正（範囲外・制約違反など）な場合は**元の配列をそのまま返す**ことで、
/// 呼び出し側が「変更されたかどうか」を配列比較だけで判定できるようにしている。
public enum TimelineEditOperations {
    /// クリップ 1 本あたりの最小合成尺（秒）。
    /// 分割・トリムの結果がこれを下回る操作は拒否する。
    public static let minimumClipDuration: Double = 0.1

    /// 指定した合成時刻でクリップを 2 分割する。
    ///
    /// 分割点の素材時刻 m により [sourceStart, m) と [m, sourceEnd) に分け、
    /// 前半は元クリップの `id` を維持、後半は新しい `id` を持つ。
    /// 両者は同じ `sourceID`・`rate`・`originalAudioVolume`・`orientation`・`colorGrade`・
    /// `transform` を引き継ぐ（素材基準の検出キャッシュを分割後も共有するため）。
    ///
    /// **`orientation` の引き継ぎを落とさないこと。** 落とすと「回した動画を分割したら
    /// 後半だけ向きが戻る」だけでなく、後半の顔・矩形モザイクの写像も変わるため、
    /// モザイクが素材からずれて素通しになる。
    ///
    /// 次の場合は分割せず元の配列を返す:
    /// - 合成時刻が範囲外、またはクリップ境界ちょうど（前半が 0 秒になる）
    /// - 分割後のいずれかの側が最小合成尺（`minimumClipDuration`）未満になる
    public static func split(clips: [TimelineClip], at compositionTime: Double) -> [TimelineClip] {
        let mapping = TimelineMapping(clips: clips)
        guard let location = mapping.sourceLocation(at: compositionTime),
              let index = clips.firstIndex(where: { $0.id == location.clipID }),
              let clipStart = mapping.clipStartTime(clipID: location.clipID) else { return clips }
        let clip = clips[index]
        let frontDuration = compositionTime - clipStart
        let backDuration = clip.duration - frontDuration
        guard frontDuration >= minimumClipDuration, backDuration >= minimumClipDuration else { return clips }

        var front = clip
        front.sourceEnd = location.time
        let back = TimelineClip(sourceID: clip.sourceID,
                                sourceStart: location.time,
                                sourceEnd: clip.sourceEnd,
                                originalAudioVolume: clip.originalAudioVolume,
                                rate: clip.rate,
                                orientation: clip.orientation,
                                colorGrade: clip.colorGrade,
                                transform: clip.transform)
        var result = clips
        result.replaceSubrange(index...index, with: [front, back])
        return result
    }

    /// 指定したクリップを取り除く。
    ///
    /// 成功時、他のクリップの内容と相対順序は保存される。
    /// タイムラインを空にはできないため、最後の 1 本を消そうとした場合と
    /// `clipID` が見つからない場合は元の配列を返す。
    public static func remove(clips: [TimelineClip], clipID: UUID) -> [TimelineClip] {
        guard clips.count > 1, clips.contains(where: { $0.id == clipID }) else { return clips }
        return clips.filter { $0.id != clipID }
    }

    /// 指定したクリップを `toIndex` の位置へ並べ替える。
    ///
    /// 成功時、各クリップの内容は保存され順序だけが変わる。
    /// 範囲外の `toIndex` は [0, count-1] にクランプする。
    /// `clipID` が見つからない場合は元の配列を返す。
    public static func move(clips: [TimelineClip], clipID: UUID, toIndex: Int) -> [TimelineClip] {
        guard let fromIndex = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        let destination = min(max(toIndex, 0), clips.count - 1)
        guard fromIndex != destination else { return clips }
        var result = clips
        let clip = result.remove(at: fromIndex)
        result.insert(clip, at: destination)
        return result
    }

    /// 指定したクリップの素材使用範囲を変更する。
    ///
    /// 成功時、`id`・`sourceID`・`rate`・`originalAudioVolume` と他クリップは保存される。
    /// 次の場合は変更せず元の配列を返す:
    /// - `clipID` が見つからない
    /// - `sourceStart` / `sourceEnd` が有限でない（NaN は比較ガードで落ちるが、
    ///   +∞ の `sourceEnd` は素通りして合成尺・写像全体を ∞ に汚染する実測があった）
    /// - `sourceStart` が負、または `sourceStart >= sourceEnd`
    /// - 変更後の合成尺が最小合成尺（`minimumClipDuration`）未満になる
    public static func trim(clips: [TimelineClip], clipID: UUID,
                            sourceStart: Double, sourceEnd: Double) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        guard sourceStart.isFinite, sourceEnd.isFinite,
              sourceStart >= 0, sourceStart < sourceEnd,
              (sourceEnd - sourceStart) / clips[index].rate >= minimumClipDuration else { return clips }
        var result = clips
        result[index].sourceStart = sourceStart
        result[index].sourceEnd = sourceEnd
        return result
    }

    /// 指定したクリップの再生倍率を設定する。
    ///
    /// 倍率は `TimelineClip.rateRange`（0.1〜10）にクランプされる。
    /// 成功時、素材使用範囲と他クリップは保存される（合成尺は倍率に応じて変わる）。
    /// `clipID` が見つからない場合は元の配列を返す。
    public static func setRate(clips: [TimelineClip], clipID: UUID, rate: Double) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        var result = clips
        result[index].rate = TimelineClip.clampedRate(rate)
        return result
    }

    /// 指定したクリップの元音声の音量を設定する。
    ///
    /// 音量は `TimelineClip.volumeRange`（0〜1）にクランプされる。
    /// 成功時、素材使用範囲・倍率と他クリップは保存される（合成尺は変わらない）。
    /// `clipID` が見つからない場合は元の配列を返す（`setRate` と同じ契約）。
    public static func setVolume(clips: [TimelineClip], clipID: UUID, volume: Float) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        var result = clips
        result[index].originalAudioVolume = TimelineClip.clampedVolume(volume)
        return result
    }

    /// 指定したクリップの向き（90 度回転 + 左右反転）を設定する。
    ///
    /// 成功時、素材使用範囲・倍率・音量と他クリップは保存される（合成尺は変わらない）。
    /// `clipID` が見つからない場合は元の配列を返す（`setRate` と同じ契約）。
    public static func setOrientation(clips: [TimelineClip], clipID: UUID,
                                      orientation: ClipOrientation) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        var result = clips
        result[index].orientation = orientation
        return result
    }

    /// 指定したクリップの色調補正（明るさ・コントラスト・彩度・暖かみ）を設定する。
    ///
    /// クランプは `ColorGrade` 自身が担うので、ここでは代入するだけでよい。
    /// 成功時、素材使用範囲・倍率・音量・向きと他クリップは保存される（合成尺は変わらない）。
    /// `clipID` が見つからない場合は元の配列を返す（`setRate` と同じ契約）。
    public static func setColorGrade(clips: [TimelineClip], clipID: UUID,
                                     colorGrade: ColorGrade) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        var result = clips
        result[index].colorGrade = colorGrade
        return result
    }

    /// 指定したクリップの変形（拡大縮小・位置）を設定する。
    ///
    /// クランプは `ClipTransform` 自身が担うので、ここでは代入するだけでよい。
    /// 成功時、素材使用範囲・倍率・音量・向き・色調補正と他クリップは保存される
    /// （合成尺は変わらない）。`clipID` が見つからない場合は元の配列を返す
    /// （`setRate` と同じ契約）。
    public static func setTransform(clips: [TimelineClip], clipID: UUID,
                                    transform: ClipTransform) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        var result = clips
        result[index].transform = transform
        return result
    }

    /// 指定したクリップを複製し、複製先を元クリップの**直後**に挿入する。
    ///
    /// 複製先は新規発番の `id` を持ち、`sourceID`・`sourceStart`・`sourceEnd`・
    /// `rate`・`originalAudioVolume`・`orientation`・`colorGrade`・`transform` は
    /// 元クリップと同じ値を引き継ぐ（素材使用範囲・速度・音量・向き・色調補正・変形の
    /// 設定を引き継ぐ、という一般的な編集アプリの挙動）。`clipID` が見つからない場合は
    /// 元の配列を返す（他の編集操作と同じ「失敗時は無変更」契約）。
    ///
    /// **クリップに設定項目を足したら、ここへ足すのを忘れないこと。** 複製と向きは
    /// 別々の機能として実装されたため、マージした時点では `orientation` が引き継がれず、
    /// 回したクリップを複製すると複製先だけ向きが戻っていた（`split` は
    /// 引き継いでいたので、複製だけが漏れていた）。`colorGrade` / `transform` も
    /// 同じ前科を踏まないよう最初から明示的に列挙してある。
    public static func duplicate(clips: [TimelineClip], clipID: UUID) -> [TimelineClip] {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return clips }
        let original = clips[index]
        let copy = TimelineClip(sourceID: original.sourceID,
                                sourceStart: original.sourceStart,
                                sourceEnd: original.sourceEnd,
                                originalAudioVolume: original.originalAudioVolume,
                                rate: original.rate,
                                orientation: original.orientation,
                                colorGrade: original.colorGrade,
                                transform: original.transform)
        var result = clips
        result.insert(copy, at: index + 1)
        return result
    }

    /// 指定した位置へクリップを挿入する。
    ///
    /// フリーズフレーム挿入（`TimelineState.freezing`）の下請け。分割で生まれた前半・後半の
    /// **間**へクリップを差し込む用途を想定しており、複製・分割のように既存クリップから
    /// 派生させるのではなく、呼び出し側が組み立て済みの `clip` をそのまま挿入する。
    ///
    /// `index` は挿入後の配列上での位置（`0...clips.count` が有効域。`clips.count` は
    /// 末尾への追加に相当する）。範囲外の `index` は元の配列をそのまま返す
    /// （他の編集操作と同じ「失敗時は無変更」契約）。
    public static func insert(clips: [TimelineClip], clip: TimelineClip, at index: Int) -> [TimelineClip] {
        guard index >= 0, index <= clips.count else { return clips }
        var result = clips
        result.insert(clip, at: index)
        return result
    }
}
