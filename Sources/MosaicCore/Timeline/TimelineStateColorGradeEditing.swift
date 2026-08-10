import Foundation

/// クリップの**色調補正**（明るさ・コントラスト・彩度・暖かみ）編集と、
/// 合成時刻からの参照（トランジション重なり込み）。
///
/// `TimelineState.swift` 本体から分離してあるのは、あちらが `file_length`（500 行）の
/// 上限に張り付いているため（`TimelineStateOrientationEditing` / `TimelineStateDuplication`
/// と同じ分け方）。
extension TimelineState {
    /// 指定したクリップの色調補正を設定する。
    ///
    /// クランプは `ColorGrade` 自身が担う（`init` / `didSet` / `init(from:)` の 3 経路）ので、
    /// ここでは何もクランプしない。**`normalizingTransitions()` は通さない**
    /// （`settingVolume` / `settingOrientation` と同じ理由。色調補正は合成尺 `duration` を
    /// 一切変えないので、トランジションのクランプ条件に影響しない）。適用区間・消音区間にも
    /// 何もしない（素材時刻アンカーなので、色調補正を変えても「素材のどこにモザイクを
    /// 掛けるか／どこを消音するか」は変わらない）。
    public func settingColorGrade(clipID: UUID, colorGrade: ColorGrade) -> TimelineState {
        let newClips = TimelineEditOperations.setColorGrade(
            clips: clips, clipID: clipID, colorGrade: colorGrade)
        guard newClips != clips else { return self }
        return replacing(clips: newClips, transitions: transitions)
    }

    /// 指定した合成時刻に効く色調補正（純関数）。
    ///
    /// `mapping.sourceLocations(at:)` を使う（顔座標の写像と同じ経路。ここで独自に
    /// 「重なっているか」を判定し直さない）:
    /// - 0 件（範囲外の時刻）: `.identity`
    /// - 1 件（重なり外）: そのクリップの `colorGrade` をそのまま返す
    /// - 2 件（トランジションの重なり）: 先行（outgoing）→後続（incoming）それぞれの
    ///   `colorGrade` を、返ってくる `progress`（0 で先行、1 で後続。顔座標の写像が
    ///   使っているのと同じ値）で `ColorGrade.blend` する
    ///
    /// **重なり中の補間は近似である。** 「素材ごとに正しく合成した色」ではなく
    /// 「4 つのパラメータをそれぞれ線形補間した結果」でしかない。たとえば warmth=+1 の
    /// クリップから warmth=-1 のクリップへクロスフェードする場合、t=0.5 では
    /// warmth=0（無補正）相当になるが、これは「2 つの色調補正済み映像を実際にブレンドした
    /// 見え方」と一致する保証はない（`apply(r:g:b:)` は非線形なので、パラメータの補間と
    /// 出力画素の補間は一般に一致しない）。UI プレビューの滑らかさのための近似であり、
    /// 書き出しの色の正しさを厳密に保証するものではないことに注意。
    /// **手順そのものは `ColorGradeResolver.resolve` にある。** ここはクリップの
    /// 引き方（`clips` から探す）を渡すだけの薄いラッパ。書き出し側は同じ
    /// `resolve` を別の引き方（`[UUID: ColorGrade]`）で呼ぶ。
    public func colorGrade(atComposition compositionTime: Double) -> ColorGrade {
        ColorGradeResolver.resolve(mapping: mapping, at: compositionTime) { clipID in
            clips.first(where: { $0.id == clipID })?.colorGrade ?? .identity
        }
    }
}

/// 合成時刻から色調補正を解決する**唯一の実装**。
///
/// **プレビューと書き出しの両方がここを通ること。** 書き出し側
/// （`VideoMosaicExporter`）は `TimelineState` を保持せず `TimelineMapping` と
/// `[clipID: ColorGrade]` だけを持つため `TimelineState.colorGrade(atComposition:)` を
/// そのままは呼べない。だからといって**同じ手順を書き写してはいけない。**
/// この案件は「同じ式を 2 か所に置いて片方だけ変わる」事故を繰り返している
/// （音程アルゴリズムがプレビューと書き出しで食い違い得た件／逆写像が向きを戻し
/// 忘れた件）。クリップの**引き方だけ**をクロージャで外から渡す形にして、
/// 手順は 1 本に保つ。
public enum ColorGradeResolver {
    /// - Parameter grade: `clipID` → そのクリップの色調補正（無ければ `.identity`）。
    ///   保持形（`TimelineState.clips` か `[UUID: ColorGrade]` か）の違いをここで吸収する。
    ///
    /// **`progress` を自前で計算しないこと。** 顔座標の写像が使うのと同じ値を使うことで、
    /// 色と顔位置が同じ進行度で動く。
    public static func resolve(mapping: TimelineMapping,
                               at compositionTime: Double,
                               grade: (UUID) -> ColorGrade) -> ColorGrade {
        let locations = mapping.sourceLocations(at: compositionTime)
        guard let first = locations.first else { return .identity }
        guard locations.count >= 2, let last = locations.last, let progress = last.progress else {
            return grade(first.location.clipID)
        }
        return ColorGrade.blend(grade(first.location.clipID),
                                grade(last.location.clipID),
                                t: progress)
    }
}
