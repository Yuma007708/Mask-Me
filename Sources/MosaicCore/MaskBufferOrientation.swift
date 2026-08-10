import CoreGraphics
import Foundation

/// `MaskBuffer`（背景モザイクの人物/背景マスク）へ `ClipOrientation` を掛ける。
///
/// 90 度単位の回転 + 左右反転のみを扱うため、補間は一切要らない——出力の各画素は
/// 入力のちょうど 1 画素のコピーであり、**画素は完全保存**される（値が変わったり
/// 平均化されたりしない）。`TimelineRenderLayout.remapStill(_ mask:)` の実体はここ。
///
/// 新しい写像の数式は書かない: 既存の `ClipOrientation.inverseMap(_:CGPoint)`
/// （正規化座標・[0,1]×[0,1]・左上原点）をピクセル中心へ適用するだけ。90 度単位の
/// 写像は軸を保つので、ピクセル中心を写した結果は常に対応する 1 ピクセルの中に
/// 厳密に収まる（浮動小数点の丸めで境界を跨ぐ余地が無い）。
extension MaskBuffer {
    /// この向きを掛けた `MaskBuffer` を返す。90/270 度では `width`/`height` が入れ替わる。
    ///
    /// `orientation.isIdentity` のときは自身をそのまま返す（配列の作り直しコストも省く）。
    public func oriented(_ orientation: ClipOrientation) -> MaskBuffer {
        guard !orientation.isIdentity else { return self }
        let outWidth = orientation.swapsDimensions ? height : width
        let outHeight = orientation.swapsDimensions ? width : height
        guard width > 0, height > 0, outWidth > 0, outHeight > 0,
              bytes.count >= width * height else {
            return MaskBuffer(bytes: [], width: max(outWidth, 0), height: max(outHeight, 0))
        }
        var outBytes = [UInt8](repeating: 0, count: outWidth * outHeight)
        for outY in 0..<outHeight {
            for outX in 0..<outWidth {
                // 出力ピクセル中心の正規化座標 → `inverseMap` で入力側の正規化座標へ。
                let normalized = CGPoint(
                    x: (CGFloat(outX) + 0.5) / CGFloat(outWidth),
                    y: (CGFloat(outY) + 0.5) / CGFloat(outHeight))
                let source = orientation.inverseMap(normalized)
                let srcX = min(max(Int(source.x * CGFloat(width)), 0), width - 1)
                let srcY = min(max(Int(source.y * CGFloat(height)), 0), height - 1)
                outBytes[outY * outWidth + outX] = bytes[srcY * width + srcX]
            }
        }
        return MaskBuffer(bytes: outBytes, width: outWidth, height: outHeight)
    }
}
