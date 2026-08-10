import Foundation

/// 動画の途中から現れた人物を「顔一覧へ自動で足してよいか」を判定する純ロジック。
///
/// MediaPipe / UIKit に一切依存しない値型。時刻は必ず引数（`sourceTime`）で受け取り、
/// `Date()` は使わない（決定的にテストできるようにするため）。
///
/// **設計の要点**:
/// - 署名（`FaceSignature`）が無い観測は一切数えない。位置だけで人を増やす退路は無い。
/// - 既知人物（`knownPersons`）に一致・判断保留の顔は候補にもしない
///   （二重登録・誤登録を避ける）。
/// - 未知の顔は sourceID ごとの候補台帳で複数回の目撃を積み上げ、
///   「別バケットで 3 回、かつ 1 秒以上の幅」を満たしたときだけ確定（admit）する。
///   1 フレームのバーストや、たまたま近い署名の別人が誤って確定しないための閾値。
/// - 候補は `FaceIdentityThreshold`（既存の同定閾値）で既知照合・候補内照合の両方に使う。
///   新しい閾値は発明しない。
public struct EmergingPersonArbiter {
    /// 挙動を決める上限値。既定は設計どおりだが、テストから差し替え可能。
    public struct Limits: Sendable, Equatable {
        /// 確定に必要な「別バケットでの命中」回数。
        public var requiredHits: Int
        /// 確定に必要な最初の命中から最後の命中までの時間幅（秒）。
        public var requiredSpanSec: Double
        /// 候補を捨てるまでの無音時間（秒）。シークで時刻が飛んだ場合も同じ規則を使う。
        public var candidateTTLSec: Double
        /// sourceID ごとに同時保持できる候補数の上限。超過分は最も古い候補から捨てる。
        public var maxCandidatesPerSource: Int
        /// 1 回の `observe` 呼び出しで確定してよい人数の上限。
        public var maxAdmissionsPerObservation: Int
        /// 確定と確定の間に必要な素材時刻の間隔（秒）。
        public var admissionIntervalSec: Double
        /// セッション（このインスタンスの生存期間）を通じて自動追加してよい人数の上限。
        /// 到達後は一切追加しない。
        public var maxSessionAdmissions: Int

        public init(
            requiredHits: Int = 3,
            requiredSpanSec: Double = 1.0,
            candidateTTLSec: Double = 5.0,
            maxCandidatesPerSource: Int = 16,
            maxAdmissionsPerObservation: Int = 1,
            admissionIntervalSec: Double = 0.5,
            maxSessionAdmissions: Int = 12
        ) {
            self.requiredHits = requiredHits
            self.requiredSpanSec = requiredSpanSec
            self.candidateTTLSec = candidateTTLSec
            self.maxCandidatesPerSource = maxCandidatesPerSource
            self.maxAdmissionsPerObservation = maxAdmissionsPerObservation
            self.admissionIntervalSec = admissionIntervalSec
            self.maxSessionAdmissions = maxSessionAdmissions
        }

        public static let `default` = Limits()
    }

    /// 15fps バケット。ライブ検出のバケットと同じ粒度（`liveBucketFPS` 相当）を
    /// このコアの中だけで完結させるためのローカル定数。
    private static let bucketFPS = 15.0

    private struct Candidate {
        var profile: PersonProfile
        /// 命中した観測が乗った 15fps バケットの集合。**同じバケットは 1 回しか
        /// 数えない**（1 フレームのバーストで確定しないための土台）。
        var hitBuckets: Set<Int>
        /// 実際の命中回数。`hitBuckets` に新しいバケットが増えたときだけ加算する。
        var hitCount: Int
        var firstSeen: Double
        var lastSeen: Double
    }

    private let limits: Limits
    private var candidatesBySource: [UUID: [Candidate]] = [:]
    private var lastAdmissionTime: Double?
    private var totalAdmissions = 0

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    /// このセッションで自動追加した人数。
    public var admittedCount: Int { totalAdmissions }

    private static func bucket(_ time: Double) -> Int {
        Int((time * bucketFPS).rounded())
    }

