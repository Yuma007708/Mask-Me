import XCTest
import CoreGraphics
import UIKit
import MosaicCore
@testable import MaskMe

#if canImport(Metal)

/// 写真モードのクロップ結線（S6）を固定する。
///
/// 写真には動画の AVFoundation 段が無いため、`renderPreview()` は常に全画素を描く
/// （`MosaicEditorModel+Crop.swift` 型 doc 参照）。クロップは表示・保存の直前で
/// `StillCropRenderer` / `MosaicEditorModel.croppedPreviewImage` を通して初めて掛かる。
///
/// 実顔素材・MediaPipe は使わない（`NullFaceLandmarker` で完結。
/// `PhotoDraftColorGradeRoundTripTests` と同じ流儀）。ここで検証したいのは検出や
/// 描画そのものではなく、クロップという「切る」操作の配線なので、Metal の実描画も
/// 不要——`previewImage` は `@Published public var` なので、テストからは
/// `renderPreview()` を経由せず直接値を入れて確かめる。
@MainActor
final class PhotoCropTests: XCTestCase {
    // MARK: - テスト素材

    /// 縦 3 色帯（赤 | 緑 | 青）の合成画像。**サイズだけでなく画素そのもの**で
    /// 「切った側の色が消えている」ことを確認するために使う（サイズだけ見ると
    /// 左右を取り違えた実装を素通りさせる、という親の指摘に対応）。
    ///
    /// `scale = 1` に固定する。`renderPreview()` が作る `UIImage(cgImage:)` も
    /// 既定で `scale = 1` なので、実物と同じ前提を保つ。
    private func makeBandedImage(width: Int = 300, height: Int = 200) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let bandWidth = CGFloat(width) / 3
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: bandWidth, height: CGFloat(height)))
            UIColor.green.setFill()
            ctx.fill(CGRect(x: bandWidth, y: 0, width: bandWidth, height: CGFloat(height)))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: bandWidth * 2, y: 0, width: bandWidth, height: CGFloat(height)))
        }
    }

    /// `rgbaBytes(of:)` が返す、既知フォーマット（RGBA8・premultiplied last）の生バッファ。
    private struct RGBABuffer {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    /// 1 画素分の色（RGBA8 の R/G/B のみ。この用途にアルファは要らない）。
    private struct PixelColor {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    /// `cgImage` を既知の RGBA8（premultiplied last）バッファへ描き直して読む。
    /// **元画像自身のピクセルフォーマット（BGRA か RGBA か等）に依存しないための
    /// 迂回**——`cgImage.dataProvider` を直接読むと、生成経路によって並びが変わり
    /// テストが環境依存になる。
    private func rgbaBytes(of image: UIImage) -> RGBABuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBABuffer(bytes: bytes, width: width, height: height)
    }

    /// 帯の画像は上下方向に一様なので、`y` は中央に固定してよい。
    private func pixel(_ rgba: RGBABuffer, x: Int, y: Int? = nil) -> PixelColor {
        let row = y ?? rgba.height / 2
        let offset = (row * rgba.width + x) * 4
        return PixelColor(r: rgba.bytes[offset], g: rgba.bytes[offset + 1], b: rgba.bytes[offset + 2])
    }

    private func isRed(_ p: PixelColor) -> Bool { p.r > 200 && p.g < 50 && p.b < 50 }
    private func isGreen(_ p: PixelColor) -> Bool { p.g > 200 && p.r < 50 && p.b < 50 }
    private func isBlue(_ p: PixelColor) -> Bool { p.b > 200 && p.r < 50 && p.g < 50 }

    private func makeModel(mode: MosaicEditorModel.Mode = .photo) -> MosaicEditorModel {
        MosaicEditorModel(mode: mode, recents: RecentItemsStore(), landmarker: NullFaceLandmarker())
    }

    // MARK: - StillCropRenderer（表示画像そのもの）

    /// 帯の右 2/3（緑・青）だけを残すクロップ。赤帯はちょうど境界（100px）で切れる。
    private func rightTwoThirds() -> CropRect {
        CropRect(rect: CGRect(x: 100.0 / 300.0, y: 0, width: 200.0 / 300.0, height: 1.0))
    }

    func test_写真の表示画像がクロップされる() throws {
        let image = makeBandedImage()
        let crop = rightTwoThirds()
        let cropped = StillCropRenderer.cropped(image, crop: crop)

        guard let rgba = rgbaBytes(of: cropped) else {
            XCTFail("クロップ後の画像から画素が読めない")
            return
        }
        // 元の赤帯（0..<100px）は切り落とされているはず。クロップ後の左端は
        // 元画像の x=100（緑帯の先頭）に対応する——ここが赤のままなら
        // 「切ったつもりで切れていない」実装を捕まえる。
        XCTAssertTrue(isGreen(pixel(rgba, x: 0)),
                      "クロップ後の左端が緑ではない（赤帯を切り落とせていない）")
        // 右端付近（元画像の x=290 相当）は青のまま残っているはず。
        XCTAssertTrue(isBlue(pixel(rgba, x: rgba.width - 5)),
                      "クロップ後の右端付近が青ではない（残すべき領域が消えている）")
        // 赤は画面のどこにも残っていないはず（切った側の色が消えていることの直接確認）。
        for x in stride(from: 0, to: rgba.width, by: 7) {
            XCTAssertFalse(isRed(pixel(rgba, x: x)), "クロップ後の画像に赤（切ったはずの帯）が残っている（x=\(x)）")
        }
    }

    // MARK: - 保存画像と表示画像

    /// `savePhoto()` が表示と同じ `croppedPreviewImage` を経由すること。
    ///
    /// **これは `test_写真の表示画像がクロップされる` と必ずセットで置く。**
    /// 単独では「表示・保存のどちらもクロップしていない」実装まで緑にしてしまう
    /// （親の指摘）。ここで `savePhoto()` のソースを直接検査し、表示と同じ
    /// `croppedPreviewImage` を読んでいること・別経路で独自にクロップし直して
    /// いないことを固定する（`PhotoRenderPipelineParityTests` と同じ流儀の
    /// 構造テスト。`PhotosSaver` は実際の写真ライブラリ権限が要るため、ここでは
    /// 呼び出さない）。
    func test_保存画像と表示画像の画素が一致する() throws {
        let url = try maskMeDirectory().appendingPathComponent("Model/MosaicEditorModel.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let stripped = strippingComments(text)
        guard let body = extractFunctionBody(named: "savePhoto", in: stripped) else {
            XCTFail("savePhoto() が見つからない")
            return
        }
        XCTAssertTrue(body.contains("croppedPreviewImage"),
                      "savePhoto() が croppedPreviewImage（表示と共有するクロップ済み画像）を読んでいない")
        XCTAssertFalse(body.contains("StillCropRenderer.cropped("),
                       "savePhoto() が独自に StillCropRenderer を呼んでいる" +
                       "（表示（croppedPreviewImage）と別経路でクロップしている疑い）")
    }

    // MARK: - 動画と同じ関数

    /// 写真のクロップ寸法は `CropRect.snappedRect(inFrame:)` の偶数スナップを経由する
    /// （動画の出力サイズ計算 `TimelineCompositionBuilder+OutputSizing.swift` が使う
    /// `CropRect.outputSize(fittingFrame:)` と同じ関数）。
    ///
    /// わざと**奇数**になる境界（256px 中 51px）を選ぶ: `pixelRect` を素で使う
    /// 実装（偶数スナップを経ない）なら 51 のまま、`snappedRect` を正しく経由すれば
    /// 52 へ丸まる。サイズが一致しないと「別の丸めを実装した」実装を検出できる。
    ///
    /// **画像幅を 2 の冪（256）にする。** `51.0/256.0*256.0` は二進浮動小数点で
    /// 丸め誤差なく厳密に 51.0 になる（2 の冪での除算・乗算は指数部の移動だけで
    /// 仮数部を壊さない）。奇数境界のテストは `.rounded()` が丁度 X.5 をまたぐかどうかに
    /// 敏感なので、誤差で 50.999… に落ちて丸め方向が変わる事故を避けるためにここを選ぶ。
    func test_写真のクロップ寸法が動画と同じ関数から出る() throws {
        let width = 256
        let height = 200
        let image = makeBandedImage(width: width, height: height)
        let crop = CropRect(rect: CGRect(x: 0, y: 0, width: 51.0 / Double(width), height: 1.0))

        let cropped = StillCropRenderer.cropped(image, crop: crop)
        guard let croppedCG = cropped.cgImage else {
            XCTFail("クロップ後の cgImage が無い")
            return
        }
        let expected = crop.outputSize(fittingFrame: CGSize(width: width, height: height))

        XCTAssertEqual(CGFloat(croppedCG.width), expected.width,
                       "写真のクロップ幅が CropRect.outputSize(fittingFrame:)（動画と同じ関数）と食い違う")
        XCTAssertEqual(CGFloat(croppedCG.height), expected.height,
                       "写真のクロップ高さが CropRect.outputSize(fittingFrame:)（動画と同じ関数）と食い違う")
        // 偶数スナップが実際に効いていること（51 のままなら丸めをすり抜けている）。
        XCTAssertEqual(Int(expected.width) % 2, 0, "テスト前提: 期待値そのものが偶数でない")
        XCTAssertNotEqual(croppedCG.width, 51, "偶数スナップを経ていない（pixelRect を素で使っている疑い）")
    }

    // MARK: - オーバーレイ座標（顔タップの当たり判定）

    /// クロップ前後で、同じ「見えている顔」を指す画面タップが同じ正規化座標
    /// （＝同じ顔）へ写像されること。
    ///
    /// 顔検出の座標は写真では常に**全画素基準**（クロップの影響を受けない）で
    /// 保持される。クロップ後は表示画像そのものが切られているため、
    /// `PreviewImageGeometry` が `crop` を通して正しく逆算できないと、
    /// 「見えている顔をタップしたのに別人が選ばれる」——モザイクを減らす方向の
    /// 欠陥になる。
    func test_クロップ後も顔タップの当たり判定が正しい顔を指す() throws {
        // 全画素基準の顔の位置（左寄り＝クロップで消える顔、右寄り＝残る顔）。
        let culledFace = CGRect(x: 0.15, y: 0.45, width: 0.1, height: 0.1)
        let keptFace = CGRect(x: 0.65, y: 0.45, width: 0.1, height: 0.1)
        let keptCenter = CGPoint(x: keptFace.midX, y: keptFace.midY)

        // 右半分だけを残すクロップ。
        let crop = CropRect(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1.0))
        let fullFrame = CGSize(width: 600, height: 400)
        let croppedSize = crop.outputSize(fittingFrame: fullFrame)

        let geometry = PreviewImageGeometry(containerSize: croppedSize, imageSize: croppedSize,
                                            zoom: .identity, crop: crop)

        // 残る顔をタップする（画面座標）。
        let tapScreen = geometry.screenPoint(from: keptCenter)
        guard let tapped = geometry.normalizedPoint(from: tapScreen) else {
            XCTFail("クロップ後の画面座標が画像の外と判定された（残るはずの顔が見えていない）")
            return
        }

        // 復元した正規化座標は「残る顔」の中に入り、「消えた顔」には掛からないこと。
        XCTAssertTrue(keptFace.insetBy(dx: -0.01, dy: -0.01).contains(tapped),
                      "クロップ後のタップが、残っているはずの顔を指していない: \(tapped)")
        XCTAssertFalse(culledFace.contains(tapped),
                       "クロップ後のタップが、消えたはずの顔を指してしまっている: \(tapped)")
    }

    // MARK: - クロップ編集中は全面

    func test_クロップ編集中の写真表示は全面() throws {
        let model = makeModel(mode: .photo)
        let image = makeBandedImage()
        model.previewImage = image

        model.setCrop(rightTwoThirds())
        XCTAssertNotEqual(model.croppedPreviewImage?.size, image.size,
                          "テスト前提: 確定済みクロップで表示画像が切れていない")

        model.beginCropEditing()
        XCTAssertEqual(model.croppedPreviewImage?.size, image.size,
                       "クロップ編集中なのに表示画像が切られている（全面で見せる設計に反する）")
        XCTAssertEqual(model.previewGeometryCrop, .full,
                       "クロップ編集中なのに previewGeometryCrop が .full ではない")
        XCTAssertTrue(model.timeline.crop.isFull,
                      "クロップ編集中なのに合成の crop が .full に組み直されていない")

        model.cancelCropEditing()
    }

    // MARK: - 動画モードは二重に掛けない

    func test_動画モードのプレビュー換算はクロップを二重に掛けない() throws {
        let model = makeModel(mode: .video)
        model.timeline = model.timeline.settingCrop(rightTwoThirds())

        XCTAssertEqual(model.previewGeometryCrop, .full,
                       "動画モードなのに previewGeometryCrop が .full ではない" +
                       "（renderLayout で既にクロップ済みの座標系へ、さらに crop を重ねてしまう）")

        // クロップ編集中でも変わらない（編集中はどのみち .full だが、経路の分岐が
        // 「編集中だから」ではなく「動画だから」であることを別々に確かめる）。
        model.cropDraft = rightTwoThirds()
        XCTAssertEqual(model.previewGeometryCrop, .full)
        model.cropDraft = nil
    }

    // MARK: - Helpers（`PhotoRenderPipelineParityTests` と同じ流儀の構造テスト用）

    private func maskMeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaskMeTests
            .deletingLastPathComponent()   // リポジトリ直下
        let dir = root.appendingPathComponent("MaskMe")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("アプリ層が無い環境ではスキップ")
        }
        return dir
    }

    private func strippingComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    private func extractFunctionBody(named name: String, in text: String) -> String? {
        guard let signatureRange = text.range(of: "func \(name)(") else { return nil }
        guard let openBrace = text.range(of: "{", range: signatureRange.upperBound..<text.endIndex) else {
            return nil
        }
        var depth = 0
        var index = openBrace.lowerBound
        var bodyEnd = index
        while index < text.endIndex {
            let ch = text[index]
            if ch == "{" { depth += 1 } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    bodyEnd = index
                    break
                }
            }
            index = text.index(after: index)
        }
        guard depth == 0 else { return nil }
        return String(text[openBrace.lowerBound...bodyEnd])
    }
}

#endif
