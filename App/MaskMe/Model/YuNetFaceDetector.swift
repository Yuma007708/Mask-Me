import UIKit
import CoreML

/// YuNet (OpenCV face detector) を Core ML で実行する `FaceBBoxDetecting` 実装。
///
/// 入力: 1×3×640×640 BGR float32 (mean=0, std=1)。
/// 出力: stride 8/16/32 ごとに `cls_S` `obj_S` `bbox_S` `kps_S` の 4 テンソル。
/// `score = cls × obj` を閾値で絞り、anchor-based の bbox を decode して NMS で絞る。
///
/// モデルファイル `yunet.mlmodel`（OpenCV Zoo の `face_detection_yunet_2023mar.onnx`
/// を coremltools 5.2 で変換、Apache 2.0）が Bundle に含まれていればロードする。
/// 見つからなければ空配列を返すフォールバック。
struct YuNetFaceDetector: FaceBBoxDetecting {
    private let model: MLModel?
    private let inputSize = 640
    private let strides = [8, 16, 32]
    private let scoreThreshold: Float = 0.6
    private let nmsThreshold: CGFloat = 0.3

    init(modelName: String = "yunet") {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else {
            self.model = nil
            return
        }
        self.model = model
    }

    func detectFaceBoundingBoxes(in image: UIImage) -> [CGRect] {
        guard let model, let cg = image.cgImage else { return [] }
        let origW = cg.width
        let origH = cg.height
        guard origW > 0, origH > 0 else { return [] }

        // Letterbox：アスペクト比を保ったまま 640x640 内に収めて余白は黒パディング。
        // stretch すると元画像のアスペクト比が壊れて、縦長/横長動画で体を顔サイズに誤検出する。
        let scale = min(CGFloat(inputSize) / CGFloat(origW), CGFloat(inputSize) / CGFloat(origH))
        let newW = Int((CGFloat(origW) * scale).rounded())
        let newH = Int((CGFloat(origH) * scale).rounded())
        let padX = (inputSize - newW) / 2
        let padY = (inputSize - newH) / 2

        guard let buffer = letterboxBGRA(cg, drawSize: CGSize(width: newW, height: newH),
                                         intoSize: inputSize, padX: padX, padY: padY),
              let input = makeMultiArray(from: buffer, size: inputSize),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["input": input]),
              let output = try? model.prediction(from: provider) else {
            return []
        }

        // Decode each stride and accumulate candidates in 640x640 letterboxed pixel coords.
        var candidates: [(rect: CGRect, score: Float)] = []
        for stride in strides {
            guard let cls = output.featureValue(for: "cls_\(stride)")?.multiArrayValue,
                  let obj = output.featureValue(for: "obj_\(stride)")?.multiArrayValue,
                  let bbox = output.featureValue(for: "bbox_\(stride)")?.multiArrayValue else {
                continue
            }
            decodeStride(stride: stride, cls: cls, obj: obj, bbox: bbox,
                         into: &candidates)
        }

        // NMS to drop duplicate boxes.
        let kept = nms(candidates, iouThreshold: nmsThreshold)

