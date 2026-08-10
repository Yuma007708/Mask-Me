import CoreGraphics
import Foundation
import XCTest
@testable import MosaicCore

/// 出力の画面比率（9:16 / 1:1 / 16:9 / 素材に合わせる）を固定する。
///
/// **この機能で壊れると事故になるのは「出力枠を変えたときにモザイクが素材からずれる」
/// ことである**（プライバシーアプリなので、ずれた瞬間に顔が素通しになる）。
/// 出力サイズだけでなく、レターボックス配置と顔座標の写像が**同じ配置矩形から**
/// 導かれていることをここで固定する。
final class TimelineAspectRatioTests: XCTestCase {
    private let clipID = UUID()

    // MARK: - 比率ごとの出力サイズ

    /// 既定（`.source`）は入力をそのまま返す。
    ///
    /// **ビット同一で返すことが契約**（`TimelineCompositionBuilder` は
    /// 「結果が自然な値と等しい ＝ 出力枠を強制しない」で分岐しており、ここが
    /// 1px でも動くと無変換タイムラインが常に再合成経路へ落ちる）。
    func test_sourceReturnsInputUnchanged() {
        let sizes = [CGSize(width: 1920, height: 1080),
                     CGSize(width: 1080, height: 1920),
                     CGSize(width: 640, height: 480),
                     CGSize(width: 0, height: 0)]
        for size in sizes {
            XCTAssertEqual(TimelineAspectRatio.source.renderSize(fittingSourceSize: size), size)
        }
    }

    /// 短辺を素材に合わせ、長辺を比率から導く（`TimelineAspectRatio` の doc の実測値）。
    func test_renderSizePerRatio() {
        let landscape = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(TimelineAspectRatio.portrait9x16.renderSize(fittingSourceSize: landscape),
                       CGSize(width: 1080, height: 1920))
        XCTAssertEqual(TimelineAspectRatio.square1x1.renderSize(fittingSourceSize: landscape),
                       CGSize(width: 1080, height: 1080))
        XCTAssertEqual(TimelineAspectRatio.landscape16x9.renderSize(fittingSourceSize: landscape),
                       CGSize(width: 1920, height: 1080))

        let portrait = CGSize(width: 1080, height: 1920)
        XCTAssertEqual(TimelineAspectRatio.portrait9x16.renderSize(fittingSourceSize: portrait),
                       CGSize(width: 1080, height: 1920))
        XCTAssertEqual(TimelineAspectRatio.square1x1.renderSize(fittingSourceSize: portrait),
                       CGSize(width: 1080, height: 1080))
        XCTAssertEqual(TimelineAspectRatio.landscape16x9.renderSize(fittingSourceSize: portrait),
                       CGSize(width: 1920, height: 1080))
    }

    /// 素材がちょうどその比率なら、枠は自然な値と**完全に一致**する
    /// （＝ builder が override を渡さず、従来の無変換経路が保たれる条件）。
    func test_matchingRatioReproducesSourceSize() {
        XCTAssertEqual(
            TimelineAspectRatio.landscape16x9.renderSize(fittingSourceSize: CGSize(width: 1920, height: 1080)),
            CGSize(width: 1920, height: 1080))
        XCTAssertEqual(
            TimelineAspectRatio.portrait9x16.renderSize(fittingSourceSize: CGSize(width: 720, height: 1280)),
            CGSize(width: 720, height: 1280))
        XCTAssertEqual(
            TimelineAspectRatio.square1x1.renderSize(fittingSourceSize: CGSize(width: 480, height: 480)),
            CGSize(width: 480, height: 480))
    }

    /// 出力サイズは常に偶数（HEVC/H.264 の都合。`VideoCompositionFactory.renderSize` と同じ規則）。
    func test_renderSizeIsAlwaysEven() {
        let sources = [CGSize(width: 641, height: 481), CGSize(width: 1234, height: 567),
                       CGSize(width: 100, height: 999), CGSize(width: 3840, height: 2160)]
        for ratio in TimelineAspectRatio.allCases where ratio != .source {
            for size in sources {
                let result = ratio.renderSize(fittingSourceSize: size)
                XCTAssertEqual(result.width.truncatingRemainder(dividingBy: 2), 0,
                               "幅が奇数 (\(ratio), \(size) → \(result))")
                XCTAssertEqual(result.height.truncatingRemainder(dividingBy: 2), 0,
                               "高さが奇数 (\(ratio), \(size) → \(result))")
                XCTAssertGreaterThanOrEqual(result.width, 2)
                XCTAssertGreaterThanOrEqual(result.height, 2)
            }
        }
    }

