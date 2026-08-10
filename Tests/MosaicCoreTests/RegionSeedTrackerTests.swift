import CoreGraphics
import XCTest
@testable import MosaicCore

/// シード（ユーザーが矩形で指定した顔）を前後へ追い続ける歩幅・ROI 決定ロジックの契約を固定する。
///
/// 守っているのは 3 つ:
///
/// 1. **ROI は連続ミスに応じて段階的に広がり、3 回目で全画面、4 回目で追跡終了**。
///    いきなり全画面にすると誤検出を拾いやすく、逆に狭いままだと見失って終わる。
/// 2. **同定できない・位置的にも近くない候補は採らない（ミスにする）**。
///    ここで妥協すると追跡が別人へ乗り移り、露出方向の事故になる。
/// 3. **等速外挿で ROI 中心が実際の動きに追随する**。静止顔前提だと動く顔を見失う。
final class RegionSeedTrackerTests: XCTestCase {
    private func face(_ box: CGRect) -> FaceLandmarkSet {
        // boundingBox は points の min/max から作られるので、矩形の四隅を置けば
        // ちょうど box に一致する bbox を持つ顔になる。
        let points = [
            FaceLandmark(x: Float(box.minX), y: Float(box.minY)),
            FaceLandmark(x: Float(box.maxX), y: Float(box.maxY)),
            FaceLandmark(x: Float(box.minX), y: Float(box.maxY)),
            FaceLandmark(x: Float(box.maxX), y: Float(box.minY))
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    // MARK: 1. 終了時刻

    func test_前方は上限で終わり後方は下限で終わる() {
        // range を歩幅 (0.2) の整数倍に揃え、最後の一歩がちょうど端に乗るようにする。
        // ミスを重ねると連続ミス上限で終了してしまうため（別の観点のテストで検証済み）、
        // ここでは常にヒットさせて「歩幅で range を歩き切る」経路だけを確認する。
        let box = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var forward = RegionSeedTracker(seedTime: 0.0, seedBox: box, range: 0.0...1.0, direction: .forward)
        var lastForwardTime: Double?
        while let step = forward.nextStep() {
            lastForwardTime = step.sourceTime
            _ = forward.accept(candidates: [face(box)], similarities: nil)
        }
        XCTAssertEqual(lastForwardTime ?? .nan, 1.0, accuracy: 1e-9, "前方インスタンスが range.upperBound で終わっていない")

        var backward = RegionSeedTracker(seedTime: 1.0, seedBox: box, range: 0.0...1.0, direction: .backward)
        var lastBackwardTime: Double?
        while let step = backward.nextStep() {
            lastBackwardTime = step.sourceTime
            _ = backward.accept(candidates: [face(box)], similarities: nil)
        }
        XCTAssertEqual(lastBackwardTime ?? .nan, 0.0, accuracy: 1e-9, "後方インスタンスが range.lowerBound で終わっていない")
    }

    // MARK: 2. ROI 倍率

    func test_ROIは直近ヒットのbboxを2倍に膨らませたもの() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)
        guard let step = sut.nextStep() else { return XCTFail("最初の nextStep が nil") }
        // 中心 (0.45, 0.5) はそのまま、幅 0.1→0.2、高さ 0.2→0.4（短辺 0.2 は 0.15 を上回るので拡大なし）。
        XCTAssertEqual(step.roi.width, 0.2, accuracy: 1e-9, "ROI 幅が bbox の 2 倍になっていない")
        XCTAssertEqual(step.roi.height, 0.4, accuracy: 1e-9, "ROI 高さが bbox の 2 倍になっていない")
        XCTAssertEqual(step.roi.midX, seedBox.midX, accuracy: 1e-9, "ROI の中心 x が直近ヒットとずれている")
        XCTAssertEqual(step.roi.midY, seedBox.midY, accuracy: 1e-9, "ROI の中心 y が直近ヒットとずれている")
    }

    // MARK: 3. 短辺下限とアスペクト比

