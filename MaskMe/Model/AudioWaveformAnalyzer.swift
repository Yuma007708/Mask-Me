import AVFoundation
import Foundation
import MosaicCore

/// 素材の音声トラックを読み、`AudioWaveform.peaksPerSecond` の粒度でピークへ縮約する。
///
/// **`TimelineWaveformStore`（波形表示）と BGM ダッキングの検出（`MosaicEditorModel+Ducking`）が
/// 同じ実装を呼ぶ唯一の場所。** 別々に実装すると、画面に出る波形と実際に検出へ使う波形が
/// 食い違い得る（読み取り設定・打ち切り秒数・端数の持ち越し方が 1 箇所でもずれると、
/// 「波形では鳴っているように見えるのに検出されない」が起き得る）。新しい解析経路を
/// 足すときは必ずここを呼ぶこと。
enum AudioWaveformAnalyzer {
    /// 解析を打ち切る素材尺（秒）。**これを超える素材は先頭ぶんだけ**波形を出す。
    ///
    /// 10 分の素材で 60,000 ピーク（約 240KB）。長尺で青天井にしないための歯止めで、
    /// 超えたぶんは波形が出ないだけ（帯とモザイクは通常どおり動く）。
    static let analysisLimitSeconds: Double = 600

    /// **失敗はすべて「無音」に倒す**（音声トラックが無い写真クリップ、読み取り不能、
    /// 途中で落ちた場合）。波形は補助表示・検出の材料であって必須経路ではないので、
    /// ここで throw して呼び出し側にエラー処理を強いる方が実害に対して割に合わない。
    static func analyze(asset: AVAsset) async -> AudioWaveform {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return .silent }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration.isFinite, duration > 0 else { return .silent }

        // 16bit 整数・モノラルへ落として読む（波形に位相もステレオ分離も要らない）。
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return .silent }
        reader.add(output)
        let limit = min(duration, analysisLimitSeconds)
        reader.timeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: limit, preferredTimescale: 600))
        guard reader.startReading() else { return .silent }

        let sampleRate = (try? await track.load(.naturalTimeScale)).map { Double($0) } ?? 44_100
        let framesPerPeak = max(1, Int(sampleRate / AudioWaveform.peaksPerSecond))
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(limit * AudioWaveform.peaksPerSecond) + 1)
        var currentMax: Int16 = 0
        var framesInCurrent = 0

        while let buffer = output.copyNextSampleBuffer() {
            reduce(buffer, framesPerPeak: framesPerPeak, peaks: &peaks,
                   currentMax: &currentMax, framesInCurrent: &framesInCurrent)
        }
        if framesInCurrent > 0 { peaks.append(Float(currentMax) / Float(Int16.max)) }
        guard reader.status == .completed || reader.status == .reading else { return .silent }
        return AudioWaveform(peaks: peaks, sourceDuration: limit)
    }

    /// 1 バッファぶんの PCM をピークへ畳み込む。
    ///
    /// 端数（`framesInCurrent`）はバッファをまたいで持ち越す。バッファ境界で
    /// 切り上げると、境界のたびに短いピークが 1 個増えて波形が素材時刻から少しずつずれる。
    private static func reduce(_ buffer: CMSampleBuffer, framesPerPeak: Int,
                               peaks: inout [Float], currentMax: inout Int16,
                               framesInCurrent: inout Int) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let raw = pointer else { return }
        let sampleCount = totalLength / 2
        raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
            for index in 0..<sampleCount {
                // **`abs` を使わない。** Int16.min は絶対値が Int16 に収まらず
                // オーバーフローで落ちる（無音に近い素材でも実際に出る値）。
                let sample = samples[index]
                let magnitude = sample == Int16.min ? Int16.max : (sample < 0 ? -sample : sample)
                if magnitude > currentMax { currentMax = magnitude }
                framesInCurrent += 1
                if framesInCurrent >= framesPerPeak {
                    peaks.append(Float(currentMax) / Float(Int16.max))
                    currentMax = 0
                    framesInCurrent = 0
                }
            }
        }
    }
}
