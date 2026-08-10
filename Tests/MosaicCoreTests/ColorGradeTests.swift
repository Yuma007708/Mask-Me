import XCTest
@testable import MosaicCore

/// `ColorGrade`（E4 色調補正のコア値型）: クランプ・identity・blend・数式・
/// プリセットの逆引きを固定する。
final class ColorGradeTests: XCTestCase {
    // MARK: - クランプ（3 経路すべて）

    /// `init` でクランプが効くこと。
    func test_init_clampsOutOfRangeValues() {
        let grade = ColorGrade(brightness: 5, contrast: -3, saturation: 9, warmth: -9)
        XCTAssertEqual(grade.brightness, 1.0, "brightness の上限クランプが効いていない")
        XCTAssertEqual(grade.contrast, 0.0, "contrast の下限クランプが効いていない")
        XCTAssertEqual(grade.saturation, 2.0, "saturation の上限クランプが効いていない")
        XCTAssertEqual(grade.warmth, -1.0, "warmth の下限クランプが効いていない")
    }

    /// 直接代入（`didSet`）でもクランプが効くこと。
    func test_directAssignment_clampsOutOfRangeValues() {
        var grade = ColorGrade.identity
        grade.brightness = -5
        grade.contrast = 8
        grade.saturation = -2
        grade.warmth = 4
        XCTAssertEqual(grade.brightness, -1.0)
        XCTAssertEqual(grade.contrast, 2.0)
        XCTAssertEqual(grade.saturation, 0.0)
        XCTAssertEqual(grade.warmth, 1.0)
    }

    /// `init(from:)`（Codable のデコード経路）でもクランプが効くこと。
    /// `didSet` は `init(from:)` を経由しないという既存の落とし穴（`TimelineClip` の doc）を
    /// 踏んでいないことの直接確認。
    func test_decoding_clampsOutOfRangeValues() throws {
        let json = """
        {"brightness": 3.0, "contrast": -1.0, "saturation": 5.0, "warmth": -3.0}
        """
        let decoded = try JSONDecoder().decode(ColorGrade.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.brightness, 1.0, "init(from:) 経由で brightness のクランプが効いていない")
        XCTAssertEqual(decoded.contrast, 0.0, "init(from:) 経由で contrast のクランプが効いていない")
        XCTAssertEqual(decoded.saturation, 2.0, "init(from:) 経由で saturation のクランプが効いていない")
        XCTAssertEqual(decoded.warmth, -1.0, "init(from:) 経由で warmth のクランプが効いていない")
    }

    /// NaN は 3 経路すべてで既定値へ倒れること。
    func test_nan_fallsBackToDefaultOnAllPaths() throws {
        let viaInit = ColorGrade(brightness: .nan, contrast: .nan, saturation: .nan, warmth: .nan)
        XCTAssertEqual(viaInit, .identity, "init 経由で NaN が既定値へ倒れない")

        var viaAssignment = ColorGrade(brightness: 0.5, contrast: 1.5, saturation: 1.5, warmth: 0.5)
        viaAssignment.brightness = .nan
        viaAssignment.contrast = .nan
        viaAssignment.saturation = .nan
        viaAssignment.warmth = .nan
        XCTAssertEqual(viaAssignment, .identity, "直接代入経由で NaN が既定値へ倒れない")

        let json = """
        {"brightness": null, "contrast": null, "saturation": null, "warmth": null}
        """
        // JSON の null は Double へデコードできないため、NaN の代わりに文字列 "nan" を試すのではなく
        // ここでは decode 経路のクランプ自体は上のテストで確認済みなので、NaN を作れる直接呼び出しで検証する。
        _ = json // 参考: JSON は非有限値を表現できないため、init(from:) の NaN 経路はここでは扱わない。
        XCTAssertEqual(ColorGrade.clampedBrightness(.nan), 0)
        XCTAssertEqual(ColorGrade.clampedContrast(.nan), 1)
        XCTAssertEqual(ColorGrade.clampedSaturation(.nan), 1)
        XCTAssertEqual(ColorGrade.clampedWarmth(.nan), 0)
    }

    // MARK: - isIdentity

    /// `isIdentity` は既定値のときだけ真であること。
    func test_isIdentity_trueOnlyForDefaults() {
        XCTAssertTrue(ColorGrade.identity.isIdentity)
        XCTAssertTrue(ColorGrade().isIdentity)
        XCTAssertFalse(ColorGrade(brightness: 0.01).isIdentity)
        XCTAssertFalse(ColorGrade(contrast: 1.01).isIdentity)
        XCTAssertFalse(ColorGrade(saturation: 0.99).isIdentity)
        XCTAssertFalse(ColorGrade(warmth: 0.01).isIdentity)
    }

