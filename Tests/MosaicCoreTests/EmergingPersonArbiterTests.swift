import XCTest
@testable import MosaicCore

/// 動画の途中から現れた人物を自動追加してよいかの純ロジック。
/// **確定間違いは即・プライバシー事故**（未選択の別人を勝手に選択顔として扱う、
/// または同じ人を2人として登録する）につながるため、境界条件を厳しく固定する。
final class EmergingPersonArbiterTests: XCTestCase {

    /// 128次元のうち2軸だけを使って角度で類似度を作る署名。
    /// 同じ軸対では `similarity(v(a), v(b)) == cos(a - b)` になるため、
    /// 閾値ちょうどの署名を正確に組み立てられる。異なる軸対を使えば
    /// （直交するため）常に類似度 0 の「別人」を作れる。
    private func axisSignature(_ axis0: Int, _ axis1: Int, angle: Double) -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[axis0] = Float(cos(angle))
        values[axis1] = Float(sin(angle))
        return FaceSignature(rawValues: values)!
    }

    // MARK: - 確定の基本条件

    func test_observe_admitsAfterThreeSightingsAcrossOneSecond() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()
        let sig = axisSignature(0, 1, angle: 0)

        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 0.0), [])
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 0.5), [])
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 1.0), [0])
    }

    func test_observe_ignoresSignaturesMatchingKnownPersons() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()
        let known = PersonProfile(exemplars: [axisSignature(0, 1, angle: 0)])
        let sig = axisSignature(0, 1, angle: 0)   // 既知人物と完全一致

        for t in stride(from: 0.0, through: 3.0, by: 0.5) {
            let result = arbiter.observe(signatures: [sig], knownPersons: [known], sourceID: source, sourceTime: t)
            XCTAssertEqual(result, [], "既知人物に一致する署名から新規候補を作っている")
        }
        XCTAssertEqual(arbiter.admittedCount, 0)
    }

    func test_observe_ignoresHoldBandSignatures() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()
        let known = PersonProfile(exemplars: [axisSignature(0, 1, angle: 0)])
        let holdBandAngle = acos(0.3)   // 既知人物との類似度 ≈ 0.3（distinct 0.25 〜 match 0.363 の帯）
        let sig = axisSignature(0, 1, angle: holdBandAngle)

        for t in [0.0, 0.5, 1.0] {
            let result = arbiter.observe(signatures: [sig], knownPersons: [known], sourceID: source, sourceTime: t)
            XCTAssertEqual(result, [], "判断保留の帯にある署名を候補にしている")
        }
        XCTAssertEqual(arbiter.admittedCount, 0, "判断保留の帯にある署名を新規候補として確定している")
    }

    /// **候補が溢れたとき、粘っている候補を押し出さない。**
    /// 捨てる基準を `firstSeen`（最初に見えた時刻）にすると、一番長く粘って確定に
    /// 近づいている候補から消える。群衆で新しい顔が次々来る動画では、あと 1 回で
    /// 確定するはずの人が押し出され続けて永遠に一覧へ出ない。
    func test_observe_overflowKeepsThePersistingCandidate() {
        var arbiter = EmergingPersonArbiter(
            limits: .init(maxCandidatesPerSource: 4))
        let source = UUID()
        // 粘っている人（最初から居て、ずっと見え続けている）。
        let persistent = axisSignature(0, 1, angle: 0)
        // 通りすがり（毎回ちがう別人が 1 回だけ写る）。互いに直交＝類似度 0。
        func passerby(_ n: Int) -> FaceSignature { axisSignature(2 + n * 2, 3 + n * 2, angle: 0) }

        var time = 0.0
        // 1 回目の目撃で候補ができる。
        _ = arbiter.observe(signatures: [persistent], knownPersons: [], sourceID: source, sourceTime: time)
        // 上限を超える人数の通りすがりを流す（粘っている人も毎回一緒に写っている）。
        for n in 0..<8 {
            time += 0.1
            _ = arbiter.observe(signatures: [persistent, passerby(n)],
                                knownPersons: [], sourceID: source, sourceTime: time)
        }
        // 1 秒の幅を満たす時刻で、粘っている人が確定すること
        // （押し出されていれば候補が作り直されており、ここで確定しない）。
        time = 1.2
        let admitted = arbiter.observe(signatures: [persistent], knownPersons: [],
                                       sourceID: source, sourceTime: time)
        XCTAssertEqual(admitted, [0], "溢れ処理が、粘って確定寸前だった候補を押し出している")
    }

    func test_observe_ignoresNilSignatures() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()

        for t in stride(from: 0.0, through: 5.0, by: 0.5) {
            let result = arbiter.observe(signatures: [nil, nil, nil], knownPersons: [],
                                         sourceID: source, sourceTime: t)
            XCTAssertEqual(result, [], "署名の無い観測から候補を作っている")
        }
        XCTAssertEqual(arbiter.admittedCount, 0)
    }

    // MARK: - TTL・シーク

    func test_observe_dropsCandidateAfterTTL() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()
        let sig = axisSignature(0, 1, angle: 0)

        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 0.0), [])
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 0.5), [])
        // TTL(5.0s) を超えるジャンプ。ここで候補は捨てられ、3回目の命中として数えられない。
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 6.0), [],
                       "TTL 超過後も候補が生き残っている")
        // 捨てられた後は新規候補としてやり直しになる。
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 6.5), [])
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 7.0), [0])
    }

    func test_observe_resetsCandidateOnSeekJump() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()
        let sig = axisSignature(0, 1, angle: 0)

        _ = arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 10.0)
        _ = arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 10.5)
        // シークで大きく巻き戻る（TTL 超の差分）。飛んだ差分を span に算入して即 admit してはならない。
        let jumped = arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 1.0)
        XCTAssertEqual(jumped, [], "シーク直後に古い候補の命中を引き継いで確定している")
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 1.5), [])
        XCTAssertEqual(arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 2.0), [0])
    }

    func test_observe_scopesCandidateClockPerSource() {
        var arbiter = EmergingPersonArbiter()
        let sourceA = UUID()
        let sourceB = UUID()
        let sigA = axisSignature(0, 1, angle: 0)
        let sigB = axisSignature(2, 3, angle: 0)

        _ = arbiter.observe(signatures: [sigA], knownPersons: [], sourceID: sourceA, sourceTime: 0.0)
        _ = arbiter.observe(signatures: [sigA], knownPersons: [], sourceID: sourceA, sourceTime: 0.5)
        // 別ソースではるか先の時刻を観測しても、sourceA の候補時計には影響しない。
        _ = arbiter.observe(signatures: [sigB], knownPersons: [], sourceID: sourceB, sourceTime: 100.0)
        let result = arbiter.observe(signatures: [sigA], knownPersons: [], sourceID: sourceA, sourceTime: 1.0)
        XCTAssertEqual(result, [0], "別ソースの時刻がこのソースの候補に影響している")
    }

    // MARK: - 1回の確定上限・間隔・セッション上限

    func test_observe_admitsAtMostOnePerObservation() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()
        let sigA = axisSignature(0, 1, angle: 0)
        let sigB = axisSignature(2, 3, angle: 0)

        _ = arbiter.observe(signatures: [sigA, sigB], knownPersons: [], sourceID: source, sourceTime: 0.0)
        _ = arbiter.observe(signatures: [sigA, sigB], knownPersons: [], sourceID: source, sourceTime: 0.5)
        let result = arbiter.observe(signatures: [sigA, sigB], knownPersons: [], sourceID: source, sourceTime: 1.0)
        XCTAssertEqual(result.count, 1, "1回の観測で2人以上確定している")
    }

    func test_observe_pacesAdmissionsByInterval() {
        var arbiter = EmergingPersonArbiter()
        let source = UUID()
        let sigA = axisSignature(0, 1, angle: 0)
        let sigB = axisSignature(2, 3, angle: 0)

        _ = arbiter.observe(signatures: [sigA, sigB], knownPersons: [], sourceID: source, sourceTime: 0.0)
        _ = arbiter.observe(signatures: [sigA, sigB], knownPersons: [], sourceID: source, sourceTime: 0.5)
        let admitA = arbiter.observe(signatures: [sigA], knownPersons: [], sourceID: source, sourceTime: 1.0)
        XCTAssertEqual(admitA, [0])
        // B はもう確定条件を満たしているが、確定直後（0.5s未満）なので見送られる。
        let blocked = arbiter.observe(signatures: [sigB], knownPersons: [], sourceID: source, sourceTime: 1.2)
        XCTAssertEqual(blocked, [], "確定の間隔を守らずに追加している")
        let admitB = arbiter.observe(signatures: [sigB], knownPersons: [], sourceID: source, sourceTime: 1.6)
        XCTAssertEqual(admitB, [0])
    }

    func test_observe_capsTotalAdmissions() {
        let limits = EmergingPersonArbiter.Limits(requiredHits: 3, requiredSpanSec: 1.0,
                                                   candidateTTLSec: 5.0, maxCandidatesPerSource: 16,
                                                   maxAdmissionsPerObservation: 1, admissionIntervalSec: 0,
                                                   maxSessionAdmissions: 2)
        var arbiter = EmergingPersonArbiter(limits: limits)
        let source = UUID()
        let sigA = axisSignature(0, 1, angle: 0)
        let sigB = axisSignature(2, 3, angle: 0)
        let sigC = axisSignature(4, 5, angle: 0)

        func build(_ sig: FaceSignature, at times: [Double]) -> [Int] {
            var last: [Int] = []
            for t in times {
                last = arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: t)
            }
            return last
        }

        XCTAssertEqual(build(sigA, at: [0.0, 0.5, 1.0]), [0])
        XCTAssertEqual(build(sigB, at: [1.0, 1.5, 2.0]), [0])
        XCTAssertEqual(build(sigC, at: [2.0, 2.5, 3.0]), [], "セッション上限に達した後も追加している")
        XCTAssertEqual(arbiter.admittedCount, 2)
    }

    // MARK: - 防波堤（変異検査で落ちることを確認する）

    /// 変異: 「同一バケットは命中に数えない」判定を削って `hitCount += 1` を無条件にする
    /// → この変異で落ちることを確認してから実装を復元すること。
    func test_observe_doesNotAdmitFromSingleFrameBurst() {
        let limits = EmergingPersonArbiter.Limits(requiredHits: 3, requiredSpanSec: 0.0,
                                                   candidateTTLSec: 5.0, maxCandidatesPerSource: 16,
                                                   maxAdmissionsPerObservation: 1, admissionIntervalSec: 0,
                                                   maxSessionAdmissions: 12)
        var arbiter = EmergingPersonArbiter(limits: limits)
        let source = UUID()
        let sig = axisSignature(0, 1, angle: 0)

        for _ in 0..<5 {
            let result = arbiter.observe(signatures: [sig], knownPersons: [], sourceID: source, sourceTime: 2.0)
            XCTAssertEqual(result, [], "同一バケットの連投で確定している（バーストで確定してはいけない）")
        }
    }
}
