import Foundation

/// クリップに掛ける色調補正（明るさ・コントラスト・彩度・暖かみ）。
///
/// 数式の正はこの型の `apply(r:g:b:)` にある。Metal 側の `colorGradeKernel`
/// （`MosaicShader.metal`）はこの写しでしかない（`TextQuadLayout` と
/// `textOverlayKernel` の役割分担と同じ: レイアウト/数式の計算は Swift、
/// カーネルは計算結果を適用するだけ）。数式を変えたら両方直すこと。
public struct ColorGrade: Hashable, Sendable, Codable {
    /// 明るさの許容範囲。
    public static let brightnessRange: ClosedRange<Double> = -1.0...1.0
    /// コントラストの許容範囲。
    public static let contrastRange: ClosedRange<Double> = 0.0...2.0
    /// 彩度の許容範囲。
    public static let saturationRange: ClosedRange<Double> = 0.0...2.0
    /// 暖かみの許容範囲。
    public static let warmthRange: ClosedRange<Double> = -1.0...1.0

    /// 無補正（既定値）。
    public static let identity = ColorGrade()

    /// 明るさ。-1...1、既定 0。
    /// init・直接代入・`init(from:)` のどの経路でも `brightnessRange` にクランプされる。
    public var brightness: Double {
        // didSet 内の再代入はオブザーバを再帰呼び出ししない（`TimelineClip.rate` と同じ手口）。
        didSet { brightness = Self.clampedBrightness(brightness) }
    }
    /// コントラスト。0...2、既定 1（無変化）。
    public var contrast: Double {
        didSet { contrast = Self.clampedContrast(contrast) }
    }
    /// 彩度。0...2、既定 1（無変化）。0 で完全なモノクロ。
    public var saturation: Double {
        didSet { saturation = Self.clampedSaturation(saturation) }
    }
    /// 暖かみ。-1...1、既定 0。正で赤み寄り、負で青み寄り。
    public var warmth: Double {
        didSet { warmth = Self.clampedWarmth(warmth) }
    }

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, warmth: Double = 0) {
        // init 中は didSet が走らないため、`TimelineClip.rate` と同様に明示的にクランプする。
        self.brightness = Self.clampedBrightness(brightness)
        self.contrast = Self.clampedContrast(contrast)
        self.saturation = Self.clampedSaturation(saturation)
        self.warmth = Self.clampedWarmth(warmth)
    }

    /// 明るさを許容範囲へクランプする。NaN は min/max を素通りして下流（`apply`・カーネル）を
    /// 汚染するため、既定値（0）へ倒す（`TimelineClip.clampedRate` と同じ流儀）。
    public static func clampedBrightness(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, brightnessRange.lowerBound), brightnessRange.upperBound)
    }

    /// コントラストを許容範囲へクランプする。NaN は既定値（1 = 無変化）へ倒す。
    public static func clampedContrast(_ value: Double) -> Double {
        value.isNaN ? 1 : min(max(value, contrastRange.lowerBound), contrastRange.upperBound)
    }

    /// 彩度を許容範囲へクランプする。NaN は既定値（1 = 無変化）へ倒す。
    public static func clampedSaturation(_ value: Double) -> Double {
        value.isNaN ? 1 : min(max(value, saturationRange.lowerBound), saturationRange.upperBound)
    }

    /// 暖かみを許容範囲へクランプする。NaN は既定値（0）へ倒す。
    public static func clampedWarmth(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, warmthRange.lowerBound), warmthRange.upperBound)
    }

    /// 4 値がすべて既定値と厳密一致するか（＝無補正）。
    public var isIdentity: Bool {
        brightness == 0 && contrast == 1 && saturation == 1 && warmth == 0
    }

    /// `a` から `b` への線形補間。`t` は 0...1 へクランプする
    /// （呼び出し側の `progress` が浮動小数点誤差で僅かに外へ出ても暴れないため）。
    public static func blend(_ a: ColorGrade, _ b: ColorGrade, t: Double) -> ColorGrade {
        let clampedT = t.isNaN ? 0 : min(max(t, 0), 1)
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * clampedT }
        return ColorGrade(brightness: lerp(a.brightness, b.brightness),
                          contrast: lerp(a.contrast, b.contrast),
                          saturation: lerp(a.saturation, b.saturation),
                          warmth: lerp(a.warmth, b.warmth))
    }

    /// `warmth` が r/b チャンネルへ効く強さの係数。1.0 だと `warmth = 1` で赤成分が
    /// 倍増しうる（色被りが極端になりすぎる）ため、UI スライダーの体感に合わせて
    /// 控えめな 0.3（最大 ±30%）にしてある。**`MosaicShader.metal` の
    /// `colorGradeKernel` にある同じ定数 `k = 0.3` と値を同期させること**
    /// （Swift 側がこの型の数式の正で、カーネル側はその写しでしかない）。
    public static let warmthStrength: Double = 0.3

    // swiftlint:disable large_tuple
    /// 色調補正を 1 画素（0...1 の RGB）へ適用する（規範実装）。
    ///
    /// **演算順序は仕様として固定する**（`warmth` を後ろへ動かすと異なる結果になる。
    /// `ColorGradeTests` で固定済み。コントラストと彩度だけの入れ替えは代数的に可換で
    /// 差が出ない — 詳細は `ColorGradeTests` の同テストの doc 参照）:
    /// 1. 暖かみ: `r *= (1 + k*warmth)`, `b *= (1 - k*warmth)`（`g` は不変）
    /// 2. 明るさ: 各成分に `brightness * 0.5` を加算
    /// 3. コントラスト: `(c - 0.5) * contrast + 0.5`
    /// 4. 彩度: `mix(luma, c, saturation)`（`luma` は Rec.709 係数 `0.2126/0.7152/0.0722`）
    /// 5. 0...1 へクランプ
    ///
    /// **これは表示参照値（ガンマ済み・sRGB エンコード後の値）上の演算であり、線形光上の
    /// 演算ではない。** 既存のモザイクのブロック平均（`blockAverage`、`MosaicShader.metal`）も
    /// 同じガンマ空間で平均を取っている。ここだけ線形化すると、モザイクと色調補正が
    /// 別々の色空間で計算されることになり、境界で色が食い違う。
    ///
    /// 入力が [0,1] の範囲外（撮影パイプラインの丸め誤差等）でも壊れないよう、
    /// 出力だけをクランプする（入力はクランプしない。中間値の符号がそのまま効くのが仕様）。
    ///
    /// 戻り値は RGB の 3 値そのもの（呼び出し側は r/g/b を素直に受け取りたいだけなので、
    /// 専用の struct を新設せず tuple のままにしてある）。
    public func apply(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        // 1) 暖かみ。
        var red = r * (1 + Self.warmthStrength * warmth)
        var green = g
        var blue = b * (1 - Self.warmthStrength * warmth)

        // 2) 明るさ。
        red += brightness * 0.5
        green += brightness * 0.5
        blue += brightness * 0.5

        // 3) コントラスト。
        red = (red - 0.5) * contrast + 0.5
        green = (green - 0.5) * contrast + 0.5
        blue = (blue - 0.5) * contrast + 0.5

        // 4) 彩度（Rec.709 輝度で mix）。
        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        red = luma + (red - luma) * saturation
        green = luma + (green - luma) * saturation
        blue = luma + (blue - luma) * saturation

        // 5) クランプ。
        return (min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1))
    }
    // swiftlint:enable large_tuple

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation, warmth
    }

    /// **`init(from:)` は didSet を経由しない**ため、4 値すべてを明示的にクランプする
    /// （`TimelineClip.init(from:)` と同じ注意。壊れた下書きから範囲外の値が入るのを防ぐ）。
    /// `colorGrade` キー自体が無い旧 JSON（v6 以前）のフォールバックは
    /// `TimelineClip.init(from:)` 側（`decodeIfPresent(...) ?? .identity`）が担う。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.brightness = Self.clampedBrightness(try container.decode(Double.self, forKey: .brightness))
        self.contrast = Self.clampedContrast(try container.decode(Double.self, forKey: .contrast))
        self.saturation = Self.clampedSaturation(try container.decode(Double.self, forKey: .saturation))
        self.warmth = Self.clampedWarmth(try container.decode(Double.self, forKey: .warmth))
    }
}

