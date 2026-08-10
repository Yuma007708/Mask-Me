import CoreGraphics
import Foundation

/// クリップに掛ける 90 度単位の回転量（**時計回りの度数**）。
///
/// 上下反転を持たないのは意図的（一般的な編集アプリでも二軍の操作なので入れない）。
/// 上下反転が要るなら「左右反転 + 180 度回転」で表現できる。
public enum ClipRotation: Int, Codable, Sendable, CaseIterable, Hashable {
    case none = 0
    /// 時計回りに 90 度（素材の左上が右上へ来る）。
    case right90 = 90
    case half = 180
    /// 反時計回りに 90 度（= 時計回りに 270 度）。
    case left90 = 270

    /// 任意の度数を 4 状態へ畳む。非有限・端数は最も近い 90 度へ丸めてから畳む。
    ///
    /// **下書きの復元でここを通す。** 手で書き換えられた JSON や将来のスキーマ変更で
    /// 45 度や -90 度が入っても、デコードを失敗させずに（＝下書きが開けなくなるのを
    /// 避けて）4 状態のどれかへ落とす。
    public static func folded(degrees: Double) -> ClipRotation {
        guard degrees.isFinite else { return .none }
        let quarters = (degrees / 90).rounded()
        guard quarters.isFinite, abs(quarters) < 1e9 else { return .none }
        let normalized = ((Int(quarters) % 4) + 4) % 4
        return ClipRotation(rawValue: normalized * 90) ?? .none
    }

    /// 時計回りに 90 度足した状態。
    public var rotatedRight: ClipRotation { Self.folded(degrees: Double(rawValue + 90)) }
    /// 反時計回りに 90 度回した状態。
    public var rotatedLeft: ClipRotation { Self.folded(degrees: Double(rawValue - 90)) }
    /// 逆回転（この回転を打ち消す回転）。
    public var inverted: ClipRotation { Self.folded(degrees: Double(-rawValue)) }
    /// 縦横が入れ替わるか（90 / 270 度）。
    public var swapsDimensions: Bool { self == .right90 || self == .left90 }
    /// ラジアン（時計回り正）。
    public var radians: Double { Double(rawValue) * .pi / 180 }
}

/// クリップ単位の向き変換（90 度単位の回転 + 左右反転）。
///
/// ## 正準形（この 1 行がすべての基準）
///
/// 変換は必ず **`回転(rotation) ∘ 左右反転(isMirrored)`** の順で適用する。
/// つまり素材へ先に左右反転を掛け、その結果を回転させる。順序を型の中に固定して
/// おかないと、「映像に掛けた順序」と「モザイク座標に掛けた順序」が食い違い、
/// **顔が素通しになる**（このアプリで最も重い事故）。
///
/// ## 画面で見た操作 → 正準形の書き換え
///
/// ユーザーが押すのは「左に回す」「右に回す」「左右反転」の 3 つで、どれも
/// **画面で見たとおりに効く**必要がある。回転は正準形の外側に積むだけなので
/// `rotation` を足し引きすれば済むが、左右反転は違う。画面の左右反転 H を外側から
/// 掛けると `H ∘ R(θ) ∘ M = R(-θ) ∘ (H ∘ M)` へ書き換わる（反射で回転の向きが
/// 裏返る）。したがって `flippedHorizontally()` は **反転を切り替えると同時に
/// 回転を逆向きにする**。ここを「`isMirrored` を反転するだけ」に書き換えると、
/// 90 度回した状態で反転ボタンが上下反転として効く。
///
/// ## 座標変換は 2 系統あり、必ず一致していなければならない
///
/// - `map(_:)` / `map(rect:)` … **正規化座標**（[0,1]×[0,1]・左上原点・y 下向き）。
///   顔ランドマークと矩形モザイクがここを通る。
/// - `transform(sourceSize:)` … **ピクセル座標**の `CGAffineTransform`。
///   映像（`AVMutableVideoCompositionLayerInstruction`）がここを通る。
///
/// この 2 つが同じ写像であることは `ClipOrientationTests` が全 8 状態 × 代表点で
/// 突き合わせて固定している。**片方だけを書き換えないこと。**
public struct ClipOrientation: Hashable, Sendable {
    /// 時計回りの回転量（正準形の外側）。
    public var rotation: ClipRotation
    /// 素材に対する左右反転（正準形の内側）。
    public var isMirrored: Bool

    public init(rotation: ClipRotation = .none, isMirrored: Bool = false) {
        self.rotation = rotation
        self.isMirrored = isMirrored
    }

    /// 無変換。
    public static let identity = ClipOrientation()

