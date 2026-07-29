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

/// クリップ id → 合成フレーム内の配置（正規化矩形）。
///
/// 検出キャッシュに入っている顔ランドマークは**素材フレーム基準**の正規化座標なので、
/// 描画・書き出しへ渡す前にこの写像で合成フレーム基準へ移す必要がある
/// （`remap(_:clipID:)`）。無変換タイムライン（単一フォーマット）では全クリップが
/// 単位矩形になり恒等写像になる＝従来挙動と一致する。
public struct TimelineRenderLayout: Equatable, Sendable {
    /// 全面（レターボックスなし）を表す単位矩形。
    public static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 未登録のクリップは単位矩形（全面）として扱う。
    public let placements: [UUID: CGRect]

    /// 全クリップが合成フレーム全面（レターボックスなし）の恒等レイアウト。
    public static let identity = TimelineRenderLayout(placements: [:])

    public init(placements: [UUID: CGRect]) {
        self.placements = placements
    }

    /// クリップの配置矩形（未登録は単位矩形）。
    public func placement(for clipID: UUID?) -> CGRect {
        guard let clipID, let rect = placements[clipID] else { return Self.unitRect }
        return rect
    }

    /// 素材フレーム基準の正規化ランドマークを、合成フレーム基準へ写す。
    /// 配置が全面（恒等）のときは値をそのまま返す（浮動小数点の再計算誤差も入れない）。
    public func remap(_ sets: [FaceLandmarkSet], clipID: UUID?) -> [FaceLandmarkSet] {
        let rect = placement(for: clipID)
        guard rect != Self.unitRect else { return sets }
        return sets.map { $0.remapped(into: rect) }
    }

    /// 素材フレーム基準の正規化矩形を、合成フレーム基準へ写す
    /// （ランドマークの `remap` と同じ写像を矩形に適用したもの。`inverseRemap` の対）。
    /// 配置が全面（恒等）のときは値をそのまま返す（再計算誤差も入れない）。
    public func remap(_ rect: CGRect, clipID: UUID?) -> CGRect {
        let place = placement(for: clipID)
        guard place != Self.unitRect else { return rect }
        return CGRect(x: place.minX + rect.minX * place.width,
                      y: place.minY + rect.minY * place.height,
                      width: rect.width * place.width,
                      height: rect.height * place.height)
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
    public func inverseRemap(_ rect: CGRect, clipID: UUID?) -> CGRect? {
        let place = placement(for: clipID)
        guard place != Self.unitRect else { return rect }
        guard place.width > 0, place.height > 0 else { return nil }
        let clipped = rect.standardized.intersection(place)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let originX = min(max((clipped.minX - place.minX) / place.width, 0), 1)
        let originY = min(max((clipped.minY - place.minY) / place.height, 0), 1)
        return CGRect(x: originX,
                      y: originY,
                      width: min(clipped.width / place.width, 1 - originX),
                      height: min(clipped.height / place.height, 1 - originY))
    }
}
