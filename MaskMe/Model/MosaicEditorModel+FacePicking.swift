import CoreGraphics
import Foundation
import MosaicCore

// プレビュー上で顔を直接タップして選ぶための、表示用の顔一覧。
//
// **既存の検出パイプラインには手を入れない。** `displayFaces(at:matching:)` は
// モザイク適用区間のゲートと重なり区間の合成を通る描画専用の経路で、座標系と
// 照合順序に強い制約がある（あちらの doc 参照）。選択のための表示は要件が違う——
// モザイクが OFF でも枠は出す、区間外でも顔は選べる——ので、
// 同じ関数に分岐を足すのではなく、この入口を別に持つ。

extension MosaicEditorModel {
    /// プレビュー上でタップして選べる顔 1 件。
    struct PickableFace: Identifiable {
        /// 代表 `FaceTarget` の ID（＝`PersonGroup.id`）。
        let id: UUID
        /// この人物に属する全ターゲット。`togglePerson` にそのまま渡す。
        let memberIDs: [UUID]
        /// **合成フレーム基準**の正規化矩形（プレビュー画像と同じ座標系）。
        let bounds: CGRect
        let isSelected: Bool
    }

    /// いまプレビューに映っている顔のうち、**人物として選べるもの**。
    ///
    /// - モザイクの ON/OFF と適用区間のゲートは通さない。枠は「これから選ぶ」ための
    ///   表示であり、モザイクが乗っているかとは別。区間外の顔も選べる。
    /// - `detectedFaces` のどれにも対応しない顔は返さない。タップしても切り替える
    ///   相手が居ないので、**押せない枠**を見せることになる。
    /// - **トランジションの重なり中は空を返す。** 合成時刻 1 つに素材位置が 2 つある
    ///   区間で、片側の座標系だけで枠を描くと、もう一方の顔の上にずれた枠が乗る。
    ///   出さなければ「まだ選べない」と読めるが、ずれた枠は誤操作になる。
    ///   重なりは継ぎ目の一瞬なので、そこで選ばせる価値より取り違えの害が大きい。
    func pickableFaces(at time: Double) -> [PickableFace] {
        guard mapping.sourceLocations(at: time).count < 2 else { return [] }
        let resolved = resolveSourceLocation(atComposition: time)
        let faces = lookupFaces(sourceID: resolved.sourceID, sourceTime: resolved.time)
        guard !faces.isEmpty else { return [] }

        let groups = personGroups
        // **照合は素材座標のまま行う**（写した後の座標で比べない。理由は
        // `displayFaces(at:matching:)` の doc）。候補は人物ではなくターゲット単位で
        // 並べる: 同じ人がフレームアウト→再入して増えたターゲットは位置が別なので、
        // 代表 1 点だけにすると再入後の顔を掴めない。
        var centroids: [CGPoint] = []
        var groupIndexOfCentroid: [Int] = []
        for (groupIndex, group) in groups.enumerated() {
            for member in group.members where isInScope(member, sourceID: resolved.sourceID) {
                centroids.append(normalizedCentroid(of: member.landmarks))
                groupIndexOfCentroid.append(groupIndex)
            }
        }
        guard !centroids.isEmpty else { return [] }

        // 同じ人物に 2 つ以上の顔が当たったら、**先に当たった方だけ**を残す。
        // 枠を 2 つ出すと、同じ人物に対して同じ操作をする的が 2 箇所できる。
        var seenGroups = Set<Int>()
        var result: [PickableFace] = []
        for face in faces {
            // **`?? 0` で埋めないこと。** 誰とも対応しない顔が先頭の人物に結び付き、
            // その人の枠が別人の顔の上に乗る（隠す相手を取り違える操作になる）。
            guard let match = FaceCentroidMatching.nearestIndex(for: face, in: centroids) else {
                continue
            }
            let groupIndex = groupIndexOfCentroid[match]
            guard seenGroups.insert(groupIndex).inserted else { continue }
            let group = groups[groupIndex]
            let placed = renderLayout.remap([face], clipID: resolved.clipID).first ?? face
            result.append(PickableFace(id: group.id, memberIDs: group.memberIDs,
                                       bounds: placed.boundingBox,
                                       isSelected: group.isSelected))
        }
        return result
    }

    /// 別素材の顔と照合しない（`selecting` と同じスコープ規則）。
    /// `sourceID` を持たない顔（写真モード・テスト直注入）は素材不問。
    private func isInScope(_ target: FaceTarget, sourceID: UUID?) -> Bool {
        guard let targetSource = target.sourceID, let sourceID else { return true }
        return targetSource == sourceID
    }
}
