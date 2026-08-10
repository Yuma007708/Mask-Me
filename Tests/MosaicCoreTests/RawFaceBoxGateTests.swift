import CoreGraphics
import XCTest
@testable import MosaicCore

/// `RawFaceBoxGate` の不変条件を固定する。
///
/// 守っているのは **「素材の向きで判定が変わらないこと」**。
/// 大きさ・縦横比のどちらかでも正規化値のまま判定すると、同じ大きさ・同じ形の顔が
/// 横動画と縦動画で別の値になり、実顔が素材の向きだけで落ちる（実際に踏んだ事故）。
final class RawFaceBoxGateTests: XCTestCase {
    private let landscape = CGSize(width: 1280, height: 720)
    private let portrait = CGSize(width: 720, height: 1280)

    /// 中心に置いた「ピクセルで w x h の顔」を表す正規化矩形を作る。
    private func box(widthPixels: CGFloat, heightPixels: CGFloat, in size: CGSize) -> CGRect {
        let w = widthPixels / size.width
        let h = heightPixels / size.height
        return CGRect(x: 0.5 - w / 2, y: 0.5 - h / 2, width: w, height: h)
    }

    // MARK: - 向き非依存（本丸）

    /// 同じピクセル寸法の顔は、横動画でも縦動画でも同じ判定になる。
    /// 大きさ・縦横比のどちらかを正規化のまま判定すると、ここが割れる。
    func test_同じピクセル寸法の顔は素材の向きに依らず同じ判定になる() {
        for side in stride(from: CGFloat(20), through: 400, by: 10) {
            let landscapeVerdict = RawFaceBoxGate.accepts(
                box(widthPixels: side, heightPixels: side, in: landscape), imageSize: landscape)
            let portraitVerdict = RawFaceBoxGate.accepts(
                box(widthPixels: side, heightPixels: side, in: portrait), imageSize: portrait)
            XCTAssertEqual(landscapeVerdict, portraitVerdict,
                           "\(Int(side))px 四方の顔で判定が向きによって割れた "
                           + "(横=\(landscapeVerdict) 縦=\(portraitVerdict))")
        }
    }

    /// `probe_crowd_02` の実測値。1280x720 の会議室素材の顔は正規化 w=0.038〜0.043 で、
    /// 大きさを正規化のまま 6% で判定していた頃は**幅だけ**がゲートを割り、
    /// 生 bbox 18 件が全滅して 6 人写った動画にモザイクが 1 つも掛からなかった。
    func test_横動画の小さい実顔が幅の圧縮で落ちない_probe_crowd_02の実測値() {
        // 実測 5 件（正規化 w, h）。ピクセルでは 49〜55px 四方相当。
        let measured: [(CGFloat, CGFloat)] = [
            (0.039, 0.090), (0.038, 0.093), (0.038, 0.095), (0.043, 0.107), (0.038, 0.090)
        ]
        for (w, h) in measured {
            let rect = CGRect(x: 0.4, y: 0.4, width: w, height: h)
            XCTAssertTrue(RawFaceBoxGate.accepts(rect, imageSize: landscape),
                          "実顔 bbox (w=\(w), h=\(h)) が落ちた")
        }
    }

    // MARK: - 大きさゲート

    func test_短辺の6パーセント以上なら通り_下回ると落ちる() {
        // 720 の 6% = 43.2px
        XCTAssertTrue(RawFaceBoxGate.accepts(
            box(widthPixels: 44, heightPixels: 44, in: landscape), imageSize: landscape))
        XCTAssertFalse(RawFaceBoxGate.accepts(
            box(widthPixels: 42, heightPixels: 42, in: landscape), imageSize: landscape))
    }

    func test_幅と高さの両方が大きさゲートを満たす必要がある() {
        // 高さは十分だが幅が 30px（< 43.2px）
        XCTAssertFalse(RawFaceBoxGate.accepts(
            box(widthPixels: 30, heightPixels: 120, in: landscape), imageSize: landscape))
    }

    // MARK: - 縦横比ゲート

    func test_ピクセル換算の縦横比で判定する() {
        // 100x100px = 比 1.0 → 通る
        XCTAssertTrue(RawFaceBoxGate.accepts(
            box(widthPixels: 100, heightPixels: 100, in: landscape), imageSize: landscape))
        // 100x300px = 比 0.33 → 落ちる（縦長すぎ＝首・胸への誤フィット）
        XCTAssertFalse(RawFaceBoxGate.accepts(
            box(widthPixels: 100, heightPixels: 300, in: landscape), imageSize: landscape))
        // 300x100px = 比 3.0 → 落ちる（横長すぎ）
        XCTAssertFalse(RawFaceBoxGate.accepts(
            box(widthPixels: 300, heightPixels: 100, in: landscape), imageSize: landscape))
    }

    func test_縦横比の判定も素材の向きに依らない() {
        // 比 0.55（レンジ内の下端寄り）と 0.45（レンジ外）を両方の向きで確認する。
        for (w, h, expected) in [(CGFloat(110), CGFloat(200), true), (90, 200, false)] {
            XCTAssertEqual(
                RawFaceBoxGate.accepts(box(widthPixels: w, heightPixels: h, in: landscape),
                                       imageSize: landscape),
                expected)
            XCTAssertEqual(
                RawFaceBoxGate.accepts(box(widthPixels: w, heightPixels: h, in: portrait),
                                       imageSize: portrait),
                expected)
        }
    }

    // MARK: - 退化入力

    func test_退化した矩形と画像サイズは棄却する() {
        XCTAssertFalse(RawFaceBoxGate.accepts(
            CGRect(x: 0.4, y: 0.4, width: 0, height: 0.2), imageSize: landscape))
        XCTAssertFalse(RawFaceBoxGate.accepts(
            CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0), imageSize: landscape))
        XCTAssertFalse(RawFaceBoxGate.accepts(
            CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), imageSize: .zero))
    }
}