    /// 無変換か（恒等写像として扱ってよいか）。
    public var isIdentity: Bool { rotation == .none && !isMirrored }

    /// 縦横が入れ替わるか。反転は縦横を替えないので回転だけで決まる。
    public var swapsDimensions: Bool { rotation.swapsDimensions }

    // MARK: - 画面で見た操作

    /// 画面で見て反時計回りに 90 度。
    public func rotatedLeft() -> ClipOrientation {
        ClipOrientation(rotation: rotation.rotatedLeft, isMirrored: isMirrored)
    }

    /// 画面で見て時計回りに 90 度。
    public func rotatedRight() -> ClipOrientation {
        ClipOrientation(rotation: rotation.rotatedRight, isMirrored: isMirrored)
    }

    /// 画面で見て左右反転。**回転も逆向きにする**（型 doc の「正準形の書き換え」参照）。
    public func flippedHorizontally() -> ClipOrientation {
        ClipOrientation(rotation: rotation.inverted, isMirrored: !isMirrored)
    }

    /// 逆変換（`inverse.map(self.map(p)) == p`）。
    ///
    /// 反転を含む向きは**それ自身が逆変換**になる（`R(θ)∘H` は対合）。
    /// 反転が無ければ逆回転。
    public var inverted: ClipOrientation {
        isMirrored ? self : ClipOrientation(rotation: rotation.inverted, isMirrored: false)
    }

    // MARK: - サイズ

    /// この向きを掛けた後の表示サイズ（90 / 270 度で縦横が入れ替わる）。
    public func displaySize(_ size: CGSize) -> CGSize {
        swapsDimensions ? CGSize(width: size.height, height: size.width) : size
    }

    // MARK: - 正規化座標の写像

    /// 正規化座標（左上原点・y 下向き）の点を、この向きを掛けた後の正規化座標へ写す。
    ///
    /// 単位正方形 → 単位正方形の写像なので、素材の縦横比に依存しない
    /// （正規化座標は軸ごとに独立して伸縮するため、90 度回転では縦横の成分が
    /// そのまま入れ替わる）。
    public func map(_ point: CGPoint) -> CGPoint {
        let x = isMirrored ? 1 - point.x : point.x
        let y = point.y
        switch rotation {
        case .none: return CGPoint(x: x, y: y)
        case .right90: return CGPoint(x: 1 - y, y: x)
        case .half: return CGPoint(x: 1 - x, y: 1 - y)
        case .left90: return CGPoint(x: y, y: 1 - x)
        }
    }

