import CoreGraphics
import Foundation

/// 下書きに保存した「どの顔を隠すか」の目印を、再開時に検出されている顔へ結び直す判定。
///
/// **なぜ位置だけでは足りないか**: 目印は保存した瞬間の重心（＝そのときの再生位置での
/// 顔の場所）で、再開時の顔は初期スキャンが見つけた別の時刻・別の場所にいる。位置照合は
/// そこで外れ、外れると安全側（その素材の顔を全選択＝全員隠す）へ倒れるため、
/// **「この人だけ隠す」というユーザーの選択が再開のたびに失われる**。
///
/// そこで人物の見た目（署名から引いた人物 ID）で先に照合し、決まらないものだけ従来の
/// 位置照合へ落とす。人物が一致したときは**位置を問わない**（顔が動いていても、
/// 別の時刻のフレームでも同じ人は同じ人）。
///
/// **説明できない目印が 1 つでも残れば全選択**という安全側の規則は変えていない。
/// 保存時に隠していた顔の行方が説明できない状態＝その顔が素で映りうる状態であり、
/// このアプリでは掛けすぎ（もう一度タップで外せる）より露出の方が重い。
public enum DraftSelectionResolver {
    /// 下書きに保存されていた「隠していた顔」1 件の目印。
    public struct Anchor: Sendable, Equatable {
        /// 保存時に同定できていた人物 ID。署名が取れていなかった顔・
        /// 人物 ID を保存する前の下書きでは nil で、位置照合だけになる。
        public let personID: UUID?
        /// 保存時の正規化重心（素材フレーム基準）。
        public let centroid: CGPoint

        public init(personID: UUID?, centroid: CGPoint) {
            self.personID = personID
            self.centroid = centroid
        }
    }

    /// 再開時に検出されている顔 1 件。
    public struct Face: Sendable, Equatable {
        /// 復元した人物台帳と照合して付いた人物 ID。付かなければ nil。
        public let personID: UUID?
        public let centroid: CGPoint

        public init(personID: UUID?, centroid: CGPoint) {
            self.personID = personID
            self.centroid = centroid
        }
    }

    public struct Resolution: Sendable, Equatable {
        /// 選択（＝モザイクを掛ける）すべき顔の添字。
        public let selected: Set<Int>
        /// 目印が全部いずれかの顔で説明できたか。
        /// false のとき `selected` は全顔（安全側へ倒した結果）。
        public let isFullyExplained: Bool
    }

    /// - Parameters:
    ///   - anchors: この素材へ向けられた目印。
    ///   - faces: この素材で検出されている顔。
    ///   - centroidThreshold: 位置照合の許容距離（正規化座標）。
    public static func resolve(anchors: [Anchor], faces: [Face],
                               centroidThreshold: CGFloat) -> Resolution {
        guard !faces.isEmpty else {
            // 結び直す先が無い。目印が残っていれば「説明できていない」が、
            // 選択すべき顔も無いので selected は空のまま。
            return Resolution(selected: [], isFullyExplained: anchors.isEmpty)
        }
        var selected = Set<Int>()
        var explained = 0
        for anchor in anchors {
            var hits = Set<Int>()
            // 1. 人物で照合する。**位置は問わない。**
            if let personID = anchor.personID {
                hits = Set(faces.indices.filter { faces[$0].personID == personID })
            }
            // 2. 人物で決まらなければ位置へ落とす（従来の作法）。
            if hits.isEmpty {
                hits = Set(faces.indices.filter {
                    hypot(faces[$0].centroid.x - anchor.centroid.x,
                          faces[$0].centroid.y - anchor.centroid.y) < centroidThreshold
                })
            }
            guard !hits.isEmpty else { continue }
            explained += 1
            selected.formUnion(hits)
        }
        let isFullyExplained = explained == anchors.count
        return Resolution(selected: isFullyExplained ? selected : Set(faces.indices),
                          isFullyExplained: isFullyExplained)
    }
}