        // Letterbox 座標 (640x640) → 元画像ピクセル座標 → [0, 1] 正規化。
        // 引き伸ばし時のアスペクト歪みを排除するため、padX/padY を引いてから scale で割る。
        let origWF = CGFloat(origW)
        let origHF = CGFloat(origH)
        return kept.compactMap { det in
            let xInScaled = det.rect.minX - CGFloat(padX)
            let yInScaled = det.rect.minY - CGFloat(padY)
            let origX = xInScaled / scale
            let origY = yInScaled / scale
            let origRectW = det.rect.width / scale
            let origRectH = det.rect.height / scale
            guard origRectW > 0, origRectH > 0 else { return nil }
            return CGRect(
                x: origX / origWF,
                y: origY / origHF,
                width: origRectW / origWF,
                height: origRectH / origHF
            )
        }
    }

    // MARK: - Decode

    private func decodeStride(
        stride: Int,
        cls: MLMultiArray,
        obj: MLMultiArray,
        bbox: MLMultiArray,
        into candidates: inout [(rect: CGRect, score: Float)]
    ) {
        let gridW = inputSize / stride
        let n = cls.shape[1].intValue
        // multiArray は連続メモリで float32。直接ポインタ参照で高速化。
        guard cls.dataType == .float32, obj.dataType == .float32, bbox.dataType == .float32 else {
            return
        }
        let clsPtr = cls.dataPointer.bindMemory(to: Float32.self, capacity: n)
        let objPtr = obj.dataPointer.bindMemory(to: Float32.self, capacity: n)
        let bboxPtr = bbox.dataPointer.bindMemory(to: Float32.self, capacity: n * 4)
        let strideF = Float(stride)
        for i in 0..<n {
            let score = clsPtr[i] * objPtr[i]
            if score < scoreThreshold { continue }
            let gx = i % gridW
            let gy = i / gridW
            let ax = (Float(gx) + 0.5) * strideF
            let ay = (Float(gy) + 0.5) * strideF
            let base = i * 4
            let cx = ax + bboxPtr[base] * strideF
            let cy = ay + bboxPtr[base + 1] * strideF
            let w = exp(bboxPtr[base + 2]) * strideF
            let h = exp(bboxPtr[base + 3]) * strideF
            candidates.append((
                rect: CGRect(
                    x: CGFloat(cx - w / 2),
                    y: CGFloat(cy - h / 2),
                    width: CGFloat(w),
                    height: CGFloat(h)
                ),
                score: score
            ))
        }
    }

    private func nms(
        _ dets: [(rect: CGRect, score: Float)],
        iouThreshold: CGFloat
    ) -> [(rect: CGRect, score: Float)] {
        let sorted = dets.sorted { $0.score > $1.score }
        var kept: [(rect: CGRect, score: Float)] = []
        for det in sorted where !kept.contains(where: { iou($0.rect, det.rect) > iouThreshold }) {
            kept.append(det)
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    // MARK: - Image prep

    /// CGImage を `intoSize × intoSize` の BGRA バッファに letterbox 焼き込みする。
    /// 余白（pad）は init 時の zero-fill（黒）のまま、scaled image は `(padX, padY)` 位置に描画。
    private func letterboxBGRA(_ cg: CGImage, drawSize: CGSize, intoSize: Int,
                               padX: Int, padY: Int) -> [UInt8]? {
        let bytesPerPixel = 4
        let bytesPerRow = intoSize * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: intoSize * intoSize * bytesPerPixel)
        let cs = CGColorSpaceCreateDeviceRGB()
        // bitmap info: BGRA で並ぶように noneSkipFirst + little endian。
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.noneSkipFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = buffer.withUnsafeMutableBytes({ rawBuffer -> CGContext? in
            guard let base = rawBuffer.baseAddress else { return nil }
            return CGContext(
                data: base, width: intoSize, height: intoSize,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs, bitmapInfo: bitmapInfo
            )
        }) else { return nil }
        ctx.draw(cg, in: CGRect(x: padX, y: padY,
                                 width: Int(drawSize.width),
                                 height: Int(drawSize.height)))
        return buffer
    }

    /// BGRA バッファを (1, 3, size, size) の Float32 MLMultiArray に詰める。
    /// チャンネル順は BGR（YuNet の学習時の順序に合わせる）、正規化なし（mean=0, std=1）。
    private func makeMultiArray(from bgra: [UInt8], size: Int) -> MLMultiArray? {
        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        ) else { return nil }
        let channelStride = size * size
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * channelStride)
        // BGRA バイト並びは [B, G, R, A]（noneSkipFirst + little endian の結果）。
        for y in 0..<size {
            for x in 0..<size {
                let pixelBase = (y * size + x) * 4
                let b = Float32(bgra[pixelBase])
                let g = Float32(bgra[pixelBase + 1])
                let r = Float32(bgra[pixelBase + 2])
                let idx = y * size + x
                ptr[0 * channelStride + idx] = b
                ptr[1 * channelStride + idx] = g
                ptr[2 * channelStride + idx] = r
            }
        }
        return array
    }
}
