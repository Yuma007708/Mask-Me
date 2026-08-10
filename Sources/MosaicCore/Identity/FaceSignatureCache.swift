import CoreGraphics
import Foundation

/// 署名 1 本と、それを作った顔の位置。
///
/// 位置を一緒に持つのが要点。署名を「顔の配列の何番目か」で結び付けると、
/// **顔の並び順が変わった瞬間に別人の署名で判定する**（検出器の出力順はフレーム間で
/// 保証されない）。位置で結び付ければ、並び順にも、どのバケットから顔を引いたかにも
/// 依存しない。
public struct FaceSignatureSample: Sendable, Equatable, Codable {
    /// 素材フレーム基準の正規化重心（`FaceLandmarkSet` 全点の平均）。
    public let centroid: CGPoint
    public let signature: FaceSignature

    public init(centroid: CGPoint, signature: FaceSignature) {
        self.centroid = centroid
        self.signature = signature
    }
}

/// 検出済みの顔に対応する人物署名の置き場。
///
/// **なぜ検出キャッシュと別立てなのか**: `DetectionCacheStore` の値型を変えると、
/// 事前スキャン・ライブ検出・書き出し・下書き復元の全経路が一斉に影響を受ける。
/// 署名は「あれば判定が良くなる」補助情報で、無くても位置追跡へ落ちて動き続けられる
/// ため、別立てにして影響範囲を閉じている。
///
/// **別立ての危険と、その潰し方**: 顔と署名を別々に持つと、対応を取り違えて
/// **別人の署名で判定する**という最悪の事故が起きる（この案件は過去に
/// `detectionCache` と `liveFlowCache` の混入を踏んでいる）。そこで
///
/// - 書き込みは顔と同時にしか行えない形にする（`store(_:for:)` は顔の配列を要求する）
/// - 読み出しは**位置で照合**し、近い署名が無ければその顔は署名なしとして返す
///
/// 対応が付かないときに「署名なし」へ倒すのは、判定がそのまま位置追跡（従来の挙動）へ
/// 落ちるため。誤った署名で「別人だから素のまま」と判断されるより、隠しすぎる方がましである。
public final class FaceSignatureCache {
    private var lookupValue: FaceSignatureLookup
    private let bucketFPS: Double

    public init(bucketFPS: Double = 15.0) {
        self.bucketFPS = bucketFPS
        self.lookupValue = FaceSignatureLookup(samples: [:], bucketFPS: bucketFPS)
    }

    public var count: Int { lookupValue.count }
    public var isEmpty: Bool { lookupValue.isEmpty }

    /// 書き出し（別スレッド）へ渡すための値型スナップショット。
    /// 参照のまま渡すと、書き出し中も再生が署名を書き込み続けて競合する。
    public func lookup() -> FaceSignatureLookup { lookupValue }

    /// 顔と署名を対で書き込む。
    ///
    /// - Parameter signatures: `faces` と**同じ順・同じ件数**。作れなかった顔は nil。
    ///   件数が違う呼び出しは記録しない（壊れた対応を残さない）。
    ///   全て nil のフレームは記録しない（引くものが無いので置く意味がない）。
    public func store(_ signatures: [FaceSignature?], for faces: [FaceLandmarkSet],
                      sourceID: UUID, time: Double) {
        guard signatures.count == faces.count else { return }
        let samples = zip(faces, signatures).compactMap { face, signature -> FaceSignatureSample? in
            guard let signature else { return nil }
            return FaceSignatureSample(centroid: FaceSignatureLookup.centroid(of: face),
                                       signature: signature)
        }
        guard !samples.isEmpty else { return }
        lookupValue.set(samples,
                        for: DetectionCacheKey(sourceID: sourceID, time: time, bucketFPS: bucketFPS))
    }

    /// `lookup()` の同名メソッドへの委譲（呼び出し側の書き味を変えないため）。
    public func signatures(for faces: [FaceLandmarkSet],
                           sourceID: UUID, time: Double,
                           window: Double? = nil) -> [FaceSignature?] {
        lookupValue.signatures(for: faces, sourceID: sourceID, time: time, window: window)
    }

    public func removeAll() {
        lookupValue.removeAll()
    }

    public func removeAll(sourceID: UUID) {
        lookupValue.removeAll(sourceID: sourceID)
    }
}

/// 署名の引き当てだけを行う**値型**。書き出しスレッドへ安全に渡せる。
///
/// 判定の実体はここにある。`FaceSignatureCache` は「書き込める入れ物」であって、
/// 引き当ての規則を二重に書かないようこちらへ委譲している。
public struct FaceSignatureLookup: Sendable, Equatable {
    private var storage: [DetectionCacheKey: [FaceSignatureSample]]
    private let bucketFPS: Double

