import CoreGraphics
import XCTest
@testable import MosaicCore

/// 物体マスクの傾き（`ObjectMask.Keyframe.angle`）の契約。
///
/// 角度は後から足した項目なので、**既存の下書きが読めなくなる**のが最大の事故になる
/// （デコードに失敗すると下書きが丸ごと開けない）。そこを含めてここで固定する。
final class ObjectMaskAngleTests: XCTestCase {
    private let clipID = UUID()
    private let sourceID = UUID()

    private func box(_ x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0.2, width: 0.2, height: 0.2)
    }

    private func mask(_ keyframes: [ObjectMask.Keyframe]) -> ObjectMask {
        guard let mask = ObjectMask(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                    keyframes: keyframes) else {
            fatalError("テストの前提が壊れている（キーフレームが空）")
        }
        return mask
    }

    // MARK: - 角度の畳み込み

    /// **何周でも回せるジェスチャを畳んで持つ。** 貯めると、キーフレーム間の補間が
    /// 何周も回って「指を離した瞬間に矩形が高速回転する」。
    func test_normalizedAngle_wrapsIntoPlusMinusPi() {
        XCTAssertEqual(ObjectMask.normalizedAngle(.pi * 3), .pi, accuracy: 1e-9)
        XCTAssertEqual(ObjectMask.normalizedAngle(.pi * 2 + 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ObjectMask.normalizedAngle(-.pi * 2 - 0.5), -0.5, accuracy: 1e-9)
        XCTAssertEqual(ObjectMask.normalizedAngle(.pi * 100), 0, accuracy: 1e-9)
    }

    func test_normalizedAngle_mapsNonFiniteToZero() {
        XCTAssertEqual(ObjectMask.normalizedAngle(.nan), 0)
        XCTAssertEqual(ObjectMask.normalizedAngle(.infinity), 0)
        XCTAssertEqual(ObjectMask.normalizedAngle(-.infinity), 0)
    }

    /// 入口（`Keyframe.init`）でも畳まれること。
    func test_keyframeInit_normalizesAngle() {
        let keyframe = ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: .pi * 2 + 0.3)
        XCTAssertEqual(keyframe.angle, 0.3, accuracy: 1e-9)
    }

    // MARK: - 補間

    /// 傾きも位置と同じように補間される。
    func test_angle_interpolatesBetweenKeyframes() {
        let target = mask([
            ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: 0),
            ObjectMask.Keyframe(sourceTime: 2, rect: box(0.5), angle: 1.0)
        ])
        XCTAssertEqual(target.angle(atSourceTime: 1), 0.5, accuracy: 1e-9)
    }

    /// **最短の回り方を通る。** -179° と +179° を素朴に線形補間すると、
    /// 2° ぶん回ればいいところを 358° 逆回りして、矩形が一瞬ぐるりと回る。
    func test_angle_takesTheShortestWayAroundPi() {
        let target = mask([
            ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: .pi - 0.1),
            ObjectMask.Keyframe(sourceTime: 2, rect: box(0.5), angle: -.pi + 0.1)
        ])
        // 中点は ±π のあたり（0 付近ではない）。
        let middle = abs(target.angle(atSourceTime: 1))
        XCTAssertEqual(middle, .pi, accuracy: 1e-9,
                       "逆回りしている（2° ぶんの補間が 358° ぶん回っている）")
    }

    /// **端の扱いが位置と一致していること。** 別々に分岐を書くと、最後のキーフレームより
    /// 後ろで「位置は最後のまま・角度だけ最初に戻る」という捻れた描画になる。
    func test_angle_clampsAtBothEnds_likeRect() {
        let target = mask([
            ObjectMask.Keyframe(sourceTime: 1, rect: box(0.1), angle: 0.3),
            ObjectMask.Keyframe(sourceTime: 3, rect: box(0.5), angle: 0.9)
        ])
        for time in [-10.0, 0.0, 1.0, .nan, -.infinity] {
            XCTAssertEqual(target.angle(atSourceTime: time), 0.3, accuracy: 1e-9,
                           "t=\(time) で先頭へ倒れていない")
            XCTAssertEqual(target.rect(atSourceTime: time).origin.x, 0.1, accuracy: 1e-9)
        }
        for time in [3.0, 99.0, .infinity] {
            XCTAssertEqual(target.angle(atSourceTime: time), 0.9, accuracy: 1e-9,
                           "t=\(time) で末尾へ倒れていない")
            XCTAssertEqual(target.rect(atSourceTime: time).origin.x, 0.5, accuracy: 1e-9)
        }
    }

    // MARK: - キーフレーム編集

    func test_settingKeyframe_storesAngle() {
        let target = mask([ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: 0)])
        let edited = target.settingKeyframe(atSourceTime: 1, rect: box(0.5), angle: 0.7)
        XCTAssertEqual(edited.angle(atSourceTime: 1), 0.7, accuracy: 1e-9)
    }

    /// 同じ時刻への置換で角度も差し替わること（位置だけ残らない）。
    func test_settingKeyframe_replacesAngleAtTheSameTime() {
        let target = mask([ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: 0.5)])
        let edited = target.settingKeyframe(atSourceTime: 0, rect: box(0.2), angle: -0.5)
        XCTAssertEqual(edited.keyframes.count, 1, "キーフレームが増えている")
        XCTAssertEqual(edited.angle(atSourceTime: 0), -0.5, accuracy: 1e-9)
    }

    // MARK: - 下書きの互換

    /// **角度を持たない既存の下書きが読めること。**
    /// ここが壊れると、以前の下書きがデコードごと失敗して丸ごと開けなくなる。
    func test_decodesLegacyKeyframeWithoutAngle() throws {
        let json = """
        {"id":"\(UUID().uuidString)","sourceTime":1.5,\
        "rect":[[0.1,0.2],[0.3,0.4]]}
        """
        let decoded = try JSONDecoder().decode(ObjectMask.Keyframe.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.angle, 0, "角度の無い下書きが無回転として読めていない")
        XCTAssertEqual(decoded.sourceTime, 1.5)
        XCTAssertEqual(decoded.rect.origin.x, 0.1, accuracy: 1e-9)
    }

    func test_keyframe_roundTripsThroughCoding() throws {
        let original = ObjectMask.Keyframe(sourceTime: 2, rect: box(0.3), angle: -1.2)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObjectMask.Keyframe.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - 描画パス

    /// **回すのはピクセル空間。** 正規化のまま回すと、画像の縦横比のぶんだけ
    /// 潰れて平行四辺形になる。正方形の領域を 90° 回したら、縦横が入れ替わった
    /// 同じ大きさの外接矩形になるはず。
    func test_rectPath_rotatesInPixelSpace() {
        let size = CGSize(width: 1600, height: 900) // 16:9（正規化のまま回すと歪む）
        let normalized = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let upright = FaceMaskBuilder.rectPath(from: normalized, in: size).boundingBox
        let turned = FaceMaskBuilder.rectPath(from: normalized, angle: .pi / 2,
                                              in: size).boundingBox

        XCTAssertEqual(turned.width, upright.height, accuracy: 1e-6,
                       "90° 回して幅が元の高さになっていない（正規化空間で回している）")
        XCTAssertEqual(turned.height, upright.width, accuracy: 1e-6)
        XCTAssertEqual(turned.midX, upright.midX, accuracy: 1e-6, "中心がずれている")
        XCTAssertEqual(turned.midY, upright.midY, accuracy: 1e-6, "中心がずれている")
    }

    func test_rectPath_withZeroAngle_isTheSameAsBefore() {
        let size = CGSize(width: 640, height: 480)
        let normalized = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(FaceMaskBuilder.rectPath(from: normalized, angle: 0, in: size).boundingBox,
                       FaceMaskBuilder.rectPath(from: normalized, in: size).boundingBox)
    }

    /// 非有限の角度で path が壊れないこと（無回転へ倒す）。
    func test_rectPath_withNonFiniteAngle_fallsBackToUpright() {
        let size = CGSize(width: 640, height: 480)
        let normalized = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let path = FaceMaskBuilder.rectPath(from: normalized, angle: .nan, in: size)
        XCTAssertEqual(path.boundingBox,
                       FaceMaskBuilder.rectPath(from: normalized, in: size).boundingBox)
    }

    // MARK: - 解決（追跡との関係）

    /// **追跡は角度を追わない。** 平行移動しか見ていないので、追跡で位置が動いても
    /// 角度は置いたときのまま。ここが崩れると、追跡が効いた瞬間に傾きが消える。
    func test_placements_keepAngleEvenWhenTrackingMovesTheRect() {
        let target = mask([
            ObjectMask.Keyframe(sourceTime: 0, rect: box(0.1), angle: 0.6),
            ObjectMask.Keyframe(sourceTime: 2, rect: box(0.5), angle: 0.6)
        ])
        let placed = ObjectMaskResolver.placements([target], clipID: clipID,
                                                   sourceTime: 1, layout: .identity)
        XCTAssertEqual(placed.first?.angle ?? .nan, 0.6, accuracy: 1e-9)
    }

    /// 静止画マスクでも角度が返ること（`clipID == nil` の分岐）。
    func test_placements_returnAngleForStillMasks() {
        guard let still = ObjectMask(anchor: .still, keyframes: [
            ObjectMask.Keyframe(sourceTime: 0, rect: box(0.3), angle: -0.4)
        ]) else { return XCTFail("生成に失敗") }
        let placed = ObjectMaskResolver.placements([still], clipID: nil,
                                                   sourceTime: 0, layout: .identity)
        XCTAssertEqual(placed.first?.angle ?? .nan, -0.4, accuracy: 1e-9)
    }
}
