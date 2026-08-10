import Foundation

/// タイムラインで**いま何を選んでいるか**。
///
/// クリップと加工レイヤーは**同時に選べない**。ツールバーは選択対象ごとに
/// 中身が変わるので、両方が選ばれている状態を作ると「どちらに対する道具か」が
/// 決まらないまま押せてしまう。相互排他をこの型に閉じ込め、呼び出し側が
/// 片方を消し忘れる経路そのものを無くす。
///
/// **View の `@State` ではなくモデルが持つ。** ツールバーはタイムラインとは
/// 別の段（画面最下部）に置くため、両者が同じ選択を読める場所が要る。
public struct TimelineSelection: Equatable, Sendable {
    /// 選択中のクリップ。
    public private(set) var clipID: UUID?
    /// 選択中の加工レイヤー（モザイクの適用区間）。
    public private(set) var rangeID: UUID?

    public init() {}

    /// 何も選んでいないか。
    public var isEmpty: Bool { clipID == nil && rangeID == nil }

    /// クリップを選ぶ。`nil` は選択解除。**レイヤーの選択は必ず外れる。**
    public mutating func selectClip(_ id: UUID?) {
        clipID = id
        if id != nil { rangeID = nil }
    }

    /// 加工レイヤーを選ぶ。`nil` は選択解除。**クリップの選択は必ず外れる。**
    public mutating func selectRange(_ id: UUID?) {
        rangeID = id
        if id != nil { clipID = nil }
    }

    /// すべての選択を外す。
    public mutating func clear() {
        clipID = nil
        rangeID = nil
    }

    /// 消えたものを指したままにしない。
    ///
    /// 分割・削除・undo でクリップやレイヤーは入れ替わる。指したままにすると、
    /// ツールバーが「選択中」の見た目のまま存在しない対象へ操作を投げる。
    /// タイムラインが変わるたびに通す。
    public mutating func prune(against state: TimelineState) {
        if let clipID, !state.clips.contains(where: { $0.id == clipID }) {
            self.clipID = nil
        }
        if let rangeID, !state.applyRanges.contains(where: { $0.id == rangeID }) {
            self.rangeID = nil
        }
    }
}