    /// 顔と署名を同じ人のものとみなす重心の距離（正規化座標）。
    ///
    /// 顔の幅がおよそ 0.2 なので、これは顔 1 つぶんの半分に満たない。狭くすると
    /// 動いている顔で対応が付かず（＝位置追跡へ落ちる。安全側）、広げると隣の人の署名を
    /// 拾いうる（＝危険側）。**暫定値。S6 の実素材計測で詰める。**
    public static let maximumCentroidDistance: CGFloat = 0.08

    /// 署名を探す時間の窓（素材時刻・秒）。署名は間引いて作るので、顔と同じバケットに
    /// 署名があるとは限らない。近傍のバケットまで見に行くための幅。
    /// **暫定値。S6 の実素材計測で詰める。**
    public static let defaultLookupWindow: Double = 0.35

    public init(samples: [DetectionCacheKey: [FaceSignatureSample]], bucketFPS: Double = 15.0) {
        self.storage = samples
        self.bucketFPS = bucketFPS
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    mutating func set(_ samples: [FaceSignatureSample], for key: DetectionCacheKey) {
        storage[key] = samples
    }

    mutating func removeAll() { storage.removeAll() }

    mutating func removeAll(sourceID: UUID) {
        storage = storage.filter { $0.key.sourceID != sourceID }
    }

    /// `faces` に対応する署名を返す（`faces` と同じ順・同じ件数）。
    ///
    /// `time` から `window` 秒以内で**最も近いバケット** 1 つを選び、そのバケットの
    /// サンプルを重心の近さで顔へ割り当てる。1 つのサンプルは 1 つの顔にしか使わない
    /// （近い順に確定させる。使い回すと 2 人が同じ人だと判定される）。
    /// 対応が付かなかった顔は nil。
    ///
    /// **顔をどのバケットから引いたかを問わない**のが設計上の肝。プレビューも書き出しも
    /// `DetectionBridge` が前後バケットを補間した顔を扱うため、「顔と同じバケットの
    /// 署名を同じ添字で取る」という素朴な対応は成立しない。
    public func signatures(for faces: [FaceLandmarkSet],
                           sourceID: UUID, time: Double,
                           window: Double? = nil) -> [FaceSignature?] {
        var result = [FaceSignature?](repeating: nil, count: faces.count)
        guard !faces.isEmpty,
              let samples = nearestSamples(sourceID: sourceID, time: time,
                                           window: window ?? Self.defaultLookupWindow)
        else { return result }

        // (顔, サンプル) の全組み合わせを距離順に見て、近い方から確定させる。
        // 顔もサンプルも 1 フレームに数個なので総当たりで足りる。
        struct Pair { let distance: CGFloat; let face: Int; let sample: Int }
        var pairs: [Pair] = []
        for (i, face) in faces.enumerated() {
            let fc = Self.centroid(of: face)
            for (j, sample) in samples.enumerated() {
                let d = hypot(fc.x - sample.centroid.x, fc.y - sample.centroid.y)
                if d < Self.maximumCentroidDistance {
                    pairs.append(Pair(distance: d, face: i, sample: j))
                }
            }
        }
        var usedSamples = Set<Int>()
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) {
            guard result[pair.face] == nil, !usedSamples.contains(pair.sample) else { continue }
            result[pair.face] = samples[pair.sample].signature
            usedSamples.insert(pair.sample)
        }
        return result
    }

    /// `time` から `window` 秒以内で最も近いバケットのサンプル。無ければ nil。
    private func nearestSamples(sourceID: UUID, time: Double,
                                window: Double) -> [FaceSignatureSample]? {
        // 窓はバケット半分を下限にする。`time` は丸める前の素材時刻なので、
        // 「同じバケット」でもバケット中心から最大半バケットずれる。ここを詰めると
        // 同じバケットの署名すら引けなくなる。
        let effective = max(window, 0.5 / bucketFPS)
        var best: (distance: Double, samples: [FaceSignatureSample])?
        for (key, samples) in storage where key.sourceID == sourceID {
            let d = abs(key.bucket - time)
            if d > effective { continue }
            if best == nil || d < best!.distance { best = (d, samples) }
        }
        return best?.samples
    }

    /// 正規化座標での全ランドマーク重心。`SelectedFaceTracker.centroid(of:)` と同じ定義。
    static func centroid(of face: FaceLandmarkSet) -> CGPoint {
        SelectedFaceTracker.centroid(of: face)
    }
}
