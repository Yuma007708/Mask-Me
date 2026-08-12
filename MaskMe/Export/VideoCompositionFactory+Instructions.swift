import AVFoundation
import CoreGraphics
import Foundation
import MosaicCore

/// `VideoCompositionFactory` の instruction 組み立て。
///
/// **`VideoCompositionFactory.swift` が file_length（500 行）に達したので分けた。**
/// 中身は移設しただけで規則は変えていない。分ける線をここに引いたのは、
/// 「どのクリップをどう置くか」（本体）と「時間をどう区切って instruction にするか」
/// （こちら）が別の関心事だからである。
extension VideoCompositionFactory {
    /// 余白に塗る色を `CGColor` へ。**色空間は sRGB を明示する。**
    /// device RGB のままだと端末・書き出し経路で数値が同じでも見た目の色がずれる。
    static func cgColor(_ color: RGBAColor) -> CGColor {
        let clamped = color.clamped
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       components: [CGFloat(clamped.red), CGFloat(clamped.green),
                                    CGFloat(clamped.blue), CGFloat(clamped.alpha)])
            ?? CGColor(gray: 0, alpha: 1)
    }

    static func instructions(placements: [ClipPlacement],
                             background: TimelineBackground = .default,
                             overlaps: [TimelineMapping.Overlap],
                             transforms: [UUID: CGAffineTransform],
                             renderSize: CGSize,
                             totalDuration: Double) -> [AVMutableVideoCompositionInstruction] {
        var boundaries: Set<Double> = [0, totalDuration]
        for placement in placements {
            boundaries.insert(placement.start)
            boundaries.insert(placement.end)
        }
        for overlap in overlaps {
            for breakpoint in overlap.kind.rampBreakpoints {
                boundaries.insert(overlap.start + overlap.duration * breakpoint)
            }
        }
        let sorted = boundaries.filter { $0.isFinite && $0 >= 0 && $0 <= totalDuration }.sorted()
        var result: [AVMutableVideoCompositionInstruction] = []
        for index in 0..<max(sorted.count - 1, 0) {
            let (from, to) = (sorted[index], sorted[index + 1])
            guard to > from else { continue }
            let active = placements.filter { $0.start <= from && from < $0.end }
            guard !active.isEmpty else { continue }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(from), end: time(to))
            // レターボックス（素材が出力枠に収まらないときの余白）の色。
            // **ここはプレビューと書き出しの両方が通る唯一の場所**なので、色を
            // 塗るだけなら Metal 側に手を入れる必要が無い（ぼかしは種が要るので別経路）。
            // 既定（黒）のときは何も設定しない——AVFoundation の既定色と同じ値を
            // わざわざ書くと、`CompositionFidelityTests` が見ている「無変換構成では
            // 素の composition と同じ」という性質に無用な差分を持ち込む。
            if background.kind != .black {
                instruction.backgroundColor = Self.cgColor(background.fillColor)
            }
            instruction.layerInstructions = layerInstructions(
                active: active,
                segment: Segment(overlaps: overlaps, transforms: transforms,
                                 renderSize: renderSize, from: from, to: to))
            result.append(instruction)
        }
        // 端数の丸めで最後の instruction が composition の末尾に届かないと、
        // AVFoundation の検証で「隙間あり」になる。末尾だけ明示的に伸ばす。
        if let last = result.last {
            let end = time(totalDuration)
            if last.timeRange.end < end {
                last.timeRange = CMTimeRange(start: last.timeRange.start, end: end)
            }
        }
        return result
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// instruction 1 区間ぶんの生成コンテキスト。
    private struct Segment {
        let overlaps: [TimelineMapping.Overlap]
        /// クリップ id → 素材フレーム → 合成フレームの基本変換。
        let transforms: [UUID: CGAffineTransform]
        let renderSize: CGSize
        /// 区間 [from, to)（合成時刻・秒）。
        let from: Double
        let to: Double
    }

    /// 区間 [from, to) に映るクリップのレイヤ instruction。
    ///
    /// 重なり区間では**前面 = outgoing / 背面 = incoming** の順に並べる
    /// （`TransitionKind.incomingLayerOpacityRamp` の doc の合成式と同じ前提）。
    private static func layerInstructions(active: [ClipPlacement],
                                          segment: Segment)
    -> [AVMutableVideoCompositionLayerInstruction] {
        let (from, to) = (segment.from, segment.to)
        let range = CMTimeRange(start: time(from), end: time(to))
        let overlap = active.count >= 2
            ? segment.overlaps.first { $0.start <= from && from < $0.end }
            : nil
        // 前面（outgoing）が先。重なりが無ければ順序は意味を持たない。
        let ordered: [ClipPlacement]
        if let overlap {
            ordered = active.filter { $0.clip.id == overlap.outgoingClipID }
                + active.filter { $0.clip.id != overlap.outgoingClipID }
        } else {
            ordered = active
        }
        return ordered.map { placement in
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: placement.track)
            let base = segment.transforms[placement.clip.id] ?? .identity
            guard let overlap,
                  let side = side(of: placement, in: overlap) else {
                layer.setTransform(base, at: range.start)
                layer.setOpacity(1, at: range.start)
                return layer
            }
            applyRamps(to: layer, input: RampInput(
                kind: overlap.kind, side: side,
                from: progress(of: from, in: overlap),
                to: progress(of: to, in: overlap),
                base: base, renderSize: segment.renderSize, range: range))
            return layer
        }
    }

    private static func side(of placement: ClipPlacement,
                             in overlap: TimelineMapping.Overlap) -> TransitionSide? {
        switch placement.clip.id {
        case overlap.outgoingClipID: return .outgoing
        case overlap.incomingClipID: return .incoming
        default: return nil
        }
    }

    private static func progress(of compositionTime: Double,
                                 in overlap: TimelineMapping.Overlap) -> Double {
        guard overlap.duration > 0 else { return 0 }
        return TransitionKind.clampedProgress((compositionTime - overlap.start) / overlap.duration)
    }

    /// 1 レイヤぶんのランプ入力（進行度の区間と、そのレイヤの基本変換）。
    private struct RampInput {
        let kind: TransitionKind
        let side: TransitionSide
        /// 区間端の進行度（0...1）。
        let from: Double
        let to: Double
        let base: CGAffineTransform
        let renderSize: CGSize
        let range: CMTimeRange
    }

    /// 1 レイヤぶんのランプ（不透明度・変換・クロップ）を設定する。
    /// 値はすべて `TransitionKind` の純関数から取る（数式をここに書かない）。
    private static func applyRamps(to layer: AVMutableVideoCompositionLayerInstruction,
                                   input: RampInput) {
        let (kind, side, p0, p1) = (input.kind, input.side, input.from, input.to)
        let (base, renderSize, range) = (input.base, input.renderSize, input.range)
        let start = kind.parameters(progress: p0, side: side)
        let end = kind.parameters(progress: p1, side: side)

        switch side {
        case .outgoing:
            layer.setOpacityRamp(fromStartOpacity: Float(start.opacity),
                                 toEndOpacity: Float(end.opacity),
                                 timeRange: range)
        case .incoming:
            // 背面レイヤは「意図した合成結果」を再現する値を使う（doc 参照）。
            let ramp = kind.incomingLayerOpacityRamp(from: p0, to: p1)
            layer.setOpacityRamp(fromStartOpacity: Float(ramp.start),
                                 toEndOpacity: Float(ramp.end),
                                 timeRange: range)
        }

        let startTransform = base.concatenating(translation(start.translation, in: renderSize))
        let endTransform = base.concatenating(translation(end.translation, in: renderSize))
        if startTransform == endTransform {
            layer.setTransform(startTransform, at: range.start)
        } else {
            layer.setTransformRamp(fromStart: startTransform, toEnd: endTransform, timeRange: range)
        }

        // クロップは**素材座標**で指定し、変換より前に適用される。画面上の可視領域を
        // 変換の逆写像で素材座標へ戻す（回転済み素材でも画面基準のワイプになる）。
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard start.visibleRect != unit || end.visibleRect != unit else { return }
        let inverse = startTransform.inverted()
        let startCrop = screenRect(start.visibleRect, in: renderSize).applying(inverse)
        let endCrop = screenRect(end.visibleRect, in: renderSize)
            .applying(endTransform.inverted())
        if startCrop == endCrop {
            layer.setCropRectangle(startCrop, at: range.start)
        } else {
            layer.setCropRectangleRamp(fromStartCropRectangle: startCrop,
                                       toEndCropRectangle: endCrop,
                                       timeRange: range)
        }
    }

    private static func translation(_ vector: CGVector, in renderSize: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: vector.dx * renderSize.width,
                          y: vector.dy * renderSize.height)
    }

    private static func screenRect(_ normalized: CGRect, in renderSize: CGSize) -> CGRect {
        CGRect(x: normalized.minX * renderSize.width,
               y: normalized.minY * renderSize.height,
               width: normalized.width * renderSize.width,
               height: normalized.height * renderSize.height)
    }}
