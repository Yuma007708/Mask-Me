import CoreGraphics
import Foundation

/// リアルタイム撮影用の「モザイクを外す顔」のオプトアウト管理。
///
/// 撮影はモザイク焼き込みのみ（原本なし）で失敗が不可逆のため、既定は
/// 「検出された全ての顔にモザイク ON」。ユーザーがタップで OFF にした顔だけを
/// 重心の時系列マッチングで追跡し、そのフレームのモザイク対象から除外する。
///
/// 安全側の設計:
/// - OFF トラックが `lostFrameTolerance` フレーム連続で検出とマッチしなければ破棄する
///   （フレームアウト→再インした人は自動で ON に戻る。別人が OFF を引き継ぐ事故を防ぐ）。
/// - マッチ距離は `SelectedFaceTracker.matchDistance`(0.5) より狭い 0.2。OFF は
///   露出方向の誤りなので、通行人への誤マッチを距離側でも絞る。
public struct CameraFaceSelection {
    /// OFF トラックと検出顔の重心マッチ距離（正規化座標）。
    public static let matchDistance: CGFloat = 0.2
    /// OFF トラックを破棄するまでの連続未マッチフレーム数。
    /// 検出 10fps 想定でおよそ 1.5 秒（フロー橋渡し中はマッチが続くため実質それ以上）。
    public static let lostFrameTolerance = 15

    private struct Track {
        var centroid: CGPoint
        var missCount: Int
    }

    private var unmasked: [Track] = []

    public init() {}

    /// OFF にしている顔があるか（UI バッジ表示用）。
    public var unmaskedCount: Int { unmasked.count }

    /// 全てのオプトアウトを破棄して「全員モザイク ON」に戻す。
    public mutating func reset() {
        unmasked.removeAll()
    }

    /// タップ位置（正規化座標）の顔の ON/OFF を切り替える。
    /// - Returns: 切替後の状態（`true`=モザイク ON に戻した / `false`=OFF にした）。
    ///   タップ位置に顔が無ければ nil。
    @discardableResult
    public mutating func toggle(at point: CGPoint, in faces: [FaceLandmarkSet]) -> Bool? {
        guard let faceIdx = Self.faceIndex(at: point, in: faces) else { return nil }
        let face = faces[faceIdx]
        // 単純な最近傍だと、OFF 顔のすぐ隣の顔をタップしたときに既存トラックを
        // 誤って解除する。facesToMask と同じ 1:1 割り当てで「このタップ顔に
        // 対応しているトラック」だけを解除対象にする。
        if let trackIdx = assignTracks(to: faces)
            .first(where: { $0.faceIdx == faceIdx })?.trackIdx {
            unmasked.remove(at: trackIdx)
            return true
        }
        unmasked.append(
            Track(centroid: SelectedFaceTracker.centroid(of: face), missCount: 0))
        return false
    }

    /// このフレームでモザイクを掛ける顔を返す（OFF トラックにマッチした顔を除外）。
    /// OFF トラックはマッチした検出位置へ追従し、未マッチが続くと破棄される。
    /// フレームは時刻順に流すこと。
    public mutating func facesToMask(from faces: [FaceLandmarkSet]) -> [FaceLandmarkSet] {
        guard !unmasked.isEmpty else { return faces }

        let assigned = assignTracks(to: faces)
        var matchedTracks = Set<Int>()
        var excludedFaces = Set<Int>()
        for pair in assigned {
            matchedTracks.insert(pair.trackIdx)
            excludedFaces.insert(pair.faceIdx)
            unmasked[pair.trackIdx].centroid =
                SelectedFaceTracker.centroid(of: faces[pair.faceIdx])
            unmasked[pair.trackIdx].missCount = 0
        }

        // 未マッチのトラックはロストを数え、許容超えで破棄（再イン時は安全側で ON）。
        // 検出が全滅したフレーム（faces 空）はロストに数えない: フロー橋渡しの上限切れ
        // などで検出自体が止まっているだけで、人が居なくなった証拠ではないため。
        if !faces.isEmpty {
            for ti in unmasked.indices where !matchedTracks.contains(ti) {
                unmasked[ti].missCount += 1
            }
            unmasked.removeAll { $0.missCount > Self.lostFrameTolerance }
        }

        return faces.enumerated()
            .filter { !excludedFaces.contains($0.offset) }
            .map(\.element)
    }

    /// タップ位置に対応する顔の添字。bbox を少し広げた矩形で判定し、
    /// 複数当たれば重心が近い方。
    public static func faceIndex(at point: CGPoint, in faces: [FaceLandmarkSet]) -> Int? {
        faces.enumerated()
            .filter { $0.element.boundingBox.insetBy(dx: -0.03, dy: -0.03).contains(point) }
            .min { lhs, rhs in
                let lc = SelectedFaceTracker.centroid(of: lhs.element)
                let rc = SelectedFaceTracker.centroid(of: rhs.element)
                return hypot(lc.x - point.x, lc.y - point.y) < hypot(rc.x - point.x, rc.y - point.y)
            }?
            .offset
    }

    /// OFF トラック → 検出顔の 1:1 割り当て（距離昇順の貪欲法、matchDistance 内のみ）。
    private struct Candidate {
        let trackIdx: Int
        let faceIdx: Int
        let dist: CGFloat
    }

    private func assignTracks(to faces: [FaceLandmarkSet])
        -> [(trackIdx: Int, faceIdx: Int)] {
        var candidates: [Candidate] = []
        for (ti, track) in unmasked.enumerated() {
            for (fi, face) in faces.enumerated() {
                let c = SelectedFaceTracker.centroid(of: face)
                let d = hypot(c.x - track.centroid.x, c.y - track.centroid.y)
                if d < Self.matchDistance {
                    candidates.append(Candidate(trackIdx: ti, faceIdx: fi, dist: d))
                }
            }
        }
        candidates.sort { $0.dist < $1.dist }
        var usedTracks = Set<Int>()
        var usedFaces = Set<Int>()
        var result: [(trackIdx: Int, faceIdx: Int)] = []
        for cand in candidates
        where !usedTracks.contains(cand.trackIdx) && !usedFaces.contains(cand.faceIdx) {
            usedTracks.insert(cand.trackIdx)
            usedFaces.insert(cand.faceIdx)
            result.append((cand.trackIdx, cand.faceIdx))
        }
        return result
    }
}
