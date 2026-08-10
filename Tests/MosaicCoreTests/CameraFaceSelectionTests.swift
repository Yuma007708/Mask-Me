import XCTest
import CoreGraphics
@testable import MosaicCore

/// リアルタイム撮影のオプトアウト選択（タップで OFF にした顔だけ除外）の検証。
/// 焼き込み撮影は失敗が不可逆のため、迷ったら「モザイク ON」に倒れることを確認する。
final class CameraFaceSelectionTests: XCTestCase {
    private func face(cx: Float, cy: Float, size: Float = 0.2) -> FaceLandmarkSet {
        let h = size / 2
        return FaceLandmarkSet(points: [
            FaceLandmark(x: cx - h, y: cy - h), FaceLandmark(x: cx + h, y: cy - h),
            FaceLandmark(x: cx - h, y: cy + h), FaceLandmark(x: cx + h, y: cy + h)
        ], confidence: 1)
    }

    /// 指定した軸だけが立った単位ベクトル。軸が違えば類似度 0（＝`distinct` 以下＝別人）、
    /// 同じ軸なら 1（＝`match` 以上＝同一人物）になる。
    private func signature(axis: Int) -> FaceSignature {
        var values = [Float](repeating: 0, count: FaceSignature.dimension)
        values[axis] = 1
        return FaceSignature(rawValues: values)!
    }

