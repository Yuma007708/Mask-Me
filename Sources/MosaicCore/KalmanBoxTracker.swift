import CoreGraphics
import Foundation

/// 顔 bbox の中心と寸法を等速度モデルで追跡する 6 状態 Kalman フィルタ。
///
/// 状態ベクトル: `(cx, cy, w, h, vx, vy)`
/// 観測ベクトル: `(cx, cy, w, h)`（w, h の速度はモデル化しない）
///
/// `MediaPipeFaceLandmarkerAdapter.redetectFromTrackedBoxes` で、前フレームの
/// bbox 位置を「速度から予測した次フレーム位置」に置き換えるために使う。
/// 速い頭部運動・パン中でも ROI が顔から外れず、tiled 全滅リカバリ（10-45f 遅延）
/// を Kalman 予測位置での ROI 再検出に短縮する。
///
/// 行列演算ではなく対角近似（各成分独立）で実装しているため計算量は O(1) の加算のみ。
/// MediaPipe / OpenCV への依存なしにユニットテスト可能。
public struct KalmanBoxTracker: Sendable {
    // MARK: 状態（正規化座標）
    public private(set) var cx: Double
    public private(set) var cy: Double
    public private(set) var w: Double
    public private(set) var h: Double
    public private(set) var vx: Double
    public private(set) var vy: Double

    // MARK: 共分散の対角要素
    private var pCx: Double
    private var pCy: Double
    private var pW: Double
    private var pH: Double
    private var pVx: Double
    private var pVy: Double

    // MARK: パラメータ
    private let processNoisePos: Double
    private let processNoiseSize: Double
    private let processNoiseVel: Double
    private let measurementNoisePos: Double
    private let measurementNoiseSize: Double

    public init(
        initialBox: CGRect,
        processNoisePos: Double = 1e-4,
        processNoiseSize: Double = 1e-5,
        processNoiseVel: Double = 1e-3,
        measurementNoisePos: Double = 1e-3,
        measurementNoiseSize: Double = 1e-3
    ) {
        self.cx = Double(initialBox.midX)
        self.cy = Double(initialBox.midY)
        self.w = Double(initialBox.width)
        self.h = Double(initialBox.height)
        self.vx = 0
        self.vy = 0
        // 初期共分散: 位置・寸法は観測相当、速度は未知（大きめ）で開始する。
        self.pCx = measurementNoisePos
        self.pCy = measurementNoisePos
        self.pW = measurementNoiseSize
        self.pH = measurementNoiseSize
        self.pVx = 1.0
        self.pVy = 1.0
        self.processNoisePos = processNoisePos
        self.processNoiseSize = processNoiseSize
        self.processNoiseVel = processNoiseVel
        self.measurementNoisePos = measurementNoisePos
        self.measurementNoiseSize = measurementNoiseSize
    }

    /// Predict 1 ステップ進める。`dt` は「1 検出フレーム」を単位とする（0.033s ではない）。
    /// 検出間隔が飛んだフレームで dt=数フレームを渡せば予測はそのぶん先へ進む。
    public mutating func predict(dt: Double = 1.0) {
        cx += vx * dt
        cy += vy * dt
        let dt2 = dt * dt
        pCx += processNoisePos * dt2
        pCy += processNoisePos * dt2
        pW  += processNoiseSize * dt2
        pH  += processNoiseSize * dt2
        pVx += processNoiseVel * dt2
        pVy += processNoiseVel * dt2
    }

    /// 観測（新しい bbox）でフィルタを更新する。
    public mutating func update(observation box: CGRect) {
        let zCx = Double(box.midX)
        let zCy = Double(box.midY)
        let zW  = Double(box.width)
        let zH  = Double(box.height)

        // cx: 位置更新に加えて「観測位置と予測位置の差」で速度も取り込む。
        let kCx = pCx / (pCx + measurementNoisePos)
        let innovX = zCx - cx
        cx += kCx * innovX
        vx += kCx * (innovX - vx)
        pCx *= (1 - kCx)
        pVx *= (1 - kCx)

        // cy
        let kCy = pCy / (pCy + measurementNoisePos)
        let innovY = zCy - cy
        cy += kCy * innovY
        vy += kCy * (innovY - vy)
        pCy *= (1 - kCy)
        pVy *= (1 - kCy)

        // w
        let kW = pW / (pW + measurementNoiseSize)
        w += kW * (zW - w)
        pW *= (1 - kW)

        // h
        let kH = pH / (pH + measurementNoiseSize)
        h += kH * (zH - h)
        pH *= (1 - kH)
    }

    /// 予測された正規化 bbox を [0, 1] 内でクランプして返す。
    /// 中心±半幅が画面外に出る場合は、辺を [0, 1] に切り詰めて幅を縮める。
    public var predictedBox: CGRect {
        let clampedW = max(0.0, min(1.0, w))
        let clampedH = max(0.0, min(1.0, h))
        let clampedCx = max(0.0, min(1.0, cx))
        let clampedCy = max(0.0, min(1.0, cy))
        let minX = max(0.0, clampedCx - clampedW / 2)
        let minY = max(0.0, clampedCy - clampedH / 2)
        let maxX = min(1.0, clampedCx + clampedW / 2)
        let maxY = min(1.0, clampedCy + clampedH / 2)
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    /// 現在の推定速度の絶対値（正規化座標 / 検出フレーム）。
    /// 0.05 で「フレームあたり画面 5% 移動中」。ROI 拡大倍率を 2.0〜3.5 に連動させる。
    public var speedMagnitude: CGFloat {
        CGFloat((vx * vx + vy * vy).squareRoot())
    }
}
