import CoreGraphics
import Foundation

/// 合成フレーム（renderSize）へのアスペクトフィット配置の純ロジック。
///
/// S8 で解像度・向きの混在を解禁したことで、クリップの映像は必ずしも合成フレーム
/// 全面を占めない（レターボックス）。**同じ配置計算を映像側（instruction の
/// transform）と顔位置側（検出キャッシュの正規化座標）で共有する**ためにここへ切り出す。
/// 片方だけがレターボックスを知っていると、顔位置とフレームが食い違ってモザイクが漏れる。
public enum AspectFit {
    /// `contentSize` を `renderSize` 内にアスペクト比を保って収めたときの、
    /// renderSize を [0,1]×[0,1] とみなす正規化配置矩形（左上原点）。
    ///
    /// 縦横比が一致する場合は単位矩形（= レターボックスなし・恒等）を返す。
    /// 非有限・非正のサイズは判断材料が無いので単位矩形に倒す（呼び出し側での
    /// 分岐を増やさず、恒等 = 従来挙動へ落とすため）。
    public static func placement(of contentSize: CGSize, in renderSize: CGSize) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              renderSize.width.isFinite, renderSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return unit }
        let scale = min(renderSize.width / contentSize.width,
                        renderSize.height / contentSize.height)
        let width = contentSize.width * scale / renderSize.width
        let height = contentSize.height * scale / renderSize.height
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}

/// 素材の表示フレーム（`preferredTransform` 適用後）→ 合成フレームの**ピクセル変換**。
///
/// **映像とモザイクの一致は、この型と `TimelineRenderLayout` が同じ
/// `ClipOrientation` / `AspectFit` から作られていることで保証している。**
/// 映像側（`VideoCompositionFactory.fitTransform`）はここを呼ぶだけにし、
/// 回転・反転の数式を向こうに書かないこと。`ClipOrientationTests` が
/// 「この変換で写したピクセル座標」と「`TimelineRenderLayout.remap` で写した
/// 正規化座標」が一致することを全 8 向きで固定している。
public enum ClipRenderTransform {
    /// - Parameters:
    ///   - displaySize: `preferredTransform` 適用後・**向きを掛ける前**の素材表示サイズ。
    ///   - orientation: クリップの向き（90 度回転 + 左右反転）。
    ///   - placement: 合成フレーム内の配置矩形（`AspectFit.placement(of:in:)` の結果。
    ///     **向きを掛けた後のサイズ**で求めたものを渡すこと）。
    ///   - renderSize: 合成フレームのピクセルサイズ。
    public static func make(displaySize: CGSize,
                            orientation: ClipOrientation,
                            placement: CGRect,
                            renderSize: CGSize) -> CGAffineTransform {
        let rotate = orientation.transform(sourceSize: displaySize)
        let oriented = orientation.displaySize(displaySize)
        guard oriented.width > 0, oriented.height > 0 else { return rotate }
        let scale = placement.width * renderSize.width / oriented.width
        return rotate
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: placement.minX * renderSize.width,
                                             y: placement.minY * renderSize.height))
    }
}

/// クリップの表示サイズ・向き・出力枠・クロップから、配置矩形（`AspectFit.placement` に
/// クロップを合成したもの）を作る**唯一の場所**。
///
/// 「fit → crop.expand」の合成をここへ閉じることで、アプリ層にも写真側にも同じ数式を
/// 書き写させない。**クロップを実際の枠へ適用するときの正しい手順はここだけが知っている**
/// （`CropRect.expand` の doc 参照——丸め前の生のクロップ矩形を分母に使うと、
/// 偏差が偶数ピクセルへのスナップと食い違って 1px 以上ずれる）。
public enum RenderPlacement {
    /// - Parameters:
    ///   - displaySize: `preferredTransform` 適用後・**向きを掛ける前**の素材表示サイズ。
    ///   - orientation: クリップの向き（90 度回転 + 左右反転）。
    ///   - frame: 出力枠（合成フレーム）のピクセルサイズ。
    ///   - crop: 出力枠に対するクロップ。`.full` なら `AspectFit.placement` をそのまま返す
    ///     （クロップ無しタイムラインの忠実度を保つ）。
    public static func make(displaySize: CGSize, orientation: ClipOrientation,
                            frame: CGSize, crop: CropRect) -> CGRect {
        let oriented = orientation.displaySize(displaySize)
        let fitted = AspectFit.placement(of: oriented, in: frame)
        // 偶数スナップ込みの手順は `CropRect.expandSnapped` に実体化してある。
        // **ここで手順を書き下さないこと。** 書き下すと同じ数式が 2 箇所になり、
        // 片方だけ直る（この案件で色調補正が実際にそうなった）。
        return crop.expandSnapped(fitted, inFrame: frame)
    }
}

