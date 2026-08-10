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
///
/// **署名（人物同定）の役割は「拒否」だけ**（S4）。
///
/// 重心の近さだけで OFF を引き継ぐと、OFF にした人の前を別人が横切った瞬間に
/// トラックが乗り移り、**その別人が素で映る**。撮影は焼き込み保存で取り返しがつかない。
/// そこで署名が使えるときは、
///
/// | 署名の言うこと | 扱い |
/// |---|---|
/// | 別人だと言い切れる（`distinct` 以下） | その顔への引き継ぎを**拒否**し、トラックを**停止**する |
/// | 同一人物だと言える（`match` 以上） | 位置の判定どおり。手本として取り込む |
/// | 判断保留・署名なし | 位置の判定どおり（従来の挙動） |
///
/// **停止は 1 フレームで解けない。** 署名は数フレームに 1 回しか測れないので、
/// 拒否したフレームだけモザイクを掛け直しても、次の署名なしフレームで同じ別人に
/// また位置でマッチする。停止したトラックは `match` の署名で名乗り直すまで
/// （あるいはロストして消えるまで）誰の OFF にも使わない。
///
/// **署名でマッチ距離を広げることはしない。** 広げる側の誤りは露出に直結する一方、
/// 狭いままの誤りは「OFF にしたのに掛かってしまう」＝もう一度タップすれば済む。
///
/// トラックの手本は、**タップ時ではなく最初に署名つきでマッチしたときに**入る
/// （タップの瞬間に署名があるとは限らないため）。それまでは従来どおり位置だけで動く。
public struct CameraFaceSelection {
    /// OFF トラックと検出顔の重心マッチ距離（正規化座標）。
    public static let matchDistance: CGFloat = 0.2
    /// OFF トラックを破棄するまでの連続未マッチフレーム数。
    /// 検出 10fps 想定でおよそ 1.5 秒（フロー橋渡し中はマッチが続くため実質それ以上）。
    public static let lostFrameTolerance = 15

    private struct Track {
        var centroid: CGPoint
        var missCount: Int
        /// この OFF トラックが誰なのか。署名つきで初めてマッチしたときに入る。
        var profile: PersonProfile?
        /// 「別人だ」と言われて停止中か。停止中は位置が近くても誰の OFF にも使わず、
        /// `match` の署名で名乗り直すまで解けない（署名は間引いて測るため、
        /// 拒否したフレームだけ掛け直しても次のフレームでまた乗り移られる）。
        var isSuspended = false
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
    public mutating func toggle(at point: CGPoint, in faces: [FaceLandmarkSet],
                                signatures: [FaceSignature?] = []) -> Bool? {
        guard let faceIdx = Self.faceIndex(at: point, in: faces) else { return nil }
        let face = faces[faceIdx]
        let signatures = Self.aligned(signatures, to: faces)
        // 単純な最近傍だと、OFF 顔のすぐ隣の顔をタップしたときに既存トラックを
        // 誤って解除する。facesToMask と同じ 1:1 割り当てで「このタップ顔に
        // 対応しているトラック」だけを解除対象にする。
        if let trackIdx = assignTracks(to: faces, signatures: signatures)
            .first(where: { $0.faceIdx == faceIdx })?.trackIdx {
            unmasked.remove(at: trackIdx)
            return true
        }
        unmasked.append(
            Track(centroid: SelectedFaceTracker.centroid(of: face), missCount: 0,
                  profile: signatures[faceIdx].map { PersonProfile(exemplars: [$0]) }))
        return false
    }

    /// このフレームでモザイクを掛ける顔を返す（OFF トラックにマッチした顔を除外）。
    /// OFF トラックはマッチした検出位置へ追従し、未マッチが続くと破棄される。
    /// フレームは時刻順に流すこと。
    public mutating func facesToMask(from faces: [FaceLandmarkSet],
                                     signatures: [FaceSignature?] = []) -> [FaceLandmarkSet] {
        let masked = maskedIndices(from: faces, signatures: signatures)
        return masked.map { faces[$0] }
    }

