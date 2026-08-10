import Foundation

/// `clipDuckRanges` の追従呼び出しをまとめた薄いラッパ（`ClipDuckGate` への委譲）。
///
/// `TimelineState.swift` 本体が file_length の閾値に張り付いているため分冊した
/// （`TimelineStateValidation.swift` / `TimelineStateAudioMuteEditing.swift` と同じ理由）。
/// `splittingEdit(at:)` / `removing(clipID:)` / `trimming(clipID:...)` の 3 箇所が、
/// `clipAudioMuteRanges` を付け替えているのと同じ呼び出し形でここを経由する。
extension TimelineState {
    /// 分割境界 `back.sourceStart` で声区間を前後へ振り分ける。
    func duckRanges(splittingFront front: TimelineClip, into back: TimelineClip, isPhoto: Bool) -> [ClipDuckRange] {
        ClipDuckGate.ranges(splittingClip: front, into: back, atSourceTime: back.sourceStart,
                            isPhoto: isPhoto, existing: clipDuckRanges)
    }

    /// クリップ削除に追従して、そのクリップの声区間を消す。
    func duckRanges(removingClipID clipID: UUID) -> [ClipDuckRange] {
        ClipDuckGate.ranges(removingClipID: clipID, from: clipDuckRanges)
    }

    /// 写真クリップのトリムに追従して `sourceEnd` を引き直す。
    func duckRanges(trimmingPhotoClip clip: TimelineClip) -> [ClipDuckRange] {
        ClipDuckGate.ranges(trimmingPhotoClip: clip, existing: clipDuckRanges)
    }
}
