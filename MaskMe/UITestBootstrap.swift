import AVFoundation
import CoreGraphics
import Foundation
import UIKit

/// UI テスト（XCUITest）から**決まった状態でアプリを起動する**ための入口。
///
/// 起動引数 `-uiTestSeedVideo` が付いているときだけ働き、合成した動画 1 本を tmp へ
/// 書いて編集画面へ直行させる。写真ライブラリから選ばせないのは
///
/// - PHPicker の自動操作が端末・OS 版で揺れる
/// - 素材の中身が環境で変わるとタイムラインの見た目も変わり、座標を指定した
///   ドラッグ（ジェスチャの検証そのもの）が不安定になる
///
/// の 2 つが理由である。**通常起動では `isSeedingVideo` が false なので 1 行も動かない。**
///
/// 生成物は tmp に残して次回起動で再利用する（Simulator の tmp は起動間で残る）。
/// 検出精度には関係しない合成パターンなので、素材としての意味は「尺と絵が時刻で
/// はっきり変わること」だけ。
enum UITestBootstrap {
    /// この引数が付いた起動だけが対象。
    static let seedVideoArgument = "-uiTestSeedVideo"

    static var isSeedingVideo: Bool {
        ProcessInfo.processInfo.arguments.contains(seedVideoArgument)
    }

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
