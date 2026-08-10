import Foundation

/// クリップ編集で**新しいクリップが生まれた理由**（血統）。
///
/// ## なぜ必要か（差分から推測してはいけない）
///
/// `ObjectMask` は `TimelineState` に同居しない（アプリ層が持つ）ので、クリップ編集の
/// あとで誰かが明示的に付け替える必要がある。その付け替えは長らく**クリップ列の差分から
/// 編集の種類を推測**していた——「直前のクリップと同じ `sourceID` を持つ新規クリップが
/// 現れたら、それは分割の後半である」。
///
/// この推測は**複製で必ず外れる**。複製先は元クリップの直後・同じ `sourceID`・元は
/// 編集前から存在するという条件を完全に満たすため、複製が分割として処理され、
/// 元クリップのマスクがキーフレーム 1 個へ潰れていた（複製では
/// `back.sourceStart == front.sourceStart` なので分割点がクリップ先頭になり、
/// 「分割点未満のキーフレーム」が 0 個になる）。動く人物を追っていた矩形が先頭位置で
/// 止まり、**顔が矩形からはみ出して露出する**。
///
/// 「`sourceStart` が一致したら複製」のような別の推測を足しても、分割点がちょうど
/// クリップ先頭になる縮退ケースと区別できず同じ種類のバグを再生産する。**見た目の差分から
/// 推測するのをやめ、編集操作の側から種類を伝える**のがこの型の役目である。
public enum ClipLineage: Equatable, Sendable {
    /// 分割。`front` は元クリップの id を継承した前半、`back` は新規発番の後半。
    /// 分割点の素材時刻は `back.sourceStart`（`TimelineEditOperations.split` の定義そのもの）。
    case split(front: UUID, back: UUID)
    /// 複製。`original` は**一切変更されない**元クリップ、`copy` は新規発番の複製先。
    case duplicate(original: UUID, copy: UUID)

    /// この編集で**新しく生まれた**クリップの id。
    public var createdClipID: UUID {
        switch self {
        case let .split(_, back): return back
        case let .duplicate(_, copy): return copy
        }
    }
}

/// 編集操作の結果（新しい状態 + その編集で生まれたクリップの血統）。
///
/// 血統を返す必要があるのはクリップを**生む**操作（分割・複製）だけで、それ以外は
/// `TimelineEdit(state)` で足りる（`lineage` は空）。
public struct TimelineEdit: Equatable, Sendable {
    public let state: TimelineState
    public let lineage: [ClipLineage]

    public init(_ state: TimelineState, lineage: [ClipLineage] = []) {
        self.state = state
        self.lineage = lineage
    }
}