    /// 非有限・非正のサイズは判断材料が無いので入力をそのまま返す（`AspectFit` と同じ倒し方）。
    func test_invalidSourceSizeFallsBackToInput() {
        let invalid = [CGSize(width: 0, height: 1080), CGSize(width: 1920, height: 0),
                       CGSize(width: CGFloat.nan, height: 1080),
                       CGSize(width: 1920, height: CGFloat.infinity),
                       CGSize(width: -1920, height: -1080)]
        for ratio in TimelineAspectRatio.allCases {
            for size in invalid {
                let result = ratio.renderSize(fittingSourceSize: size)
                XCTAssertEqual(result.width.isNaN, size.width.isNaN)
                XCTAssertEqual(result.height.isNaN, size.height.isNaN)
                if !size.width.isNaN { XCTAssertEqual(result.width, size.width) }
                if !size.height.isNaN { XCTAssertEqual(result.height, size.height) }
            }
        }
    }

    // MARK: - レターボックス配置（素材を切り取らない）

    /// 比率を変えても素材は**切り取られず**、アスペクト比を保ったまま枠に収まる。
    /// 配置は `AspectFit.placement` が決める（比率側で再実装しない）。
    func test_placementLetterboxesWithoutCropping() {
        let source = CGSize(width: 1920, height: 1080)

        // 16:9 素材 → 9:16 枠: 上下に黒帯（レターボックス）。幅は全面。
        let portraitFrame = TimelineAspectRatio.portrait9x16.renderSize(fittingSourceSize: source)
        let inPortrait = AspectFit.placement(of: source, in: portraitFrame)
        XCTAssertEqual(inPortrait.width, 1.0, accuracy: 1e-12)
        XCTAssertEqual(inPortrait.height * portraitFrame.height, 1080 * (1080.0 / 1920.0), accuracy: 1e-9)
        XCTAssertEqual(inPortrait.minX, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(inPortrait.minY, 0, "上下に黒帯が入るはず")

        // 16:9 素材 → 1:1 枠: 同じく上下に黒帯。幅は全面。
        let squareFrame = TimelineAspectRatio.square1x1.renderSize(fittingSourceSize: source)
        let inSquare = AspectFit.placement(of: source, in: squareFrame)
        XCTAssertEqual(inSquare.width, 1.0, accuracy: 1e-12)
        XCTAssertEqual(inSquare.height, 1080.0 / 1920.0, accuracy: 1e-12)
        XCTAssertEqual(inSquare.minY, (1 - inSquare.height) / 2, accuracy: 1e-12)

        // 9:16 素材 → 16:9 枠: 左右に黒帯（ピラーボックス）。高さは全面。
        let tall = CGSize(width: 1080, height: 1920)
        let wideFrame = TimelineAspectRatio.landscape16x9.renderSize(fittingSourceSize: tall)
        let inWide = AspectFit.placement(of: tall, in: wideFrame)
        XCTAssertEqual(inWide.height, 1.0, accuracy: 1e-12)
        XCTAssertEqual(inWide.width, (1080.0 / 1920.0) / (1920.0 / 1080.0), accuracy: 1e-12)
        XCTAssertGreaterThan(inWide.minX, 0, "左右に黒帯が入るはず")
    }

    /// 配置は必ず枠の内側に収まり（はみ出し = 切り取り が起きない）、中央に置かれる。
    func test_placementStaysInsideFrameAndIsCentered() {
        let sources = [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920),
                       CGSize(width: 640, height: 480), CGSize(width: 1000, height: 1000)]
        for ratio in TimelineAspectRatio.allCases where ratio != .source {
            for source in sources {
                let frame = ratio.renderSize(fittingSourceSize: source)
                let place = AspectFit.placement(of: source, in: frame)
                XCTAssertGreaterThanOrEqual(place.minX, -1e-12)
                XCTAssertGreaterThanOrEqual(place.minY, -1e-12)
                XCTAssertLessThanOrEqual(place.maxX, 1 + 1e-12)
                XCTAssertLessThanOrEqual(place.maxY, 1 + 1e-12)
                XCTAssertEqual(place.minX, 1 - place.maxX, accuracy: 1e-12, "水平中央でない")
                XCTAssertEqual(place.minY, 1 - place.maxY, accuracy: 1e-12, "垂直中央でない")
                // 素材のアスペクト比が保たれている（引き伸ばさない）。
                let drawn = CGSize(width: place.width * frame.width, height: place.height * frame.height)
                XCTAssertEqual(drawn.width / drawn.height, source.width / source.height, accuracy: 1e-9)
            }
        }
    }

    // MARK: - モザイク座標の一致（いちばん重要）

