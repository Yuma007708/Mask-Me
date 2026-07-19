import CoreGraphics
import UIKit
import XCTest
import MosaicCore
@testable import MaskMe

/// フロー前進ブリッジ（MMGrayFrame 共有 + CameraFlowAdvancer）の検証。
/// テクスチャ入りの合成画像を既知の並進で動かし、seed → advance の対応点から
/// 推定した相似変換が真値の並進を復元することを確かめる（OpenCV リンク・
/// 座標スケール復元・共有フレーム API の結線チェック）。
final class CameraFlowAdvancerTests: XCTestCase {
    /// 決定的な擬似乱数（テスト再現性のため線形合同法）。
    private struct Lcg {
        var state: UInt64 = 0x2545F491
        mutating func next(_ bound: Int) -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            // 上位 32 ビットを [0, 1) に正規化（ビット数と除数を揃えること。
            // ずれると値域が半分になり、矩形が画像の半分にしか描かれない）
            return CGFloat(state >> 32) / (CGFloat(UInt32.max) + 1) * CGFloat(bound)
        }
    }

    /// グレー背景に多数の濃淡矩形を敷いたテクスチャ画像。`offset` で全体を並進。
    private func textureImage(size: CGSize, offset: CGPoint) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.5, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // 矩形はシフト量（数px）より十分大きくする。エッジ間隔がシフトと
            // 同オーダーだと LK が隣の似た角へ誤マッチし、前後方向チェックで
            // 生存点が枯れてテストが不安定になる。
            var rng = Lcg()
            for _ in 0..<250 {
                let x = rng.next(Int(size.width))
                let y = rng.next(Int(size.height))
                let side = 12 + rng.next(20)
                UIColor(white: rng.next(1000) / 1000, alpha: 1).setFill()
                ctx.fill(CGRect(x: x + offset.x, y: y + offset.y,
                                width: side, height: side))
            }
        }
    }

    private func estimateTranslation(
        imageSize: CGSize, shift: CGPoint
    ) throws -> SimilarityTransform {
        let advancer = CameraFlowAdvancer()
        let frame0 = try XCTUnwrap(MMGrayFrame(
            image: textureImage(size: imageSize, offset: .zero),
            maxLongSide: CameraFlowAdvancer.maxLongSide))
        advancer.reseed(frame: frame0,
                        faceBoxes: [CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)])
        let frame1 = try XCTUnwrap(MMGrayFrame(
            image: textureImage(size: imageSize, offset: shift),
            maxLongSide: CameraFlowAdvancer.maxLongSide))
        let observations = advancer.advance(frame: frame1)
        XCTAssertEqual(observations.count, 1)
        let obs = try XCTUnwrap(observations[0], "フロー品質ゲートを通らなかった")
        return try XCTUnwrap(
            SimilarityTransform.estimate(from: obs.from, to: obs.to),
            "相似変換を推定できなかった")
    }

    /// 等倍（縮小なし）: 既知並進 ±1px で復元できること。
    func test_advance_recoversTranslation_atFullScale() throws {
        let t = try estimateTranslation(
            imageSize: CGSize(width: 640, height: 480),
            shift: CGPoint(x: 6, y: 4))
        XCTAssertEqual(t.tx, 6, accuracy: 1.0)
        XCTAssertEqual(t.ty, 4, accuracy: 1.0)
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.02)
    }

    /// 縮小経路（長辺 1280 → 640、scale=2）: フルフレーム px へ復元されること。
    func test_advance_recoversTranslation_withDownscale() throws {
        let t = try estimateTranslation(
            imageSize: CGSize(width: 1280, height: 960),
            shift: CGPoint(x: 12, y: -8))
        XCTAssertEqual(t.tx, 12, accuracy: 2.0)
        XCTAssertEqual(t.ty, -8, accuracy: 2.0)
        XCTAssertEqual(t.scale, 1.0, accuracy: 0.02)
    }

    /// 複数顔が 1 枚の共有グレーフレームで独立に追跡されること。
    func test_multipleTrackers_shareOneGrayFrame() throws {
        let size = CGSize(width: 640, height: 480)
        let advancer = CameraFlowAdvancer()
        let frame0 = try XCTUnwrap(MMGrayFrame(
            image: textureImage(size: size, offset: .zero),
            maxLongSide: CameraFlowAdvancer.maxLongSide))
        advancer.reseed(frame: frame0, faceBoxes: [
            CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8),
            CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8)
        ])
        let frame1 = try XCTUnwrap(MMGrayFrame(
            image: textureImage(size: size, offset: CGPoint(x: 5, y: 3)),
            maxLongSide: CameraFlowAdvancer.maxLongSide))
        let observations = advancer.advance(frame: frame1)
        XCTAssertEqual(observations.count, 2)
        for obs in observations {
            let o = try XCTUnwrap(obs)
            let t = try XCTUnwrap(SimilarityTransform.estimate(from: o.from, to: o.to))
            XCTAssertEqual(t.tx, 5, accuracy: 1.5)
            XCTAssertEqual(t.ty, 3, accuracy: 1.5)
        }
    }

    func test_reset_dropsTrackers() throws {
        let advancer = CameraFlowAdvancer()
        let frame = try XCTUnwrap(MMGrayFrame(
            image: textureImage(size: CGSize(width: 640, height: 480), offset: .zero),
            maxLongSide: CameraFlowAdvancer.maxLongSide))
        advancer.reseed(frame: frame,
                        faceBoxes: [CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)])
        advancer.reset()
        XCTAssertTrue(advancer.isEmpty)
        XCTAssertTrue(advancer.advance(frame: frame).isEmpty)
    }
}
