import Foundation

/// 選択中のレイヤーアイテム（種 + id）。
///
/// **タプル `(TimelineLayerKind, UUID)` を直接プロパティに格納しない。** Swift の
/// タプルは要素が `Equatable` でもタプル自体は `Equatable` に準拠できないため、
/// `TimelineSelection` の自動合成 `Equatable` が壊れる。この struct を挟むことで
/// 素直に自動合成できる。
public struct TimelineLayerSelection: Equatable, Sendable {
    public let kind: TimelineLayerKind
    public let id: UUID

    public init(kind: TimelineLayerKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

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
    /// 選択中のレイヤーアイテム（種 + id）。E2/E3 で音声・テキストのアイテムが乗る。
    public private(set) var layer: TimelineLayerSelection?

    public init() {}

    /// 何も選んでいないか。
    public var isEmpty: Bool { clipID == nil && layer == nil }

    /// 指定した種のレイヤーを選んでいるならその id。違う種を選んでいるなら nil。
    ///
    /// **種を落とす形（`rangeID` のような「種を問わず id だけ返す」入口）は置かない。**
    /// かつて `rangeID` / `selectRange` という shim があり、常に `.mosaic` として
    /// 書き込んでいた。BGM の段が同じ Binding を使っていたため、**BGM の帯をタップして
    /// 選ぶと内部では `.mosaic` になり、削除も音量調整も効かなくなっていた**
    /// （E2-3b で作り込んだ欠陥。E3-3a のレビューで発見）。
    /// 種を必ず伴う形にして、同じ取り違えを型で防ぐ。
    public func layerID(of kind: TimelineLayerKind) -> UUID? {
        guard let layer, layer.kind == kind else { return nil }
        return layer.id
    }

    /// クリップを選ぶ。`nil` は選択解除。**レイヤーの選択は必ず外れる。**
    public mutating func selectClip(_ id: UUID?) {
        clipID = id
        if id != nil { layer = nil }
    }

    /// レイヤーアイテムを選ぶ。`nil` は選択解除。**クリップの選択は必ず外れる。**
    public mutating func selectLayer(_ selection: TimelineLayerSelection?) {
        layer = selection
        if selection != nil { clipID = nil }
    }

    /// すべての選択を外す。
    public mutating func clear() {
        clipID = nil
        layer = nil
    }

    /// 消えたものを指したままにしない。
    ///
    /// 分割・削除・undo でクリップやレイヤーは入れ替わる。指したままにすると、
    /// ツールバーが「選択中」の見た目のまま存在しない対象へ操作を投げる。
    /// タイムラインが変わるたびに通す。
    ///
    /// **種ごとの `switch` で全 case を網羅し、`default` は書かない。** E2/E3 で
    /// `TimelineLayerKind` に case が増えたとき、ここが対応漏れのままだと
    /// コンパイルが通ってしまう（＝消えたアイテムを刈らない無言の欠陥）。
    /// `default` を書くとその安全策が失われる。
    public mutating func prune(against state: TimelineState) {
        if let clipID, !state.clips.contains(where: { $0.id == clipID }) {
            self.clipID = nil
        }
        if let layer {
            let stillExists: Bool
            switch layer.kind {
            case .mosaic:
                stillExists = state.applyRanges.contains { $0.id == layer.id }
            case .audio:
                stillExists = state.audioItems.contains { $0.id == layer.id }
            case .text:
                stillExists = state.textItems.contains { $0.id == layer.id }
            }
            if !stillExists { self.layer = nil }
        }
    }
}