    /// **素材の中の同じ場所には、枠を変えても同じ絵と同じモザイクが乗る。**
    ///
    /// 顔ランドマークは素材フレーム基準の正規化座標なので、枠を変えたときに
    /// `TimelineRenderLayout.remap`（＝ `AspectFit.placement`）を通さないと枠基準のまま
    /// 取り残されてずれる。ここでは
    ///
    /// 1. 素材上の点 u を `remap` した合成座標を出力ピクセルへ直す
    /// 2. 同じ点 u が映像として描かれる出力ピクセル（配置矩形の中の相対位置）を直接計算する
    ///
    /// の 2 つが一致することを固定する。2 は映像側の変換
    /// （`VideoCompositionFactory.fitTransform` = `scale = placement.width * renderSize.width /
    /// display.width`、平行移動 = `placement.origin * renderSize`）と同じ式で、
    /// **モザイクと絵が同じ配置矩形から導かれている**ことの検証になる。
    func test_landmarkFollowsMaterialUnderEveryAspectRatio() {
        let source = CGSize(width: 1920, height: 1080)
        // 素材の正規化座標（顔があると思ってよい位置）。
        let probes: [CGPoint] = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.1, y: 0.2),
                                 CGPoint(x: 0.87, y: 0.93), CGPoint(x: 0, y: 0),
                                 CGPoint(x: 1, y: 1)]
        for ratio in TimelineAspectRatio.allCases {
            let frame = ratio == .source
                ? source
                : ratio.renderSize(fittingSourceSize: source)
            let place = AspectFit.placement(of: source, in: frame)
            let layout = TimelineRenderLayout(placements: [clipID: place])
            // 映像側の変換（fitTransform と同じ式）。
            let scale = place.width * frame.width / source.width
            for probe in probes {
                let set = FaceLandmarkSet(points: [FaceLandmark(x: Float(probe.x), y: Float(probe.y))],
                                          confidence: 1)
                guard let mapped = layout.remap([set], clipID: clipID).first?.points.first else {
                    return XCTFail("写像後のランドマークが取れない")
                }
                // 1. モザイクが乗る出力ピクセル。
                let mosaicX = CGFloat(mapped.x) * frame.width
                let mosaicY = CGFloat(mapped.y) * frame.height
                // 2. 絵が描かれる出力ピクセル（素材ピクセル × scale + 平行移動）。
                let drawnX = probe.x * source.width * scale + place.minX * frame.width
                let drawnY = probe.y * source.height * scale + place.minY * frame.height
                // 許容は 0.01px。`FaceLandmark` の座標は Float なので、写像の一致は
                // Float の丸め（1920px で 1e-4px 程度）までしか主張できない。
                // ずれの事故は px 単位なので、この桁で十分に検出できる。
                XCTAssertEqual(mosaicX, drawnX, accuracy: 0.01,
                               "\(ratio) で素材 \(probe) のモザイクが絵と横にずれている")
                XCTAssertEqual(mosaicY, drawnY, accuracy: 0.01,
                               "\(ratio) で素材 \(probe) のモザイクが絵と縦にずれている")
            }
        }
    }

    /// 枠を変えても、素材座標で保存されている矩形マスクは往復で戻る
    /// （比率を戻したときに元の位置へ戻ることの担保）。
    func test_rectRoundTripHoldsUnderEveryAspectRatio() {
        let source = CGSize(width: 1080, height: 1920)
        let rects = [CGRect(x: 0, y: 0, width: 1, height: 1),
                     CGRect(x: 0.2, y: 0.3, width: 0.25, height: 0.4),
                     CGRect(x: 0.7, y: 0.05, width: 0.3, height: 0.9)]
        for ratio in TimelineAspectRatio.allCases {
            let frame = ratio == .source ? source : ratio.renderSize(fittingSourceSize: source)
            let layout = TimelineRenderLayout(
                placements: [clipID: AspectFit.placement(of: source, in: frame)])
            for rect in rects {
                let composed = layout.remap(rect, clipID: clipID)
                guard let back = layout.inverseRemap(composed, clipID: clipID) else {
                    return XCTFail("\(ratio) で逆写像が nil になった")
                }
                XCTAssertEqual(back.minX, rect.minX, accuracy: 1e-9, "\(ratio)")
                XCTAssertEqual(back.minY, rect.minY, accuracy: 1e-9, "\(ratio)")
                XCTAssertEqual(back.width, rect.width, accuracy: 1e-9, "\(ratio)")
                XCTAssertEqual(back.height, rect.height, accuracy: 1e-9, "\(ratio)")
            }
        }
    }

    /// **枠だけ変えて写像を通さなかった場合は実際にずれる**（このテストが守っている
    /// 対象が本当に効いていることの確認。恒等写像で通ってしまうテストにしない）。
    func test_ignoringLayoutActuallyMisplacesMosaic() {
        let source = CGSize(width: 1920, height: 1080)
        let frame = TimelineAspectRatio.square1x1.renderSize(fittingSourceSize: source)  // 1080x1080
        let place = AspectFit.placement(of: source, in: frame)
        let layout = TimelineRenderLayout(placements: [clipID: place])
        let set = FaceLandmarkSet(points: [FaceLandmark(x: 0.5, y: 0.1)], confidence: 1)
        guard let mapped = layout.remap([set], clipID: clipID).first?.points.first else {
            return XCTFail("写像後のランドマークが取れない")
        }
        // 写像なし（0.1 * 1080 = 108px）と写像あり（黒帯 236.25px + 0.1 * 607.5px = 297px）は
        // 189px ずれる。顔 1 個ぶんより大きいので、素通しになるのはこの差である。
        let naive = 0.1 * frame.height
        let correct = CGFloat(mapped.y) * frame.height
        XCTAssertEqual(correct, place.minY * frame.height + 0.1 * place.height * frame.height,
                       accuracy: 0.01)
        XCTAssertEqual(abs(correct - naive), 189, accuracy: 0.01)
    }

    // MARK: - 状態と永続化

    /// 既定は「素材に合わせる」。
    func test_defaultIsSource() {
        XCTAssertEqual(TimelineState().aspectRatio, .source)
    }

    /// 設定は状態に載り、同じ値なら self を返す（他の編集操作と同じ契約）。
    func test_settingAspectRatio() {
        let state = TimelineState()
        let changed = state.settingAspectRatio(.square1x1)
        XCTAssertEqual(changed.aspectRatio, .square1x1)
        XCTAssertNotEqual(changed, state)
        XCTAssertEqual(changed.settingAspectRatio(.square1x1), changed)
    }

    /// 保存 → 復元で比率が保たれる。
    func test_codableRoundTrip() throws {
        for ratio in TimelineAspectRatio.allCases {
            let state = TimelineState().settingAspectRatio(ratio)
            let data = try JSONEncoder().encode(state)
            let restored = try JSONDecoder().decode(TimelineState.self, from: data)
            XCTAssertEqual(restored.aspectRatio, ratio)
        }
    }

    /// **旧下書き（`aspectRatio` キーが無い JSON）は「素材に合わせる」で復元される。**
    /// schemaVersion は v4 のまま（v5 で足したのはキーだけなので移行処理は無い）。
    func test_legacyDraftWithoutAspectRatioRestoresAsSource() throws {
        // 現行のエンコード結果から `aspectRatio` を抜き、schemaVersion を v4 へ戻して
        // 「v5 より前に保存された下書き」を作る（JSON を手書きすると `transitions` /
        // `sources` の UUID キー辞書が配列でエンコードされる仕様を取り違える）。
        let legacy = try legacyJSON(removingAspectRatio: true, schemaVersion: 4)
        let state = try JSONDecoder().decode(TimelineState.self, from: legacy)
        XCTAssertEqual(state.aspectRatio, .source)
    }

    /// 未知の比率文字列（手書き・将来版の下書き）でも下書きごと開けなくならず、
    /// 「素材に合わせる」に倒れる。
    func test_unknownAspectRatioStringFallsBackToSource() throws {
        let json = try legacyJSON(removingAspectRatio: false, schemaVersion: 5,
                                  aspectRatioString: "21x9")
        let state = try JSONDecoder().decode(TimelineState.self, from: json)
        XCTAssertEqual(state.aspectRatio, .source)
    }

    /// 現行のエンコード結果を土台に、旧下書き相当の JSON を組む。
    private func legacyJSON(removingAspectRatio: Bool,
                            schemaVersion: Int,
                            aspectRatioString: String? = nil) throws -> Data {
        let data = try JSONEncoder().encode(TimelineState())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if removingAspectRatio {
            object.removeValue(forKey: "aspectRatio")
        } else if let aspectRatioString {
            object["aspectRatio"] = aspectRatioString
        }
        object["schemaVersion"] = schemaVersion
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// 保存した JSON に比率と現行スキーマ版が入っていること
    /// （書き忘れると次回起動で常に `.source` へ戻る）。
    func test_encodedJSONCarriesAspectRatioAndSchemaVersion() throws {
        let data = try JSONEncoder().encode(TimelineState().settingAspectRatio(.portrait9x16))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["aspectRatio"] as? String, "9x16")
        XCTAssertEqual(object["schemaVersion"] as? Int, TimelineState.currentSchemaVersion)
        XCTAssertEqual(TimelineState.currentSchemaVersion, 7)
    }
}