/// クリップ id → 合成フレーム内の配置（正規化矩形）。
///
/// 検出キャッシュに入っている顔ランドマークは**素材フレーム基準**の正規化座標なので、
/// 描画・書き出しへ渡す前にこの写像で合成フレーム基準へ移す必要がある
/// （`remap(_:clipID:)`）。無変換タイムライン（単一フォーマット）では全クリップが
/// 単位矩形になり恒等写像になる＝従来挙動と一致する。
/// **クリップの向き（`ClipOrientation`）もここに入る。** 素材フレームの正規化座標は
/// 「向きを掛ける → 配置矩形へ収める」の順で合成フレームへ写る。この順序は映像側
/// （`VideoCompositionFactory.fitTransform` が `preferredTransform → 向き → 配置`
/// の順に畳む）と同じでなければならない。**向きを映像にだけ掛けてここへ入れ忘れると、
/// 顔・矩形モザイクが素材からずれて素通しになる。**
public struct TimelineRenderLayout: Equatable, Sendable {
    /// 全面（レターボックスなし）を表す単位矩形。
    public static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 未登録のクリップは単位矩形（全面）として扱う。
    public let placements: [UUID: CGRect]

    /// クリップ id → 向き。未登録は無変換（`ClipOrientation.identity`）。
    ///
    /// **配置矩形（`placements`）は「向きを掛けた後の表示サイズ」で計算されていること。**
    /// 90 度回転で縦横が入れ替わるので、回転前のサイズでアスペクトフィットすると
    /// レターボックスの位置が合わず、映像とモザイクが食い違う。
    public let orientations: [UUID: ClipOrientation]

    /// **静止画編集（時間軸なし）専用**の配置矩形・向き。既定は単位矩形・無変換。
    ///
    /// `ObjectMask.Anchor.isStill` のマスクは `clipID` を持たないため、`placements` /
    /// `orientations`（クリップ id 引き）では表現できない。かといって
    /// `placement(for: nil)` に静止画の値を返させると、動画経路で `clipID` の解決に
    /// 失敗して `nil` が来たときに**静止画の配置を掴む**取り違えを作る
    /// （`placement(for: nil)` の意味は「クリップが未登録＝単位矩形」のまま変えない）。
    /// そのため専用のスロットを別に持つ。
    public var stillPlacement: CGRect
    public var stillOrientation: ClipOrientation

    /// 全クリップが合成フレーム全面（レターボックスなし）・無変換の恒等レイアウト。
    public static let identity = TimelineRenderLayout(placements: [:])

    public init(placements: [UUID: CGRect],
                orientations: [UUID: ClipOrientation] = [:],
                stillPlacement: CGRect = TimelineRenderLayout.unitRect,
                stillOrientation: ClipOrientation = .identity) {
        self.placements = placements
        self.orientations = orientations
        self.stillPlacement = stillPlacement
        self.stillOrientation = stillOrientation
    }

    /// クリップの配置矩形（未登録は単位矩形）。**`clipID: nil` は静止画の意味ではない**
    /// （常に単位矩形。静止画の配置は `stillPlacement` / `remapStill` を使うこと）。
    public func placement(for clipID: UUID?) -> CGRect {
        guard let clipID, let rect = placements[clipID] else { return Self.unitRect }
        return rect
    }

    /// クリップの向き（未登録は無変換）。
    public func orientation(for clipID: UUID?) -> ClipOrientation {
        guard let clipID, let orientation = orientations[clipID] else { return .identity }
        return orientation
    }

    /// 素材フレーム基準の正規化ランドマークを、合成フレーム基準へ写す。
    /// 向き → 配置矩形の順に適用する。どちらも恒等なら値をそのまま返す
    /// （浮動小数点の再計算誤差も入れない）。
    public func remap(_ sets: [FaceLandmarkSet], clipID: UUID?) -> [FaceLandmarkSet] {
        let rect = placement(for: clipID)
        let orientation = orientation(for: clipID)
        guard rect != Self.unitRect || !orientation.isIdentity else { return sets }
        return sets.map { $0.oriented(orientation).remapped(into: rect) }
    }

