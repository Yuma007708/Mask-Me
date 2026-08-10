import XCTest
import CoreGraphics
@testable import MosaicCore

/// 毎フレーム前進層の検証。合成した対応点ペア（既知の相似変換をグリッド点へ
/// 適用したもの）で駆動し、前進・stale 検出補正・外挿・凍結・ブレンドを確かめる。
final class LiveFacePropagatorTests: XCTestCase {
    private let imageSize = CGSize(width: 1000, height: 1000)

    /// 中心 `(cx, cy)`・辺 `span` の正方形顔（正規化座標）。
    private func face(cx: Float, cy: Float, span: Float = 0.2) -> FaceLandmarkSet {
        let half = span / 2
        let points = [
            FaceLandmark(x: cx - half, y: cy - half),
            FaceLandmark(x: cx + half, y: cy - half),
            FaceLandmark(x: cx - half, y: cy + half),
            FaceLandmark(x: cx + half, y: cy + half),
            FaceLandmark(x: cx, y: cy)
        ]
        return FaceLandmarkSet(points: points, confidence: 1)
    }

    private func centroid(_ set: FaceLandmarkSet) -> (x: Float, y: Float) {
        let n = Float(set.points.count)
        return (set.points.map(\.x).reduce(0, +) / n,
                set.points.map(\.y).reduce(0, +) / n)
    }

    /// 顔周辺のグリッド点に既知変換を適用した対応点ペア（ピクセル空間）。
    private func observation(
        around center: CGPoint, transform: SimilarityTransform
    ) -> LiveFacePropagator.FlowObservation {
        var from: [CGPoint] = []
        for gx in -2...2 {
            for gy in -2...2 {
                from.append(CGPoint(x: center.x + CGFloat(gx) * 30,
                                    y: center.y + CGFloat(gy) * 30))
            }
        }
        return .init(from: from, to: from.map(transform.applyPoint))
    }

    /// begin → complete で顔をトラックへ投入する（パイプラインと同じ流れ）。
    private func seed(_ propagator: LiveFacePropagator, faces: [FaceLandmarkSet]) {
        let token = propagator.beginDetection()
        propagator.completeDetection(token: token, faces: faces, imageSize: imageSize)
    }

    // MARK: - 前進