    // MARK: - blend

    /// t=0 で a、t=1 で b、中点で各成分の中点になること。
    func test_blend_endpointsAndMidpoint() {
        let a = ColorGrade(brightness: -1, contrast: 0, saturation: 0, warmth: -1)
        let b = ColorGrade(brightness: 1, contrast: 2, saturation: 2, warmth: 1)

        XCTAssertEqual(ColorGrade.blend(a, b, t: 0), a, "t=0 で a と一致しない")
        XCTAssertEqual(ColorGrade.blend(a, b, t: 1), b, "t=1 で b と一致しない")

        let mid = ColorGrade.blend(a, b, t: 0.5)
        XCTAssertEqual(mid.brightness, 0, accuracy: 1e-9)
        XCTAssertEqual(mid.contrast, 1, accuracy: 1e-9)
        XCTAssertEqual(mid.saturation, 1, accuracy: 1e-9)
        XCTAssertEqual(mid.warmth, 0, accuracy: 1e-9)
    }

    /// t は 0...1 へクランプされること（範囲外・NaN を投げても暴れない）。
    func test_blend_clampsT() {
        let a = ColorGrade(brightness: -1)
        let b = ColorGrade(brightness: 1)
        XCTAssertEqual(ColorGrade.blend(a, b, t: -5), a)
        XCTAssertEqual(ColorGrade.blend(a, b, t: 5), b)
        XCTAssertEqual(ColorGrade.blend(a, b, t: .nan), a, "NaN の t が暴れずに安全側(a)へ倒れない")
    }

    // MARK: - apply(r:g:b:) の数式

    /// identity は入力をそのまま返すこと（[0,1] の範囲内の入力で）。
    func test_apply_identityPassesThroughInput() {
        let grade = ColorGrade.identity
        let inputs = [(0.0, 0.0, 0.0), (1.0, 1.0, 1.0), (0.2, 0.6, 0.9), (0.5, 0.5, 0.5)]
        for input in inputs {
            let (r, g, b) = grade.apply(r: input.0, g: input.1, b: input.2)
            XCTAssertEqual(r, input.0, accuracy: 1e-9)
            XCTAssertEqual(g, input.1, accuracy: 1e-9)
            XCTAssertEqual(b, input.2, accuracy: 1e-9)
        }
    }

    /// contrast=0 なら全画素が 0.5 になること（他パラメータは既定）。
    func test_apply_zeroContrastFlattensToMidGray() {
        let grade = ColorGrade(contrast: 0)
        let (r, g, b) = grade.apply(r: 0.9, g: 0.1, b: 0.4)
        XCTAssertEqual(r, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b, 0.5, accuracy: 1e-9)
    }

    /// saturation=0 なら R=G=B になり、その値が Rec.709 輝度と一致すること。
    func test_apply_zeroSaturationProducesRec709Luma() {
        let grade = ColorGrade(saturation: 0)
        let inputR = 0.8
        let inputG = 0.3
        let inputB = 0.1
        let (r, g, b) = grade.apply(r: inputR, g: inputG, b: inputB)
        let expectedLuma = 0.2126 * inputR + 0.7152 * inputG + 0.0722 * inputB
        XCTAssertEqual(r, expectedLuma, accuracy: 1e-9)
        XCTAssertEqual(g, expectedLuma, accuracy: 1e-9)
        XCTAssertEqual(b, expectedLuma, accuracy: 1e-9)
        XCTAssertEqual(r, g, accuracy: 1e-9)
        XCTAssertEqual(g, b, accuracy: 1e-9)
    }

