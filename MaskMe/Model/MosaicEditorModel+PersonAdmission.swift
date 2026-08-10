import Foundation
import MosaicCore
import UIKit

#if canImport(Metal)

/// 動画の途中から現れた人物を、顔一覧（`detectedFaces`）へ自動で足す配線。
///
/// 判定そのもの（何回・何秒見えたら確定するか）は `MosaicCore.EmergingPersonArbiter`
/// （純ロジック）が持つ。ここは「確定した署名を、実際に `detectedFaces` へどう
/// 反映するか」というアプリ層の配線だけを担う。
extension MosaicEditorModel {
    /// `storeLiveSignatures` の末尾（署名を置き場へ書いた直後）から呼ぶ。
    ///
    /// - 追加する `FaceTarget` は常に `isSelected: true`。`selectedLandmarks` /
    ///   `targetsForExport` の「選択数 == 検出数なら絞り込みを丸ごとバイパスする」
    ///   近道が壊れないようにするため（未選択で足すと、それまで隠れていた顔が
    ///   絞り込みに掛かって素通しになる）。
    /// - この経路は `cacheStore` にも `liveFlowCache` にも一切書かない
    ///   （顔と空エントリの書き込みは `storeLiveDetection` が済ませている）。
    ///
    /// - Parameter faces: **素材フレーム基準**の顔（`detectedFaces[].landmarks` はこの座標系）。
    /// - Parameter frameFaces: `frame`（合成フレーム）と同じ座標系の顔。サムネイルの
    ///   切り出しにだけ使う。nil なら `faces` を使う（恒等レイアウトのテスト注入用）。
    ///   `faces` と同じ順・同じ件数であること。
    @MainActor
    func admitEmergingPersons(faces: [FaceLandmarkSet], frameFaces: [FaceLandmarkSet]? = nil,
                              signatures: [FaceSignature?],
                              sourceID: UUID, sourceTime: Double, frame: UIImage) {
        let knownPersons = selectedPersonProfiles(of: detectedFaces)
        let admittedIndices = emergingPersonArbiter.observe(
            signatures: signatures, knownPersons: knownPersons,
            sourceID: sourceID, sourceTime: sourceTime)
        guard !admittedIndices.isEmpty else { return }

        let thumbnailFaces = (frameFaces?.count == faces.count ? frameFaces : nil) ?? faces
        for index in admittedIndices {
            guard faces.indices.contains(index), signatures.indices.contains(index),
                  let signature = signatures[index]
            else { continue }
            // サムネイルは `frame`（合成フレーム）から切り出すので、その座標系の顔を使う。
            let thumbnailLandmarks = thumbnailFaces.indices.contains(index)
                ? thumbnailFaces[index] : faces[index]
            admitPerson(signature: signature, landmarks: faces[index],
                        thumbnailLandmarks: thumbnailLandmarks,
                        sourceID: sourceID, frame: frame)
        }
    }

    /// 1 人ぶんの確定を `detectedFaces` へ反映する。
    ///
    /// - Parameter landmarks: **素材フレーム基準**（`detectedFaces` へ載せる値）。
    /// - Parameter thumbnailLandmarks: `frame` と同じ座標系（サムネイルの切り出し専用）。
    @MainActor
    private func admitPerson(signature: FaceSignature, landmarks: FaceLandmarkSet,
                             thumbnailLandmarks: FaceLandmarkSet,
                             sourceID: UUID, frame: UIImage) {
        // 台帳へ登録する。nil（判断保留の帯）や、たまたま既存人物と一致した場合は
        // 追加を取りやめる——台帳と一覧の食い違い（同じ人物IDが2チップに割れる）を
        // 作らないため。
        guard let personID = personRegistry.register(signature),
              !detectedFaces.contains(where: { $0.personID == personID })
        else { return }

        // 新入りの初期検出率は「登場直後から満点」に見せる（0%だと「追えていない」
        // という誤ったサインになる）。`liveMatchCounts` 側の初期値と揃える。
        let initialRate: Double? = liveSampleCount > 0 ? 100 : nil
        let newTarget = FaceTarget(id: UUID(), landmarks: landmarks,
                                   thumbnail: generateThumbnail(for: thumbnailLandmarks, from: frame),
                                   isSelected: true, detectionRate: initialRate,
                                   sourceID: sourceID, personID: personID)

        detectedFaces.append(newTarget)
        // `liveMatchCounts` は `detectedFaces` と添字で対応する並行配列。**末尾 append
        // のみ**で伸ばす（`insert(at: 0)` 等は既存顔の添字をずらし、検出率の取り違えを
        // 起こす）。初期値は `liveSampleCount`（＝これまでの全サンプルで見つかっていた
        // 体で始める。0 だと登場直後に検出率バッジが 0% と出てしまう）。
        while liveMatchCounts.count < detectedFaces.count {
            liveMatchCounts.append(liveSampleCount)
        }

        // undo/redo スタックと履歴基準は「新 ID を知らない」ままなので、`apply(_:)` が
        // `snap.selectedFaceIDs.contains(id)` で選択を作り直す際に新入りの選択が外れる
        // （＝顔が露出する）。全スナップショットへ新 IDを注入して塞ぐ。
        lastCommitted?.selectedFaceIDs.insert(newTarget.id)
        for i in undoStack.indices { undoStack[i].selectedFaceIDs.insert(newTarget.id) }
        for i in redoStack.indices { redoStack[i].selectedFaceIDs.insert(newTarget.id) }

        // `detectedFaces` の didSet（`applyPendingFaceSelectionAnchorsIfNeeded`）が
        // 保留中の下書き目印を適用し、新入りを「目印に無い顔＝非選択」として落とす
        // 経路があるため、選択を後段で再表明する（冪等）。
        if let idx = detectedFaces.firstIndex(where: { $0.id == newTarget.id }) {
            detectedFaces[idx].isSelected = true
        }

        previewController?.invalidate()
    }
}

#endif