    /// 1 回分の観測（1 フレームぶんの検出結果）を候補台帳へ反映し、
    /// 確定すべき添字（`signatures` の添字）を返す。
    ///
    /// - Parameters:
    ///   - signatures: この観測で検出された顔の署名。`nil` は「署名が取れなかった顔」で、
    ///     位置がいくつ見えていても候補にはしない。
    ///   - knownPersons: 既に顔一覧に載っている人物（そのセッションで選べる範囲）。
    ///   - sourceID: 観測元の素材 ID。候補台帳は素材ごとに独立して持つ。
    ///   - sourceTime: 素材時刻（合成時刻ではない）。
    /// - Returns: 確定（admit）すべき `signatures` の添字。1 回の呼び出しで
    ///   最大 `limits.maxAdmissionsPerObservation`（既定 1）件。
    public mutating func observe(
        signatures: [FaceSignature?],
        knownPersons: [PersonProfile],
        sourceID: UUID,
        sourceTime: Double
    ) -> [Int] {
        guard totalAdmissions < limits.maxSessionAdmissions else { return [] }

        purgeExpired(sourceID: sourceID, now: sourceTime)
        var candidates = candidatesBySource[sourceID] ?? []
        let bucketID = Self.bucket(sourceTime)
        var admitted: [Int] = []

        for (idx, signatureOpt) in signatures.enumerated() {
            guard let signature = signatureOpt,
                  isUnknown(signature, comparedTo: knownPersons),
                  let matchedIndex = matchOrCreateCandidate(signature: signature, in: &candidates,
                                                             bucketID: bucketID, sourceTime: sourceTime),
                  meetsAdmissionCriteria(candidates[matchedIndex]),
                  admitted.count < limits.maxAdmissionsPerObservation,
                  isPaced(at: sourceTime)
            else { continue }

            admitted.append(idx)
            candidates.remove(at: matchedIndex)
            totalAdmissions += 1
            lastAdmissionTime = sourceTime
            if totalAdmissions >= limits.maxSessionAdmissions { break }
        }

        candidatesBySource[sourceID] = candidates
        return admitted
    }

    /// 既知人物のどれとも「別人と言い切れる」（`distinct` 以下）かどうか。
    /// 一致・判断保留（帯の中）はどちらも false（＝候補にしない）。
    private func isUnknown(_ signature: FaceSignature, comparedTo knownPersons: [PersonProfile]) -> Bool {
        let bestKnown = knownPersons.map { $0.similarity(to: signature) }.max() ?? -1
        return bestKnown <= FaceIdentityThreshold.distinct
    }

    private func meetsAdmissionCriteria(_ candidate: Candidate) -> Bool {
        candidate.hitCount >= limits.requiredHits
            && candidate.lastSeen - candidate.firstSeen >= limits.requiredSpanSec
    }

    private func isPaced(at sourceTime: Double) -> Bool {
        guard let lastAdmissionTime else { return true }
        return sourceTime - lastAdmissionTime >= limits.admissionIntervalSec
    }

    /// 署名を候補台帳と照合する。一致すれば手本を足して命中を記録しその添字を返す。
    /// 判断保留の帯なら何もせず nil。どれとも似ていなければ新しい候補を作り、
    /// できたばかりでまだ確定判定に届かないため nil を返す。
    private func matchOrCreateCandidate(
        signature: FaceSignature,
        in candidates: inout [Candidate],
        bucketID: Int,
        sourceTime: Double
    ) -> Int? {
        var bestIndex: Int?
        var bestSimilarity: Float = -.infinity
        for (index, candidate) in candidates.enumerated() {
            let similarity = candidate.profile.similarity(to: signature)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestIndex = index
            }
        }

        if let index = bestIndex, bestSimilarity >= FaceIdentityThreshold.match {
            candidates[index].profile.add(signature)
            // 同一バケットは命中に数えない（1 フレームのバーストで確定させないため）。
            if !candidates[index].hitBuckets.contains(bucketID) {
                candidates[index].hitBuckets.insert(bucketID)
                candidates[index].hitCount += 1
            }
            candidates[index].lastSeen = sourceTime
            return index
        }
        if bestIndex != nil, bestSimilarity > FaceIdentityThreshold.distinct {
            return nil   // 判断保留の帯。既存候補にも新規候補にもしない。
        }

        let newCandidate = Candidate(profile: PersonProfile(exemplars: [signature]),
                                      hitBuckets: [bucketID], hitCount: 1,
                                      firstSeen: sourceTime, lastSeen: sourceTime)
        candidates.append(newCandidate)
        if candidates.count > limits.maxCandidatesPerSource {
            // 捨てる基準は **`lastSeen`（最後に見えた時刻）が最も古い候補**。
            // `firstSeen` で捨ててはいけない: それは「一番長く粘って確定に近づいている
            // 候補」でもあるので、群衆で新しい顔が次々来ると、あと 1 回で確定するはずの
            // 人が押し出され続けて永遠に一覧へ出ない。
            // `lastSeen` なら「もう見えていない候補」から落ちる＝ `purgeExpired`（TTL）と
            // 同じ基準で、TTL を待たずに枠を空けるだけの意味になる。
            if let stalest = candidates.indices.min(by: { candidates[$0].lastSeen < candidates[$1].lastSeen }) {
                candidates.remove(at: stalest)
            }
        }
        return nil   // できたばかりの候補は3回の命中に届かないため確定判定は不要
    }

    /// TTL 超過の候補を捨てる。シークで時刻が飛んだ（前にも後ろにも）場合も
    /// 同じ規則（`abs` 差分）でリセットされる。
    private mutating func purgeExpired(sourceID: UUID, now: Double) {
        guard var candidates = candidatesBySource[sourceID] else { return }
        candidates.removeAll { abs(now - $0.lastSeen) > limits.candidateTTLSec }
        candidatesBySource[sourceID] = candidates
    }
}