    /// 合成フレーム基準の正規化ランドマークを、素材フレーム基準へ逆写像する
    /// （`remap(_ sets:clipID:)` の対）。
    ///
    /// **合成フレームで検出した顔を検出キャッシュへ書く前に必ず通すこと。** プレビューの
    /// ライブ検出は `AVVideoComposition` を装着した合成フレーム（レターボックス込み）を
    /// 見ているので、その座標をそのまま素材キーで保存すると、描画・書き出し側で
    /// `remap` がもう一度掛かって二重にずれる（＝顔が素通しになる）。
    ///
    /// 配置が全面（恒等）のときは値をそのまま返す（浮動小数点の再計算誤差も入れない）。
    ///
    /// **矩形版（`inverseRemap(_ rect:clipID:)`）と違い、黒帯へのはみ出しを切り取らない。**
    /// 顔のランドマークは顔の輪郭より外へ出ることがあり、切り取ると顔が痩せて
    /// モザイクが小さくなる＝露出が増える方向へ倒れる。安全側は「素直に逆写像する」。
    ///
    /// **向きも戻すこと。** `remap` は「向き → 配置」の順で掛けるので、逆は
    /// 「配置の逆 → 向きの逆」でなければならない（矩形版と同じ順序）。
    /// 片方だけ戻すと、回したクリップで往復が成立せず顔が素通しになる。
    /// この 2 つは別々の機能として実装されたため、**マージで黙って食い違った前科がある。**
    public func inverseRemap(_ sets: [FaceLandmarkSet], clipID: UUID?) -> [FaceLandmarkSet] {
        let rect = placement(for: clipID)
        let orientation = orientation(for: clipID)
        guard rect != Self.unitRect || !orientation.isIdentity else { return sets }
        guard rect.width > 0, rect.height > 0 else { return sets }
        return sets.map { $0.unmapped(from: rect).oriented(orientation.inverted) }
    }

    /// 素材フレーム基準の正規化矩形を、合成フレーム基準へ写す
    /// （ランドマークの `remap` と同じ写像を矩形に適用したもの。`inverseRemap` の対）。
    /// 配置・向きがどちらも恒等のときは値をそのまま返す（再計算誤差も入れない）。
    public func remap(_ rect: CGRect, clipID: UUID?) -> CGRect {
        let place = placement(for: clipID)
        let oriented = orientation(for: clipID).map(rect)
        guard place != Self.unitRect else { return oriented }
        return CGRect(x: place.minX + oriented.minX * place.width,
                      y: place.minY + oriented.minY * place.height,
                      width: oriented.width * place.width,
                      height: oriented.height * place.height)
    }

    /// 素材フレーム基準の**ピクセル空間の傾き**（ラジアン・時計回り）を合成フレーム基準へ写す。
    ///
    /// レターボックス（`placements`）は素材の縦横比を保った等方変換なので角度を変えないが、
    /// **向き（回転・反転）は角度を変える**（`ObjectMaskPlacement.angle` の doc 参照）。
    public func remapAngle(_ angle: Double, clipID: UUID?) -> Double {
        let orientation = orientation(for: clipID)
        guard !orientation.isIdentity else { return angle }
        return orientation.mapAngle(angle)
    }

    /// `remapAngle(_:clipID:)` の逆写像（画面で指定された傾きを素材基準へ戻す）。
    public func inverseRemapAngle(_ angle: Double, clipID: UUID?) -> Double {
        let orientation = orientation(for: clipID)
        guard !orientation.isIdentity else { return angle }
        return orientation.inverseMapAngle(angle)
    }

    /// 合成フレーム基準の正規化矩形を、素材フレーム基準へ逆写像する（`remap` の対）。
    ///
    /// ユーザーがプレビュー（＝**合成フレーム**）上に描いた矩形を、素材フレームの
    /// クロップ範囲へ戻すために使う（`MosaicEditorModel` の矩形サーチ）。
    /// レターボックスされたクリップでこの逆写像を通さないと、矩形が素材上の別の場所を
    /// 指す（320x240 のフレームに 240x320 の素材を収めた場合、素材 x=0.10 に対して
    /// 合成 x=0.275 とずれる）。
    ///
    /// **矩形は点ではないので、黒帯にはみ出したぶんは切り落とす**: 与えられた矩形を
    /// 配置矩形と交差させてから素材座標へ写す（結果は必ず [0,1]×[0,1] に収まる）。
    /// 交差が空（＝矩形が完全に黒帯の中、または面積 0）なら **nil** を返し、
    /// 呼び出し側は「この素材には対応する領域が無い」として走査対象から外す
    /// （潰れた矩形で素材の端を誤検索しない）。
    /// 配置が全面（恒等）のときは値をそのまま返す（再計算誤差も入れない）。
    ///
    /// **向きも逆に戻す**（配置の逆写像 → 向きの逆写像の順。`remap` と逆順）。
    /// ユーザーが画面に描いた矩形は「回った後の絵」の上に描かれているので、
    /// 向きを戻さずに保存すると素材上の別の場所を指す。
    public func inverseRemap(_ rect: CGRect, clipID: UUID?) -> CGRect? {
        let place = placement(for: clipID)
        let orientation = orientation(for: clipID)
        guard place != Self.unitRect else { return orientation.inverseMap(rect) }
        guard place.width > 0, place.height > 0 else { return nil }
        let clipped = rect.standardized.intersection(place)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let originX = min(max((clipped.minX - place.minX) / place.width, 0), 1)
        let originY = min(max((clipped.minY - place.minY) / place.height, 0), 1)
        let inPlacement = CGRect(x: originX,
                                 y: originY,
                                 width: min(clipped.width / place.width, 1 - originX),
                                 height: min(clipped.height / place.height, 1 - originY))
        return orientation.inverseMap(inPlacement)
    }