    func test_ROI短辺は下限を下回らず縦横比を保つ() {
        // bbox 0.02×0.01 を 2 倍しても短辺 0.02 は 0.15 未満なので拡大がかかる。
        let seedBox = CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.01)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)
        guard let step = sut.nextStep() else { return XCTFail("最初の nextStep が nil") }
        let shortSide = min(step.roi.width, step.roi.height)
        XCTAssertGreaterThanOrEqual(shortSide, 0.15 - 1e-9, "ROI 短辺が下限 0.15 を下回っている")
        // 元の比 2:1 が保たれているか。
        let originalRatio = seedBox.width / seedBox.height
        let scaledRatio = step.roi.width / step.roi.height
        XCTAssertEqual(scaledRatio, originalRatio, accuracy: 1e-6, "拡大後に縦横比が保たれていない")
    }

    // MARK: 4. ミスのたびに ROI が広がる

    func test_ミスのたびにROIが3倍4_5倍全画面へ広がる() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)

        _ = sut.nextStep() // 連続ミス 0 → 2.0 倍（検算済み）
        _ = sut.accept(candidates: [], similarities: nil)

        guard let step1 = sut.nextStep() else { return XCTFail("1 回目ミス後の nextStep が nil") }
        XCTAssertEqual(step1.roi.width, seedBox.width * 3.0, accuracy: 1e-9, "1 回ミス後に ROI が 3.0 倍になっていない")
        XCTAssertFalse(step1.isFullFrame, "1 回ミスの時点で全画面になっている")
        _ = sut.accept(candidates: [], similarities: nil)

        guard let step2 = sut.nextStep() else { return XCTFail("2 回目ミス後の nextStep が nil") }
        XCTAssertEqual(step2.roi.width, seedBox.width * 4.5, accuracy: 1e-9, "2 回ミス後に ROI が 4.5 倍になっていない")
        XCTAssertFalse(step2.isFullFrame, "2 回ミスの時点で全画面になっている")
        _ = sut.accept(candidates: [], similarities: nil)

        guard let step3 = sut.nextStep() else { return XCTFail("3 回目ミス後の nextStep が nil") }
        XCTAssertTrue(step3.isFullFrame, "3 回連続ミスで全画面フォールバックになっていない")
        XCTAssertEqual(step3.roi, CGRect(x: 0, y: 0, width: 1, height: 1), "全画面フォールバックの矩形が [0,1]² になっていない")
    }

    // MARK: 5. 連続ミス上限で終了

    func test_連続ミス4回でnextStepがnilになる() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...100, direction: .forward)
        for _ in 0..<4 {
            XCTAssertNotNil(sut.nextStep(), "連続ミス上限に達する前に nextStep が nil になった")
            let outcome = sut.accept(candidates: [], similarities: nil)
            if outcome.isFinished {
                XCTAssertNil(sut.nextStep(), "isFinished 後も nextStep が値を返している")
                return
            }
        }
        XCTFail("4 回ミスしても isFinished が立たなかった")
    }

    // MARK: 6. 再ヒットで連続ミスカウンタが 0 に戻る

    func test_ミスの後に再ヒットしたら連続ミスがリセットされROIが2倍に戻る() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)

        _ = sut.nextStep()
        _ = sut.accept(candidates: [], similarities: nil) // 1 回ミス

        guard let missStep = sut.nextStep() else { return XCTFail("nextStep が nil") }
        // ミス後の ROI 中心 = 直近ヒット(シード)の中心のまま。
        let hitFace = face(CGRect(x: seedBox.minX, y: seedBox.minY, width: seedBox.width, height: seedBox.height))
        let outcome = sut.accept(candidates: [hitFace], similarities: nil)
        XCTAssertEqual(outcome.chosenIndex, 0, "予測中心に一致する候補を採らなかった")
        _ = missStep

        guard let nextStep = sut.nextStep() else { return XCTFail("再ヒット後の nextStep が nil") }
        XCTAssertEqual(nextStep.roi.width, seedBox.width * 2.0, accuracy: 1e-6, "再ヒット後に ROI が 2.0 倍に戻っていない")
    }

    // MARK: 7. 類似度が最大かつ閾値以上を選ぶ

    func test_候補が複数のとき類似度が最大かつ閾値以上のものを選ぶ() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)
        _ = sut.nextStep()

        let candidates = [
            face(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)),
            face(CGRect(x: 0.41, y: 0.4, width: 0.1, height: 0.1))
        ]
        let similarities: [Float] = [FaceIdentityThreshold.match - 0.01, FaceIdentityThreshold.match + 0.1]
        let outcome = sut.accept(candidates: candidates, similarities: similarities)
        XCTAssertEqual(outcome.chosenIndex, 1, "類似度が最大かつ閾値以上の候補を選んでいない")
    }

    // MARK: 8. 類似度最大でも閾値未満なら位置判定に落ちる

    func test_類似度が最大でも閾値未満なら位置判定に落ちる() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)
        _ = sut.nextStep()

        // 候補0 は予測中心（シード中心）に一致、候補1 は遠いが類似度は高い（ただし閾値未満）。
        let candidates = [
            face(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)),
            face(CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1))
        ]
        let similarities: [Float] = [FaceIdentityThreshold.distinct, FaceIdentityThreshold.match - 0.05]
        let outcome = sut.accept(candidates: candidates, similarities: similarities)
        XCTAssertEqual(outcome.chosenIndex, 0, "閾値未満の類似度で決め打ちせず位置判定に落ちていない")
    }

    // MARK: 9. similarities が nil のとき予測中心に最も近い候補を選ぶ

    func test_similaritiesがnilのとき予測中心に最も近い候補を選ぶ() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)
        _ = sut.nextStep()

        let candidates = [
            face(CGRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1)),
            face(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))
        ]
        let outcome = sut.accept(candidates: candidates, similarities: nil)
        XCTAssertEqual(outcome.chosenIndex, 1, "予測中心に最も近い候補を選んでいない")
    }

    // MARK: 10. ROI 短辺の半分を超えて離れた候補はミスになる

    func test_予測中心から離れすぎた候補はミスになる() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)
        _ = sut.nextStep() // ROI は 0.2×0.2、短辺 0.2、許容 0.1

        let farFace = face(CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1))
        let outcome = sut.accept(candidates: [farFace], similarities: nil)
        XCTAssertNil(outcome.chosenIndex, "許容を超えて離れた候補を採ってしまっている")
    }

    // MARK: 11. maxSteps で終了

    func test_maxStepsに達したら終わる() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var options = RegionSeedTracker.Options()
        options.maxSteps = 3
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...1000, direction: .forward,
                                    options: options)
        var count = 0
        while sut.nextStep() != nil {
            count += 1
            _ = sut.accept(candidates: [], similarities: nil)
            XCTAssertLessThanOrEqual(count, 3, "maxSteps を超えて歩き続けている")
        }
        XCTAssertEqual(count, 3, "maxSteps ちょうどで終わっていない")
    }

    // MARK: 12. 画面端でのクランプ

    func test_ROIは画面端で0から1にクランプされる() {
        let seedBox = CGRect(x: 0.02, y: 0.02, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)
        guard let step = sut.nextStep() else { return XCTFail("nextStep が nil") }
        XCTAssertGreaterThanOrEqual(step.roi.minX, 0, "ROI が左端をはみ出している")
        XCTAssertGreaterThanOrEqual(step.roi.minY, 0, "ROI が上端をはみ出している")
        XCTAssertLessThanOrEqual(step.roi.maxX, 1, "ROI が右端をはみ出している")
        XCTAssertLessThanOrEqual(step.roi.maxY, 1, "ROI が下端をはみ出している")
    }

    // MARK: 13. 等速外挿

    func test_等速外挿でROI中心が実際の顔位置に追随する() {
        // 顔が x 方向に毎ステップ (0.2 秒) 0.05 動く = 0.25 正規化/秒。
        let seedBox = CGRect(x: 0.1, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0, seedBox: seedBox, range: 0...10, direction: .forward)

        var trueOriginX: CGFloat = 0.1
        var lastCentroidX: CGFloat = seedBox.midX
        for _ in 0..<3 {
            guard sut.nextStep() != nil else { return XCTFail("nextStep が nil") }
            trueOriginX += 0.05
            let hitBox = CGRect(x: trueOriginX, y: 0.4, width: 0.1, height: 0.1)
            let outcome = sut.accept(candidates: [face(hitBox)], similarities: nil)
            XCTAssertEqual(outcome.chosenIndex, 0, "等速で動く顔を見失っている")
            lastCentroidX = hitBox.midX
        }

        // 4 歩目: 直近の速度 (0.25/s) を反映した外挿で、ROI 中心が次の真の位置に来ているはず。
        guard let step4 = sut.nextStep() else { return XCTFail("4 歩目の nextStep が nil") }
        let expectedCenterX = lastCentroidX + 0.25 * 0.2
        XCTAssertEqual(step4.roi.midX, expectedCenterX, accuracy: 1e-6,
                      "等速外挿の ROI 中心が実際の動きに追随していない")
    }

    // MARK: 14. 端点ステップ

    func test_tracker_emitsClampedBoundaryStep() {
        // range 0...1, seed 0.5, step 0.2（既定）で後方へ歩くと 0.3, 0.1 の次は -0.1 で
        // range を出る。直前の 0.1 は range の内側だったので、クランプした下限 0.0 が
        // 最後の1ステップとして出るはず。
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0.5, seedBox: seedBox, range: 0...1, direction: .backward)

        var emitted: [Double] = []
        while let step = sut.nextStep() {
            emitted.append(step.sourceTime)
            _ = sut.accept(candidates: [face(seedBox)], similarities: nil)
        }
        XCTAssertEqual(emitted.count, 3, "端点クランプを含めたステップ数が想定と違う")
        if emitted.count == 3 {
            XCTAssertEqual(emitted[0], 0.3, accuracy: 1e-9)
            XCTAssertEqual(emitted[1], 0.1, accuracy: 1e-9)
            XCTAssertEqual(emitted[2], 0.0, accuracy: 1e-9, "端点クランプ（range.lowerBound）が出ていない")
        }
    }

    func test_tracker_boundaryStepEmittedOnce_thenFinishes() {
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0.5, seedBox: seedBox, range: 0...1, direction: .backward)

        var stepCount = 0
        while sut.nextStep() != nil {
            stepCount += 1
            _ = sut.accept(candidates: [face(seedBox)], similarities: nil)
        }
        XCTAssertEqual(stepCount, 3, "端点ステップの後にも歩き続けている")
        XCTAssertNil(sut.nextStep(), "終了後も nextStep が値を返している")
    }

    func test_tracker_noDuplicateStepWhenSeedAlignsWithBoundary() {
        // seed 0.4, range 0...1, step 0.2 は割り切れるので、後方は 0.2 → 0.0（残差 0）で
        // 自然に下限へ乗る。この場合はクランプ用の重複ステップを出してはいけない。
        let seedBox = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)
        var sut = RegionSeedTracker(seedTime: 0.4, seedBox: seedBox, range: 0...1, direction: .backward)

        var emitted: [Double] = []
        while let step = sut.nextStep() {
            emitted.append(step.sourceTime)
            _ = sut.accept(candidates: [face(seedBox)], similarities: nil)
        }
        XCTAssertEqual(emitted.count, 2, "残差0の端点で重複ステップが出ている")
        if emitted.count == 2 {
            XCTAssertEqual(emitted[0], 0.2, accuracy: 1e-9)
            XCTAssertEqual(emitted[1], 0.0, accuracy: 1e-9)
        }
        XCTAssertNil(sut.nextStep(), "境界ちょうどで終わった後にも歩き続けている")
    }
}