    /// `facesToMask` の添字版。フロー前進層（`LiveFacePropagator`）が「検出間で
    /// 前進させた顔のうちどれを描くか」を添字で参照するために使う。
    /// トラックの追従・ロスト算入という状態更新は `facesToMask` と同一。
    ///
    /// - Parameter signatures: `faces` と**同じ順・同じ件数**。作れなかった顔は nil。
    ///   件数が違えば全て署名なしとして扱う（取り違えた署名で判断するより、
    ///   位置だけの従来挙動へ落ちる方が安全）。
    public mutating func maskedIndices(from faces: [FaceLandmarkSet],
                                       signatures: [FaceSignature?] = []) -> [Int] {
        guard !unmasked.isEmpty else { return Array(faces.indices) }
        let signatures = Self.aligned(signatures, to: faces)

        // 拒否は「そのフレームだけ」では効かない。署名は間引いて測るので、
        // 署名の無い次のフレームでは同じ別人にまた位置でマッチしてしまう。
        // 一度でも別人だと言われたトラックは**停止**させ、`match` の署名で
        // 名乗り直すまで（あるいはロストして消えるまで）誰の OFF にも使わない。
        for trackIdx in vetoedTracks(faces: faces, signatures: signatures) {
            unmasked[trackIdx].isSuspended = true
        }

        let assigned = assignTracks(to: faces, signatures: signatures)
        var matchedTracks = Set<Int>()
        var excludedFaces = Set<Int>()
        for pair in assigned {
            matchedTracks.insert(pair.trackIdx)
            excludedFaces.insert(pair.faceIdx)
            unmasked[pair.trackIdx].centroid =
                SelectedFaceTracker.centroid(of: faces[pair.faceIdx])
            unmasked[pair.trackIdx].missCount = 0
            unmasked[pair.trackIdx].isSuspended = false
            if let signature = signatures[pair.faceIdx] {
                learn(signature, forTrackAt: pair.trackIdx)
            }
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

        return faces.indices.filter { !excludedFaces.contains($0) }
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

    /// マッチした顔の署名をトラックへ取り込む。
    ///
    /// 手本がまだ無ければそれを最初の手本にする（タップ時点では署名が無いのが普通）。
    /// 既に手本があるときは **`match` 以上のときだけ**足す。位置の追従が隣の人へ
    /// ずれていた場合に別人の顔を手本にすると、以後その別人まで OFF 扱いになる。
    private mutating func learn(_ signature: FaceSignature, forTrackAt index: Int) {
        guard var profile = unmasked[index].profile else {
            unmasked[index].profile = PersonProfile(exemplars: [signature])
            return
        }
        guard profile.similarity(to: signature) >= FaceIdentityThreshold.match else { return }
        profile.add(signature)
        unmasked[index].profile = profile
    }

    /// 署名の配列を顔の件数に揃える（合わなければ全て署名なし）。
    private static func aligned(_ signatures: [FaceSignature?],
                                to faces: [FaceLandmarkSet]) -> [FaceSignature?] {
        signatures.count == faces.count
            ? signatures
            : [FaceSignature?](repeating: nil, count: faces.count)
    }

    /// OFF トラック → 検出顔の 1:1 割り当て（距離昇順の貪欲法、matchDistance 内のみ）。
    private struct Candidate {
        let trackIdx: Int
        let faceIdx: Int
        let dist: CGFloat
    }

    /// 停止中のトラックが、この顔を引き継いでよいか。
    /// 停止は「別人だと言われた」状態なので、解けるのは `match` の署名だけ。
    private static func resumes(_ track: Track, signature: FaceSignature?) -> Bool {
        guard track.isSuspended else { return true }
        guard let profile = track.profile, let signature else { return false }
        return profile.similarity(to: signature) >= FaceIdentityThreshold.match
    }

    /// このフレームで「別人だ」と言われたトラックの添字。
    /// 距離が届いていない組み合わせは無関係なので数えない。
    private func vetoedTracks(faces: [FaceLandmarkSet],
                              signatures: [FaceSignature?]) -> [Int] {
        unmasked.indices.filter { ti in
            guard let profile = unmasked[ti].profile else { return false }
            return faces.indices.contains { fi in
                guard let signature = signatures[fi],
                      profile.similarity(to: signature) <= FaceIdentityThreshold.distinct
                else { return false }
                let c = SelectedFaceTracker.centroid(of: faces[fi])
                return hypot(c.x - unmasked[ti].centroid.x,
                             c.y - unmasked[ti].centroid.y) < Self.matchDistance
            }
        }
    }

    private func assignTracks(to faces: [FaceLandmarkSet],
                              signatures: [FaceSignature?])
        -> [(trackIdx: Int, faceIdx: Int)] {
        var candidates: [Candidate] = []
        for (ti, track) in unmasked.enumerated() {
            for (fi, face) in faces.enumerated() {
                // 「別人だ」と言われて停止したトラックは、本人の署名で名乗り直すまで
                // 誰の OFF にも使わない（乗り移り＝その別人が素で映る事故を塞ぐ）。
                guard Self.resumes(track, signature: signatures[fi]) else { continue }
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