    /// 正規化矩形を写す。90 度回転では幅と高さが入れ替わる。
    ///
    /// 角を 2 点写して外接矩形を取る。90 度単位の写像は軸を保つので、
    /// 外接矩形は近似ではなく**厳密に**元の矩形の像である。
    public func map(_ rect: CGRect) -> CGRect {
        guard !isIdentity else { return rect }
        let standardized = rect.standardized
        let a = map(CGPoint(x: standardized.minX, y: standardized.minY))
        let b = map(CGPoint(x: standardized.maxX, y: standardized.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// `map(_:)` の逆写像（合成側の正規化座標 → 素材側の正規化座標）。
    public func inverseMap(_ point: CGPoint) -> CGPoint { inverted.map(point) }

    /// `map(_:)` の逆写像（矩形）。
    public func inverseMap(_ rect: CGRect) -> CGRect { inverted.map(rect) }

    // MARK: - 角度の写像

    /// **ピクセル空間での**傾き（ラジアン・時計回り）を写す。
    ///
    /// 矩形モザイク（`ObjectMask.Keyframe.angle`）が持つ角度に使う。
    ///
    /// **回転を足してはならない。** 矩形は「軸平行の正規化 rect ＋ 中心まわりの角度」で
    /// 表され、描画（`FaceMaskBuilder.rectPath`）は `rect × 表示サイズ` のピクセル矩形を
    /// 中心で `angle` だけ回す。90 度回転ぶんの形の変化は、すでに **`map(_ rect:)` の側**が
    /// 担っている——`map` は正規化の幅と高さを入れ替え、表示フレームの縦横も入れ替わるので、
    /// 得られるピクセル矩形は最初から倒れた姿になっている。そこへ `+ rotation.radians` を
    /// 足すと**二重に回り**、90/270 度で形が 90 度違ってしまう（横長の矩形が縦長になる）。
    ///
    /// 実測（素材 640×360、正規化 rect 0.20×0.10 ＝ 128×36px の横長を右 90 度）:
    /// 正しい姿は 36×128 の縦長。回転を足した実装は 128×36 のまま横長で描く。
    /// **顔を隠すために置いた横長の矩形が縦長になり、顔の左右がはみ出す。**
    /// 既定の `angle == 0`（ドラッグで置いた普通の矩形）でも起きる。
    ///
    /// 一方 **左右反転は角度に効く**。鏡映は回る向きを裏返すので符号を反転する。
    /// これは `map(_ rect:)` 側には現れない（鏡映しても軸平行 rect の幅と高さは不変）。
    /// 180 度は矩形の 180 度対称性で角度に影響しない。
    public func mapAngle(_ angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        return ObjectMask.normalizedAngle(isMirrored ? -angle : angle)
    }

    /// `mapAngle(_:)` の逆写像。
    public func inverseMapAngle(_ angle: Double) -> Double { inverted.mapAngle(angle) }

    // MARK: - ピクセル空間のアフィン変換（映像側）

    /// 素材フレーム（`sourceSize`・左上原点・y 下向き）を、この向きを掛けた
    /// 表示フレーム（`displaySize(sourceSize)`）へ写すアフィン変換。
    ///
    /// **`AVMutableVideoCompositionLayerInstruction.setTransform` の座標系はこの
    /// 左上原点・y 下向きであり、正の回転角が画面上の時計回りに対応する**
    /// （縦動画の `preferredTransform` が `translate(h,0) * rotate(+π/2)` になる
    /// のと同じ約束）。だから `map(_:)` と同じ向きの回転をそのまま使える。
    ///
    /// 原点合わせは `VideoCompositionFactory.fitTransform` と同じ手口
    /// （変換後の外接矩形の左上を 0 へ寄せる）。符号の場合分けを書かないので、
    /// 回転の向きを取り違えても左上合わせだけは必ず成立する。
    public func transform(sourceSize: CGSize) -> CGAffineTransform {
        guard !isIdentity else { return .identity }
        var base = CGAffineTransform.identity
        if isMirrored {
            base = CGAffineTransform(scaleX: -1, y: 1)
        }
        let rotated = base.concatenating(CGAffineTransform(rotationAngle: CGFloat(rotation.radians)))
        let bounds = CGRect(origin: .zero, size: sourceSize).applying(rotated)
        return rotated.concatenating(
            CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    }
}

// MARK: - Codable（下書き互換）

extension ClipOrientation: Codable {
    private enum CodingKeys: String, CodingKey { case rotation, isMirrored }

    /// **デコードで失敗しない。** 壊れた値は「無変換」へ倒す。
    ///
    /// 向きは下書きの一要素でしかないので、ここで throw すると下書きが丸ごと
    /// 開けなくなる（`ObjectMask.Keyframe.angle` と同じ移行規約）。
    ///
    /// **`Int` で読んではならない。** 書き出すのは常に整数だが、読む側が `Int` だと
    /// `{"rotation": 90.5}` や桁あふれした数値で `JSONDecoder` が
    /// 「Number 90.5 is not representable in Swift」を投げ、`TimelineClip` ごと
    /// デコードが失敗する。`DraftStore` は下書きを 1 件ずつ隔離して読むので一覧全体は
    /// 生き残るが、**そのクリップを含む動画プロジェクト 1 本が丸ごと nil になり、
    /// 次の保存で一覧から静かに消える**（この doc が防ごうとしていた事故そのもの）。
    /// `Double` で受ければ `folded(degrees:)` が非有限も巨大値も安全に畳む。
    /// 型が違う（文字列など）ときも `decodeIfPresent` の失敗を握り潰して無変換へ倒す。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let degrees: Double? = try? container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        rotation = ClipRotation.folded(degrees: degrees ?? 0)
        let mirrored: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .isMirrored) ?? false
        isMirrored = mirrored ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rotation.rawValue, forKey: .rotation)
        try container.encode(isMirrored, forKey: .isMirrored)
    }
}

// MARK: - 顔ランドマーク

extension FaceLandmarkSet {
    /// 正規化ランドマークにクリップの向きを掛ける。
    ///
    /// **素材にだけ向きを掛けてここを呼び忘れると顔が素通しになる。**
    /// 呼び出しは `TimelineRenderLayout.remap(_:clipID:)` の 1 箇所に閉じてある。
    public func oriented(_ orientation: ClipOrientation) -> FaceLandmarkSet {
        guard !orientation.isIdentity else { return self }
        let mapped = points.map { landmark -> FaceLandmark in
            let point = orientation.map(CGPoint(x: CGFloat(landmark.x), y: CGFloat(landmark.y)))
            return FaceLandmark(x: Float(point.x), y: Float(point.y), z: landmark.z)
        }
        return FaceLandmarkSet(points: mapped, confidence: confidence)
    }
}
