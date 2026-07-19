import XCTest
@testable import MaskMe

/// OpticalFlowTracker（OpenCV 疎 LK ラッパー）の合成画像テスト。
/// 実動画は使わず、決定的なパターン画像で「既知の平行移動を追跡できるか」
/// 「特徴のない画像で正直に nil を返すか」を検証する。
final class OpticalFlowTrackerTests: XCTestCase {

    /// ランダムドットパターン（seed 固定の決定的疑似乱数）を offset だけずらして描く。
    /// 市松模様は自己相似で LK が格子1マス分ズレた解に収束し得るため、非周期な
    /// ランダムドットを使う。
    private func dotsImage(size: CGSize, offset: CGPoint) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size,
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            var state: UInt64 = 42
            func next() -> CGFloat {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(state >> 33) / CGFloat(UInt32.max)
            }
            for _ in 0..<400 {
                let x = next() * (size.width - 20) + 10 + offset.x
                let y = next() * (size.height - 20) + 10 + offset.y
                ctx.fill(CGRect(x: x, y: y, width: 3, height: 3))
            }
        }
    }

    private func flatImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size,
            format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func test_advance_tracksKnownTranslation() throws {
        let size = CGSize(width: 320, height: 240)
        let tracker = OpticalFlowTracker()
        let seeded = tracker.seed(with: dotsImage(size: size, offset: .zero),
                                  faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertTrue(seeded)
        let match = try XCTUnwrap(
            tracker.advance(with: dotsImage(size: size, offset: CGPoint(x: 9, y: 5))))
        XCTAssertGreaterThanOrEqual(match.previousPoints.count, 15)
        // 対応点の平均移動量が仕込んだオフセットと一致するはず
        var dx: CGFloat = 0, dy: CGFloat = 0
        for (p, c) in zip(match.previousPoints, match.currentPoints) {
            dx += c.cgPointValue.x - p.cgPointValue.x
            dy += c.cgPointValue.y - p.cgPointValue.y
        }
        dx /= CGFloat(match.previousPoints.count)
        dy /= CGFloat(match.previousPoints.count)
        XCTAssertEqual(dx, 9, accuracy: 1.0)
        XCTAssertEqual(dy, 5, accuracy: 1.0)
    }

    func test_seed_failsOnFlatImage() {
        let tracker = OpticalFlowTracker()
        let seeded = tracker.seed(with: flatImage(size: CGSize(width: 320, height: 240)),
                                  faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertFalse(seeded)   // 特徴点ゼロ → seed 失敗を正直に返す
    }

    func test_advance_returnsNilWhenTargetVanishes() {
        let size = CGSize(width: 320, height: 240)
        let tracker = OpticalFlowTracker()
        XCTAssertTrue(tracker.seed(with: dotsImage(size: size, offset: .zero),
                                   faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)))
        // パターンが消えたフレーム → 生存点が閾値を割り nil
        XCTAssertNil(tracker.advance(with: flatImage(size: size)))
    }

    func test_advance_withoutSeed_returnsNil() {
        let tracker = OpticalFlowTracker()
        XCTAssertNil(tracker.advance(with: flatImage(size: CGSize(width: 100, height: 100))))
    }

    /// 長辺が 640px を超える画像は内部で縮小してから追跡する（コスト上限の縮小経路）。
    /// 縮小・拡大の丸めで誤差が乗るため、許容誤差は等倍テストの ±1.0px より緩めた ±2.0px。
    func test_advance_tracksKnownTranslation_whenDownscaled() throws {
        let size = CGSize(width: 1280, height: 960)
        let tracker = OpticalFlowTracker()
        let seeded = tracker.seed(with: dotsImage(size: size, offset: .zero),
                                  faceBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertTrue(seeded)
        let match = try XCTUnwrap(
            tracker.advance(with: dotsImage(size: size, offset: CGPoint(x: 18, y: 10))))
        XCTAssertGreaterThanOrEqual(match.previousPoints.count, 15)
        var dx: CGFloat = 0, dy: CGFloat = 0
        for (p, c) in zip(match.previousPoints, match.currentPoints) {
            dx += c.cgPointValue.x - p.cgPointValue.x
            dy += c.cgPointValue.y - p.cgPointValue.y
        }
        dx /= CGFloat(match.previousPoints.count)
        dy /= CGFloat(match.previousPoints.count)
        XCTAssertEqual(dx, 18, accuracy: 2.0)
        XCTAssertEqual(dy, 10, accuracy: 2.0)
    }
}