    /// brightness=+1 は 1.0 に飽和すること。
    func test_apply_maxBrightnessSaturatesToOne() {
        let grade = ColorGrade(brightness: 1)
        let (r, g, b) = grade.apply(r: 1, g: 1, b: 1)
        XCTAssertEqual(r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(g, 1.0, accuracy: 1e-9)
        XCTAssertEqual(b, 1.0, accuracy: 1e-9)
    }

    /// warmth の符号反転で R と B が入れ替わる対称性。
    ///
    /// `saturation = 1`（既定）のときだけ成立する（彩度ステップの `mix(luma, c, 1) == c` で
    /// Rec.709 の非対称な輝度係数が結果に影響しなくなるため。`saturation < 1` では
    /// r/b 入れ替えでも luma が変わってしまい対称性が崩れる）。
    func test_apply_warmthSignFlipSwapsRedAndBlue() {
        let symmetricValue = 0.4 // R=B の入力にして「符号反転で R/B が入れ替わる」ことだけを見る
        let green = 0.7
        let positive = ColorGrade(warmth: 0.6)
        let negative = ColorGrade(warmth: -0.6)

        let (rPos, gPos, bPos) = positive.apply(r: symmetricValue, g: green, b: symmetricValue)
        let (rNeg, gNeg, bNeg) = negative.apply(r: symmetricValue, g: green, b: symmetricValue)

        XCTAssertEqual(rPos, bNeg, accuracy: 1e-9, "+warmth の R が -warmth の B と一致しない")
        XCTAssertEqual(bPos, rNeg, accuracy: 1e-9, "+warmth の B が -warmth の R と一致しない")
        XCTAssertEqual(gPos, gNeg, accuracy: 1e-9, "warmth は G に影響しないはず")
        XCTAssertEqual(gPos, green, accuracy: 1e-9, "既定の他パラメータでは G が変化しないはず")
    }

    /// 適用順序が仕様であること: `warmth` をコントラスト・彩度より**後**（クランプ直前）に
    /// 掛けると `apply(r:g:b:)` の結果と異なること。
    ///
    /// **コントラストと彩度の入れ替えでは差が出ない。** 両者はどちらも「各チャンネルへ
    /// 同一の係数を掛け、0.5 を通る同じ pivot（コントラストは直接、彩度は重み和 1 の
    /// `luma` 経由）で作用する affine 変換」なので代数的に可換（実測で確認済み: 上記の
    /// `brightness/contrast/saturation/warmth` の組み合わせで両順序の出力が bit 一致した）。
    /// 順序が効くのは、`warmth` が r/b だけを非対称に動かす（チャンネル間で同一でない）
    /// ためで、それを検証できる組み替えでここを固定する。
    func test_apply_orderMatters_warmthBeforeContrastDiffersFromWarmthAfter() {
        let grade = ColorGrade(brightness: 0.1, contrast: 1.6, saturation: 0.4, warmth: 0.2)
        let input = (0.85, 0.2, 0.55) // 各成分がばらけた入力（順序差が出やすい）

        let actual = grade.apply(r: input.0, g: input.1, b: input.2)

        // warmth をクランプ直前（明るさ・コントラスト・彩度の**後**）へ動かした手計算。
        var r = input.0
        var g = input.1
        var b = input.2
        r += grade.brightness * 0.5; g += grade.brightness * 0.5; b += grade.brightness * 0.5
        r = (r - 0.5) * grade.contrast + 0.5
        g = (g - 0.5) * grade.contrast + 0.5
        b = (b - 0.5) * grade.contrast + 0.5
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r = luma + (r - luma) * grade.saturation
        g = luma + (g - luma) * grade.saturation
        b = luma + (b - luma) * grade.saturation
        r *= (1 + ColorGrade.warmthStrength * grade.warmth)
        b *= (1 - ColorGrade.warmthStrength * grade.warmth)
        let warmthLastOrder = (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))

        XCTAssertNotEqual(actual.0, warmthLastOrder.0, accuracy: 1e-9,
                          "適用順序が固定されておらず、warmth を最後に回した結果と一致してしまっている")
        XCTAssertNotEqual(actual.2, warmthLastOrder.2, accuracy: 1e-9,
                          "適用順序が固定されておらず、warmth を最後に回した結果と一致してしまっている（B）")
    }

    // MARK: - プリセット

    /// `.none` は `.identity` と一致すること。
    func test_preset_noneIsIdentity() {
        XCTAssertEqual(ColorGradePreset.none.grade, .identity)
    }

    /// プリセットの数値と厳密一致する `ColorGrade` は逆引きできること。
    func test_presetMatching_findsExactMatch() {
        for preset in ColorGradePreset.allCases {
            XCTAssertEqual(ColorGradePreset.matching(preset.grade), preset,
                           "\(preset) の数値から逆引きできない")
        }
    }

    /// どのプリセットにも一致しない数値は nil（＝カスタム）を返すこと。
    func test_presetMatching_returnsNilForCustomValues() {
        let custom = ColorGrade(brightness: 0.123, contrast: 1.234, saturation: 0.5, warmth: -0.5)
        XCTAssertNil(ColorGradePreset.matching(custom))
    }
}