    func test_advance_translatesLandmarksByFlow() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.5, cy: 0.5)])
        // +50px, +20px の並進フロー → 正規化で +0.05, +0.02
        let t = SimilarityTransform(scale: 1, rotation: 0, tx: 50, ty: 20)
        propagator.advance(
            observations: [observation(around: CGPoint(x: 500, y: 500), transform: t)],
            imageSize: imageSize)
        let c = centroid(propagator.faces[0])
        XCTAssertEqual(c.x, 0.55, accuracy: 0.001)
        XCTAssertEqual(c.y, 0.52, accuracy: 0.001)
    }

    func test_advance_rejectsScaleOutsideGate() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.5, cy: 0.5)])
        // 2 倍スケールはゲート (0.7...1.4) 外 → 誤追跡として無視（速度 0 なので不動）
        let t = SimilarityTransform(scale: 2.0, rotation: 0, tx: 0, ty: 0)
        propagator.advance(
            observations: [observation(around: CGPoint(x: 500, y: 500), transform: t)],
            imageSize: imageSize)
        let c = centroid(propagator.faces[0])
        XCTAssertEqual(c.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.y, 0.5, accuracy: 0.001)
        XCTAssertTrue(propagator.isExtrapolating(at: 0))
    }

    // MARK: - stale 検出補正（本改修の核心）

    func test_staleDetection_isCorrectedToCurrentFrame() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.3, cy: 0.3)])
        // 検出を発行（この時点の位置 = 0.3, 0.3 が「古い結果」として返ってくる）
        let token = propagator.beginDetection()
        // 検出中に 3 フレーム、+30px ずつ右へ動く
        let step = SimilarityTransform(scale: 1, rotation: 0, tx: 30, ty: 0)
        var center = CGPoint(x: 300, y: 300)
        for _ in 0..<3 {
            propagator.advance(
                observations: [observation(around: center, transform: step)],
                imageSize: imageSize)
            center.x += 30
        }
        // 古い検出（発行時点の位置）が届く → 累積 +90px = +0.09 補正されて採用
        propagator.completeDetection(
            token: token, faces: [face(cx: 0.3, cy: 0.3)], imageSize: imageSize)
        let c = centroid(propagator.faces[0])
        XCTAssertEqual(c.x, 0.39, accuracy: 0.005, "stale 検出が現フレームへ補正されていない")
        XCTAssertEqual(c.y, 0.3, accuracy: 0.005)
    }

    func test_completeDetection_ignoresStaleToken() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.5, cy: 0.5)])
        let oldToken = propagator.beginDetection()
        _ = propagator.beginDetection()   // 新しい検出が発行された（旧 token は無効）
        propagator.completeDetection(
            token: oldToken, faces: [face(cx: 0.9, cy: 0.9)], imageSize: imageSize)
        let c = centroid(propagator.faces[0])
        XCTAssertEqual(c.x, 0.5, accuracy: 0.001, "無効 token の検出が採用された")
    }

    // MARK: - フロー失敗 → 外挿 → 凍結

    func test_flowFailure_extrapolatesWithVelocityThenFreezes() {
        let propagator = LiveFacePropagator(maxExtrapolationFrames: 3)
        seed(propagator, faces: [face(cx: 0.4, cy: 0.5)])
        // 等速 +20px/フレームで速度を作る
        let step = SimilarityTransform(scale: 1, rotation: 0, tx: 20, ty: 0)
        var center = CGPoint(x: 400, y: 500)
        for _ in 0..<8 {
            propagator.advance(
                observations: [observation(around: center, transform: step)],
                imageSize: imageSize)
            center.x += 20
        }
        let beforeLoss = centroid(propagator.faces[0]).x
        // フロー失敗 → 外挿で進み続ける（露出防止: 急停止させない）
        propagator.advance(observations: [nil], imageSize: imageSize)
        let after1 = centroid(propagator.faces[0]).x
        XCTAssertGreaterThan(after1, beforeLoss + 0.005, "外挿で前進していない")
        XCTAssertTrue(propagator.isExtrapolating(at: 0))
        // 上限を超えたら凍結（当てずっぽうの等速前進を続けない）
        for _ in 0..<5 { propagator.advance(observations: [nil], imageSize: imageSize) }
        let frozen = centroid(propagator.faces[0]).x
        propagator.advance(observations: [nil], imageSize: imageSize)
        XCTAssertEqual(centroid(propagator.faces[0]).x, frozen, accuracy: 0.0001,
                       "凍結後も動いている")
    }

    func test_flowRecovery_resumesFromDetection() {
        let propagator = LiveFacePropagator(maxExtrapolationFrames: 2)
        seed(propagator, faces: [face(cx: 0.5, cy: 0.5)])
        for _ in 0..<4 { propagator.advance(observations: [nil], imageSize: imageSize) }
        // 実検出が来たら合流して外挿状態から復帰する
        let token = propagator.beginDetection()
        propagator.completeDetection(
            token: token, faces: [face(cx: 0.52, cy: 0.5)], imageSize: imageSize)
        XCTAssertFalse(propagator.isExtrapolating(at: 0))
    }

    // MARK: - 合流の残差ブレンド

    func test_smallResidual_blendsOverFrames() {
        let propagator = LiveFacePropagator(blendFrames: 3)
        seed(propagator, faces: [face(cx: 0.5, cy: 0.5)])
        // 前進なしのまま、+0.02 ずれた検出が合流（検出ジッタ相当）
        let token = propagator.beginDetection()
        propagator.completeDetection(
            token: token, faces: [face(cx: 0.52, cy: 0.5)], imageSize: imageSize)
        // 直後はまだ中間（ポップしない）
        let first = centroid(propagator.faces[0]).x
        XCTAssertGreaterThan(first, 0.5)
        XCTAssertLessThan(first, 0.52)
        // 静止フロー（恒等変換）を流しつつブレンドフレーム経過 → 検出位置に収束
        let still = observation(around: CGPoint(x: 520, y: 500), transform: .identity)
        for _ in 0..<3 { propagator.advance(observations: [still], imageSize: imageSize) }
        XCTAssertEqual(centroid(propagator.faces[0]).x, 0.52, accuracy: 0.0001)
    }

    func test_largeResidual_snapsImmediately() {
        let propagator = LiveFacePropagator(blendFrames: 3, snapDistance: 0.05)
        seed(propagator, faces: [face(cx: 0.5, cy: 0.5)])
        let token = propagator.beginDetection()
        // 0.2 のずれは snapDistance 超 → ブレンドせず即スナップ…だが IoU 対応も
        // 外れるので新顔として採用される（どちらでも表示は即検出位置）
        propagator.completeDetection(
            token: token, faces: [face(cx: 0.7, cy: 0.5)], imageSize: imageSize)
        XCTAssertEqual(centroid(propagator.faces[0]).x, 0.7, accuracy: 0.0001)
    }

    // MARK: - 順序・複数顔

    func test_trackOrder_followsDetectionOrder() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.3, cy: 0.3), face(cx: 0.7, cy: 0.7)])
        // 検出順が入れ替わっても、トラックは新しい検出配列の順序に一致する
        // （呼び出し側は検出合流のたびに添字ベースの選択を再計算する前提）
        let token = propagator.beginDetection()
        propagator.completeDetection(
            token: token,
            faces: [face(cx: 0.7, cy: 0.7), face(cx: 0.3, cy: 0.3)],
            imageSize: imageSize)
        XCTAssertEqual(centroid(propagator.faces[0]).x, 0.7, accuracy: 0.001)
        XCTAssertEqual(centroid(propagator.faces[1]).x, 0.3, accuracy: 0.001)
    }

    func test_multipleFaces_advanceIndependently() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.3, cy: 0.5), face(cx: 0.7, cy: 0.5)])
        let right = SimilarityTransform(scale: 1, rotation: 0, tx: 40, ty: 0)
        let down = SimilarityTransform(scale: 1, rotation: 0, tx: 0, ty: 40)
        propagator.advance(
            observations: [
                observation(around: CGPoint(x: 300, y: 500), transform: right),
                observation(around: CGPoint(x: 700, y: 500), transform: down)
            ],
            imageSize: imageSize)
        XCTAssertEqual(centroid(propagator.faces[0]).x, 0.34, accuracy: 0.001)
        XCTAssertEqual(centroid(propagator.faces[0]).y, 0.5, accuracy: 0.001)
        XCTAssertEqual(centroid(propagator.faces[1]).x, 0.7, accuracy: 0.001)
        XCTAssertEqual(centroid(propagator.faces[1]).y, 0.54, accuracy: 0.001)
    }

    func test_newFace_isAdoptedWithoutCorrection() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.3, cy: 0.3)])
        let token = propagator.beginDetection()
        propagator.completeDetection(
            token: token,
            faces: [face(cx: 0.3, cy: 0.3), face(cx: 0.8, cy: 0.8)],
            imageSize: imageSize)
        XCTAssertEqual(propagator.count, 2)
        XCTAssertEqual(centroid(propagator.faces[1]).x, 0.8, accuracy: 0.001)
    }

    // MARK: - 検出との添字対応（カメラの署名配線が依存する不変条件）

    /// **`completeDetection` 後の `faces` は、渡した検出顔と同じ順・同じ件数であること。**
    ///
    /// `CameraMosaicPipeline` は検出顔から測った署名の配列を、そのまま
    /// `propagator.faces` の添字で `CameraFaceSelection` へ渡す。ここが崩れると
    /// **別人の署名で OFF の可否を判断する**（乗り移り拒否が逆に働き、露出しうる）。
    func test_completeDetection_keepsDetectionOrderAndCount() {
        let propagator = LiveFacePropagator()
        // 既存トラックがある状態で、順序の違う検出が届く場面を作る
        seed(propagator, faces: [face(cx: 0.2, cy: 0.5), face(cx: 0.8, cy: 0.5)])

        let detected = [face(cx: 0.8, cy: 0.5), face(cx: 0.5, cy: 0.9), face(cx: 0.2, cy: 0.5)]
        seed(propagator, faces: detected)

        XCTAssertEqual(propagator.faces.count, detected.count, "件数が検出と食い違っている")
        for (i, expected) in detected.enumerated() {
            XCTAssertEqual(centroid(propagator.faces[i]).x, centroid(expected).x, accuracy: 0.01,
                           "\(i) 番目が検出と別の顔になっている（署名が別人に配られる）")
            XCTAssertEqual(centroid(propagator.faces[i]).y, centroid(expected).y, accuracy: 0.01)
        }
    }

    // MARK: - リセット

    func test_reset_dropsAllTracks() {
        let propagator = LiveFacePropagator()
        seed(propagator, faces: [face(cx: 0.5, cy: 0.5)])
        propagator.reset()
        XCTAssertTrue(propagator.isEmpty)
        XCTAssertEqual(propagator.faces.count, 0)
    }
}