/// 数値プリセット（見た目の名前つきショートカット）。
///
/// **プリセット名はクリップに保存しない。** `TimelineClip.colorGrade` に保存されるのは
/// 4 つの数値だけである。もしプリセット名（例: `"cinema"`）を別フィールドとして
/// クリップへ保存すると、ユーザーがプリセット適用後にスライダーを 1 つでも動かした瞬間に
/// 「保存された名前」と「実際の数値」が食い違う 2 つの情報源になる（どちらを表示・
/// 書き出しに使うかの優先順位が要る、保存のたびに整合を取り直す、といった不要な複雑さを生む）。
/// `matching(_:)` は現在の数値からプリセット名を**逆引き**する（UI が「今どのプリセットに
/// 一致しているか」をハイライトする用途）だけで、保存経路には一切関与しない。
public enum ColorGradePreset: String, CaseIterable, Sendable {
    case none
    case cinema
    case retro
    case cool
    case warm
    case mono

    /// このプリセットに対応する数値。
    public var grade: ColorGrade {
        switch self {
        case .none:
            return .identity
        case .cinema:
            return ColorGrade(brightness: -0.05, contrast: 1.2, saturation: 0.85, warmth: -0.1)
        case .retro:
            return ColorGrade(brightness: 0.05, contrast: 0.9, saturation: 0.7, warmth: 0.25)
        case .cool:
            return ColorGrade(brightness: 0, contrast: 1.05, saturation: 1.05, warmth: -0.35)
        case .warm:
            return ColorGrade(brightness: 0, contrast: 1.05, saturation: 1.05, warmth: 0.35)
        case .mono:
            return ColorGrade(brightness: 0, contrast: 1.1, saturation: 0.0, warmth: 0)
        }
    }

    /// 現在の数値に**厳密一致**するプリセットを逆引きする（無ければ nil = "カスタム"）。
    /// 保存経路には使わない（型の doc 参照）。UI のハイライト用途限定。
    public static func matching(_ grade: ColorGrade) -> ColorGradePreset? {
        allCases.first { $0.grade == grade }
    }
}