    // MARK: - 静止画専用の写像

    /// 素材フレーム基準の正規化矩形を、合成フレーム基準へ写す（静止画編集専用）。
    /// `remap(_ rect:clipID:)` の静止画版で、`stillPlacement` / `stillOrientation` を使う。
    public func remapStill(_ rect: CGRect) -> CGRect {
        let oriented = stillOrientation.map(rect)
        guard stillPlacement != Self.unitRect else { return oriented }
        return CGRect(x: stillPlacement.minX + oriented.minX * stillPlacement.width,
                      y: stillPlacement.minY + oriented.minY * stillPlacement.height,
                      width: oriented.width * stillPlacement.width,
                      height: oriented.height * stillPlacement.height)
    }

    /// `remapStill(_:)` の逆写像。挙動は `inverseRemap(_ rect:clipID:)` と同一
    /// （はみ出しは配置矩形と交差させて切り落とす）で、`stillPlacement` / `stillOrientation`
    /// を使う。
    public func inverseRemapStill(_ rect: CGRect) -> CGRect? {
        guard stillPlacement != Self.unitRect else { return stillOrientation.inverseMap(rect) }
        guard stillPlacement.width > 0, stillPlacement.height > 0 else { return nil }
        let clipped = rect.standardized.intersection(stillPlacement)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let originX = min(max((clipped.minX - stillPlacement.minX) / stillPlacement.width, 0), 1)
        let originY = min(max((clipped.minY - stillPlacement.minY) / stillPlacement.height, 0), 1)
        let inPlacement = CGRect(x: originX,
                                 y: originY,
                                 width: min(clipped.width / stillPlacement.width, 1 - originX),
                                 height: min(clipped.height / stillPlacement.height, 1 - originY))
        return stillOrientation.inverseMap(inPlacement)
    }

    /// 素材フレーム基準のピクセル空間の傾きを合成フレーム基準へ写す（静止画編集専用）。
    /// `remapAngle(_:clipID:)` の静止画版。
    public func remapStillAngle(_ angle: Double) -> Double {
        guard !stillOrientation.isIdentity else { return angle }
        return stillOrientation.mapAngle(angle)
    }

    /// `remapStillAngle(_:)` の逆写像。
    public func inverseRemapStillAngle(_ angle: Double) -> Double {
        guard !stillOrientation.isIdentity else { return angle }
        return stillOrientation.inverseMapAngle(angle)
    }

    /// 素材フレーム基準の正規化ランドマークを、合成フレーム基準へ写す（静止画編集専用）。
    /// `remap(_ sets:clipID:)` の静止画版で、`stillPlacement` / `stillOrientation` を使う。
    public func remapStill(_ sets: [FaceLandmarkSet]) -> [FaceLandmarkSet] {
        guard stillPlacement != Self.unitRect || !stillOrientation.isIdentity else { return sets }
        return sets.map { $0.oriented(stillOrientation).remapped(into: stillPlacement) }
    }

    /// `remapStill(_ sets:)` の逆写像（`inverseRemap(_ sets:clipID:)` の静止画版）。
    public func inverseRemapStill(_ sets: [FaceLandmarkSet]) -> [FaceLandmarkSet] {
        guard stillPlacement != Self.unitRect || !stillOrientation.isIdentity else { return sets }
        guard stillPlacement.width > 0, stillPlacement.height > 0 else { return sets }
        return sets.map { $0.unmapped(from: stillPlacement).oriented(stillOrientation.inverted) }
    }

    /// 素材フレーム基準の `MaskBuffer`（背景モザイクの人物/背景マスク）を、
    /// 合成フレーム基準（＝写真の向きを掛けた後）へ写す（静止画編集専用）。
    ///
    /// **画素は完全保存**（90 度単位の回転のみ。`MaskBuffer.oriented(_:)` 参照）。
    /// `stillPlacement` は現状のところ写真にレターボックスが無い（クロップ未実装）ため
    /// 常に単位矩形であり、`remapStill(_ rect:)` と違って再サンプリングを伴う
    /// スケーリングは行わない——スケーリングを持ち込むと画素の完全保存が崩れる。
    public func remapStill(_ mask: MaskBuffer) -> MaskBuffer {
        mask.oriented(stillOrientation)
    }
}
