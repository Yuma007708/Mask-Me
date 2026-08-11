import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// UI テスト（XCUITest）から**決まった状態でアプリを起動する**ための入口。
///
/// 起動引数 `-uiTestSeedVideo` / `-uiTestSeedPhoto` が付いているときだけ働き、
/// 合成した素材で編集画面へ直行させる（動画は tmp へ書き、写真は画像を直に渡す）。
/// 写真ライブラリから選ばせないのは
///
/// - PHPicker の自動操作が端末・OS 版で揺れる
/// - 素材の中身が環境で変わるとタイムラインの見た目も変わり、座標を指定した
///   ドラッグ（ジェスチャの検証そのもの）が不安定になる
///
/// の 2 つが理由である。**通常起動では `isSeeding` が false なので 1 行も動かない。**
///
/// 生成物は tmp に残して次回起動で再利用する（Simulator の tmp は起動間で残る）。
/// 検出精度には関係しない合成パターンなので、素材としての意味は「尺と絵が時刻で
/// はっきり変わること」だけ。
enum UITestBootstrap {
    /// この引数が付いた起動だけが対象。
    static let seedVideoArgument = "-uiTestSeedVideo"
    static let seedPhotoArgument = "-uiTestSeedPhoto"

    static var isSeedingVideo: Bool {
        ProcessInfo.processInfo.arguments.contains(seedVideoArgument)
    }

    static var isSeedingPhoto: Bool {
        ProcessInfo.processInfo.arguments.contains(seedPhotoArgument)
    }

    /// 種の素材で起動しているか（動画・写真のどちらでも）。
    ///
    /// **初回案内（`OnboardingSheet`）を出さない判定はこちらを使う。** 動画だけを
    /// 見ていると、写真で直行したときに案内が重なって最初のシートで止まる。
    static var isSeeding: Bool { isSeedingVideo || isSeedingPhoto }

    /// タイムラインが画面幅より十分広くなる尺（既定ズーム 40px/秒 で 400px）。
    /// 短すぎるとクリップ帯が狭くて掴めず、長すぎると生成に時間がかかる。
    private static let seedDuration = 10.0
    private static let seedFrameRate: Int32 = 30
    /// 縦動画。アプリの主な用途（スマホで撮った動画）に合わせる。
    private static let seedSize = CGSize(width: 480, height: 854)

    /// 種の動画の URL。無ければ作る。**生成は主スレッドの外で行う。**
    static func seedVideoURL() async -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-seed.mov")
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 0 {
            return url
        }
        return await Task.detached(priority: .userInitiated) { write(to: url) }.value
    }

    /// 種の写真。**ファイルを介さず `UIImage` を直に返す**（写真は `PickedMedia.image`
    /// が画像そのものを受け取るので、動画のように tmp へ書き出す必要が無い）。
    ///
    /// 絵は縦・横で違う色にしてある——写真モードの向き（回転・反転）を目で確かめる
    /// ときに、上下左右が分からない一様な絵だと判断できないため。
    static func seedPhotoImage() -> UIImage {
        let size = seedSize
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: 0.58, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // 上端だけ白帯（上下が分かる）。
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 8))
            // 左端だけ濃い帯（左右が分かる）。
            UIColor.black.withAlphaComponent(0.7).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 8, height: size.height))
        }
    }

    // MARK: - 生成

    private static func write(to url: URL) -> URL? {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(seedSize.width),
            AVVideoHeightKey: Int(seedSize.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let total = Int(seedDuration * Double(seedFrameRate))
        for index in 0..<total {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = makeFrame(index: index, total: total, pool: pool) else { break }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index),
                                                                timescale: seedFrameRate))
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        return writer.status == .completed ? url : nil
    }

    /// 1 フレーム描く。時刻で色相と縦帯の位置を動かし、**どのコマかが絵で分かる**ようにする
    /// （サムネイルが全部同じだと「サムネイルが出ているか」の確認ができない）。
    private static func makeFrame(index: Int, total: Int,
                                  pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        let progress = total > 1 ? Double(index) / Double(total - 1) : 0
        context.setFillColor(UIColor(hue: CGFloat(progress), saturation: 0.6,
                                     brightness: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: seedSize))
        // 左から右へ動く白帯（コマの違いが一目で分かる）。
        let barWidth = seedSize.width / 6
        let barX = (seedSize.width - barWidth) * CGFloat(progress)
        context.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        context.fill(CGRect(x: barX, y: 0, width: barWidth, height: seedSize.height))
        return buffer
    }
}