    /// 既定（オプトアウトなし）は全ての顔にモザイクが掛かる。
    func testDefaultMasksAllFaces() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.3, cy: 0.4), face(cx: 0.7, cy: 0.4)]
        XCTAssertEqual(sel.facesToMask(from: faces).count, 2)
    }

    /// タップで OFF にした顔だけが除外され、もう一度タップすると ON に戻る。
    func testToggleExcludesAndRestoresFace() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.3, cy: 0.4), face(cx: 0.7, cy: 0.4)]

        XCTAssertEqual(sel.toggle(at: CGPoint(x: 0.3, y: 0.4), in: faces), false)
        let masked = sel.facesToMask(from: faces)
        XCTAssertEqual(masked.count, 1)
        XCTAssertEqual(masked.first.map { SelectedFaceTracker.centroid(of: $0).x } ?? -1,
                       0.7, accuracy: 0.001)

        XCTAssertEqual(sel.toggle(at: CGPoint(x: 0.3, y: 0.4), in: faces), true)
        XCTAssertEqual(sel.facesToMask(from: faces).count, 2)
    }

    /// 顔の無い場所のタップは何も変えない。
    func testToggleOnEmptyAreaDoesNothing() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.3, cy: 0.4)]
        XCTAssertNil(sel.toggle(at: CGPoint(x: 0.9, y: 0.9), in: faces))
        XCTAssertEqual(sel.facesToMask(from: faces).count, 1)
    }

    /// OFF にした顔が移動しても追従して除外されつづける。
    func testUnmaskedTrackFollowsMovingFace() {
        var sel = CameraFaceSelection()
        var x: Float = 0.2
        sel.toggle(at: CGPoint(x: 0.2, y: 0.5), in: [face(cx: x, cy: 0.5)])
        while x < 0.8 {
            x += 0.1
            let masked = sel.facesToMask(from: [face(cx: x, cy: 0.5), face(cx: 0.1, cy: 0.1)])
            XCTAssertEqual(masked.count, 1, "x=\(x) で OFF 顔の追従が切れた")
            XCTAssertEqual(masked.first.map { SelectedFaceTracker.centroid(of: $0).y } ?? -1,
                           0.1, accuracy: 0.001)
        }
    }

    /// フレームアウトが続いた OFF 顔はトラック破棄され、再イン時は安全側で ON に戻る。
    func testLostUnmaskedFaceRevertsToMaskedOnReentry() {
        var sel = CameraFaceSelection()
        sel.toggle(at: CGPoint(x: 0.2, y: 0.5), in: [face(cx: 0.2, cy: 0.5)])

        // OFF 顔が消えて別の顔だけが映りつづける（ロストが数えられる状況）
        for _ in 0...CameraFaceSelection.lostFrameTolerance {
            _ = sel.facesToMask(from: [face(cx: 0.9, cy: 0.9)])
        }
        XCTAssertEqual(sel.unmaskedCount, 0, "ロスト超過で OFF トラックが破棄されるはず")
        XCTAssertEqual(sel.facesToMask(from: [face(cx: 0.2, cy: 0.5)]).count, 1)
    }

    /// 検出が全滅したフレームはロストに数えない（フロー上限切れ等で検出が
    /// 止まっているだけの可能性があるため、OFF 状態を維持する）。
    func testEmptyDetectionFramesDoNotCountAsLost() {
        var sel = CameraFaceSelection()
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [face(cx: 0.5, cy: 0.5)])

        for _ in 0..<(CameraFaceSelection.lostFrameTolerance * 3) {
            XCTAssertTrue(sel.facesToMask(from: []).isEmpty)
        }
        XCTAssertEqual(sel.unmaskedCount, 1)
        XCTAssertTrue(sel.facesToMask(from: [face(cx: 0.5, cy: 0.5)]).isEmpty,
                      "検出復帰後も OFF が維持されるはず")
    }

    /// 離れた位置に現れた別人が OFF を引き継がない（matchDistance 外）。
    func testDistantNewcomerDoesNotInheritOptOut() {
        var sel = CameraFaceSelection()
        sel.toggle(at: CGPoint(x: 0.2, y: 0.2), in: [face(cx: 0.2, cy: 0.2)])
        let newcomer = face(cx: 0.8, cy: 0.8)
        XCTAssertEqual(sel.facesToMask(from: [newcomer]).count, 1,
                       "OFF 顔から離れた新顔は既定どおりモザイク ON のはず")
    }

    /// 2 つの OFF トラックが同じ顔を二重に除外しない（1:1 割り当て）。
    func testTwoTracksDoNotExcludeSameFaceTwice() {
        var sel = CameraFaceSelection()
        let two = [face(cx: 0.4, cy: 0.5), face(cx: 0.55, cy: 0.5)]
        sel.toggle(at: CGPoint(x: 0.4, y: 0.5), in: two)
        sel.toggle(at: CGPoint(x: 0.55, y: 0.5), in: two)
        // 片方だけが映るフレーム: 除外は 1 顔ぶんだけ
        XCTAssertTrue(sel.facesToMask(from: [face(cx: 0.45, cy: 0.5)]).isEmpty)
        // 3 人目が加わっても除外は 2 顔まで
        let three = two + [face(cx: 0.7, cy: 0.5)]
        XCTAssertEqual(sel.facesToMask(from: three).count, 1)
    }

    /// reset で全員 ON に戻る。
    func testResetRestoresAllMasks() {
        var sel = CameraFaceSelection()
        let faces = [face(cx: 0.5, cy: 0.5)]
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: faces)
        sel.reset()
        XCTAssertEqual(sel.facesToMask(from: faces).count, 1)
    }

    // MARK: - 署名による乗り移り防止（S4）

    /// **OFF にした人の前を別人が横切っても、その別人は素で映らないこと。**
    /// 位置だけで見ていた頃は、重心 0.2 以内に入った時点で OFF を引き継いでいた。
    func testStrangerCrossingDoesNotInheritTheOptOut() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        // 手本を持たせる（タップ時点ではなく、最初の署名つきマッチで入る）
        XCTAssertTrue(sel.facesToMask(from: [mine], signatures: [signature(axis: 0)]).isEmpty)

        // 別人が同じ位置に立つ（重心距離 0.02 = マッチ距離のはるか内側）
        let stranger = face(cx: 0.52, cy: 0.5)
        XCTAssertEqual(sel.facesToMask(from: [stranger], signatures: [signature(axis: 1)]).count,
                       1, "OFF が別人へ乗り移り、その人が素で映っている")
    }

    /// **拒否は後続の署名なしフレームにも効き続けること。**
    /// 署名は 0.5 秒に 1 回しか測らないので、拒否したフレームだけ掛け直しても、
    /// 次の署名なしフレームで同じ別人にまた位置でマッチしてしまう。
    func testRejectionPersistsThroughFramesWithoutSignatures() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])

        let stranger = face(cx: 0.52, cy: 0.5)
        XCTAssertEqual(sel.facesToMask(from: [stranger], signatures: [signature(axis: 1)]).count, 1)
        // 以降は署名が測れないフレームが続く（実機ではこちらが大多数）
        for _ in 0..<4 {
            XCTAssertEqual(sel.facesToMask(from: [stranger]).count, 1,
                           "署名の無いフレームで別人が OFF を取り戻し、素で映っている")
        }
    }

    /// 停止したトラックは、本人の署名が来れば元に戻ること
    /// （別人が横切っただけで、掛け直しを強いられない）。
    func testSuspendedTrackResumesWhenTheOwnerIsConfirmed() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])
        _ = sel.facesToMask(from: [face(cx: 0.52, cy: 0.5)], signatures: [signature(axis: 1)])

        XCTAssertTrue(sel.facesToMask(from: [mine], signatures: [signature(axis: 0)]).isEmpty,
                      "本人だと分かっても OFF が戻らない（掛け直しを強いる）")
    }

    /// 拒否したフレームはトラックにとって「未マッチ」であり、続けばロストして
    /// 全員 ON に戻ること（別人が居座っている間ずっと OFF を抱えたままにしない）。
    func testRejectedFramesCountAsLostAndFallBackToAllOn() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])

        let stranger = face(cx: 0.5, cy: 0.5)
        for _ in 0...CameraFaceSelection.lostFrameTolerance {
            _ = sel.facesToMask(from: [stranger], signatures: [signature(axis: 1)])
        }
        XCTAssertEqual(sel.unmaskedCount, 0, "拒否が続いてもトラックが破棄されていない")
        XCTAssertEqual(sel.facesToMask(from: [mine], signatures: [signature(axis: 0)]).count, 1,
                       "ロスト後の再インは全員 ON から始まるはず")
    }

    /// 同一人物だと言える署名は、位置の判定を変えないこと（OFF は OFF のまま）。
    func testSamePersonKeepsTheOptOut() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])

        let moved = face(cx: 0.6, cy: 0.5)
        XCTAssertTrue(sel.facesToMask(from: [moved], signatures: [signature(axis: 0)]).isEmpty,
                      "同一人物なのに OFF が外れた")
    }

    /// **署名でマッチ距離を広げない。** 同一人物だと分かっていても、離れた位置の顔へは
    /// 引き継がない（広げる側の誤りは露出に直結する）。
    func testSignatureDoesNotWidenMatchDistance() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.2, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.2, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])

        let farAway = face(cx: 0.9, cy: 0.5)
        XCTAssertEqual(sel.facesToMask(from: [farAway], signatures: [signature(axis: 0)]).count, 1,
                       "署名を根拠に距離の壁を越えて OFF を引き継いでいる")
    }

    /// 署名の無いフレームは従来どおり位置だけで動くこと
    /// （ここを「決め手が無いから拒否」に倒すと、OFF がほぼ機能しなくなる）。
    func testFramesWithoutSignaturesKeepSpatialBehaviour() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])

        XCTAssertTrue(sel.facesToMask(from: [face(cx: 0.55, cy: 0.5)]).isEmpty,
                      "署名の無いフレームで OFF が外れている")
    }

    /// 件数の合わない署名は**全て無視**する（取り違えた署名で判断しない）。
    func testMismatchedSignatureCountIsIgnored() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])

        // 顔 2 件に署名 1 件。別人の署名を隣の顔へ当てはめてはいけない。
        let faces = [face(cx: 0.5, cy: 0.5), face(cx: 0.9, cy: 0.9)]
        XCTAssertEqual(sel.facesToMask(from: faces, signatures: [signature(axis: 1)]).count, 1,
                       "件数の合わない署名を使って判断している")
    }

    /// 別人の顔を手本として取り込まないこと。取り込むと、以後その別人まで OFF になる。
    func testStrangerIsNotLearnedAsAnExemplar() {
        var sel = CameraFaceSelection()
        let mine = face(cx: 0.5, cy: 0.5)
        sel.toggle(at: CGPoint(x: 0.5, y: 0.5), in: [mine])
        _ = sel.facesToMask(from: [mine], signatures: [signature(axis: 0)])

        // 判断保留の帯（類似度 0.3 ≒ distinct 0.25 と match 0.363 の間）の顔が
        // 位置でマッチする。位置の判定どおり OFF は引き継がれるが、手本にはしない。
        var mixed = [Float](repeating: 0, count: FaceSignature.dimension)
        mixed[0] = 0.3
        mixed[1] = Float((1.0 - 0.3 * 0.3).squareRoot())
        let ambiguous = FaceSignature(rawValues: mixed)!
        XCTAssertTrue(sel.facesToMask(from: [mine], signatures: [ambiguous]).isEmpty)

        // 手本になっていれば、この署名の人が以後 OFF を引き継げてしまう。
        XCTAssertEqual(sel.facesToMask(from: [mine], signatures: [signature(axis: 1)]).count, 1,
                       "判断保留の顔を手本に取り込み、別人が OFF を引き継げるようになっている")
    }
}
