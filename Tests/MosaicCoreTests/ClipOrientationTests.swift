import CoreGraphics
import XCTest
@testable import MosaicCore

/// クリップの回転・左右反転の**座標系**を固定するテスト。
///
/// このアプリで最も重い事故は「素材だけ回してモザイクを回し忘れ、顔が素通しになる」
/// ことなので、ここでは 3 つを別々に固定する:
///
/// 1. 操作の意味（画面で見た左右反転・回転が、正準形の書き換えとして正しいか）
/// 2. 映像のピクセル変換とモザイクの正規化写像が**同じ写像**か
/// 3. 顔ランドマーク・矩形・角度が素材と一緒に回るか（レターボックス併用も含む）
final class ClipOrientationTests: XCTestCase {
    // 全 8 状態（回転 4 × 反転 2）。
    // 別ファイルの extension（`ClipOrientationAdversarialTests.swift`）から使うため internal。
    let allOrientations: [ClipOrientation] = ClipRotation.allCases.flatMap { rotation in
        [ClipOrientation(rotation: rotation, isMirrored: false),
         ClipOrientation(rotation: rotation, isMirrored: true)]
    }

    // 別ファイルの extension（`ClipOrientationAdversarialTests.swift`）から使うため internal。
    let samplePoints: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
        CGPoint(x: 0.25, y: 0.1), CGPoint(x: 0.8, y: 0.55), CGPoint(x: 0.5, y: 0.5)
    ]

    // MARK: - 1. 操作の意味

    func test_右回転は画面上で時計回りに90度回る() {
        // 画面で見た時計回り: (x, y) → (1 - y, x)。
        for orientation in allOrientations {
            for point in samplePoints {
                let expected = clockwise(orientation.map(point))
                assertEqual(orientation.rotatedRight().map(point), expected,
                            "\(orientation) \(point)")
            }
        }
    }

    func test_左回転は右回転の逆() {
        for orientation in allOrientations {
            XCTAssertEqual(orientation.rotatedLeft().rotatedRight(), orientation)
            XCTAssertEqual(orientation.rotatedRight().rotatedLeft(), orientation)
        }
    }

    func test_右回転4回で元に戻る() {
        for orientation in allOrientations {
            XCTAssertEqual(
                orientation.rotatedRight().rotatedRight().rotatedRight().rotatedRight(),
                orientation)
        }
    }

    /// **回転した状態でも「左右反転」は画面の左右で効く。**
    /// `isMirrored` を切り替えるだけの実装だと、90 度回した状態で上下反転になる。
    func test_左右反転は回転していても画面の左右で効く() {
        for orientation in allOrientations {
            for point in samplePoints {
                let onScreen = orientation.map(point)
                let expected = CGPoint(x: 1 - onScreen.x, y: onScreen.y)
                assertEqual(orientation.flippedHorizontally().map(point), expected,
                            "\(orientation) \(point)")
            }
        }
    }

    func test_左右反転2回で元に戻る() {
        for orientation in allOrientations {
            XCTAssertEqual(orientation.flippedHorizontally().flippedHorizontally(), orientation)
        }
    }

    func test_逆変換で往復する() {
        for orientation in allOrientations {
            for point in samplePoints {
                assertEqual(orientation.inverseMap(orientation.map(point)), point,
                            "\(orientation) \(point)")
            }
        }
    }

    func test_90度回転で縦横が入れ替わる() {
        let size = CGSize(width: 640, height: 480)
        XCTAssertEqual(ClipOrientation(rotation: .right90).displaySize(size),
                       CGSize(width: 480, height: 640))
        XCTAssertEqual(ClipOrientation(rotation: .left90).displaySize(size),
                       CGSize(width: 480, height: 640))
        XCTAssertEqual(ClipOrientation(rotation: .half).displaySize(size), size)
        XCTAssertEqual(ClipOrientation(rotation: .none, isMirrored: true).displaySize(size), size)
    }

    // MARK: - 2. 映像のピクセル変換とモザイクの正規化写像の一致

    /// **これが「顔が素通しにならない」ことの根拠**。
    /// 映像レイヤに掛けるアフィン変換（`ClipOrientation.transform(sourceSize:)`）で
    /// 写したピクセル位置と、モザイク座標に掛ける正規化写像（`map`）が一致する。
    func test_映像のアフィン変換とモザイクの正規化写像が一致する() {
        let source = CGSize(width: 640, height: 360)
        for orientation in allOrientations {
            let transform = orientation.transform(sourceSize: source)
            let display = orientation.displaySize(source)
            for point in samplePoints {
                let pixel = CGPoint(x: point.x * source.width, y: point.y * source.height)
                let moved = pixel.applying(transform)
                let normalized = CGPoint(x: moved.x / display.width, y: moved.y / display.height)
                assertEqual(normalized, orientation.map(point), "\(orientation) \(point)")
            }
        }
    }

    /// レターボックス（配置矩形）を挟んでも一致する。
    /// 映像側の `VideoCompositionFactory.fitTransform` はこの `ClipRenderTransform` を
    /// 呼ぶだけなので、ここが一致すれば書き出しの映像とモザイクが一致する。
    func test_レターボックス込みでも映像とモザイクの写像が一致する() {
        let display = CGSize(width: 640, height: 360)
        let renderSize = CGSize(width: 480, height: 640)
        let clipID = UUID()
        for orientation in allOrientations {
            let placement = AspectFit.placement(of: orientation.displaySize(display),
                                                in: renderSize)
            let layout = TimelineRenderLayout(placements: [clipID: placement],
                                              orientations: [clipID: orientation])
            let transform = ClipRenderTransform.make(displaySize: display,
                                                     orientation: orientation,
                                                     placement: placement,
                                                     renderSize: renderSize)
            for point in samplePoints {
                let pixel = CGPoint(x: point.x * display.width, y: point.y * display.height)
                let moved = pixel.applying(transform)
                let viaPixels = CGPoint(x: moved.x / renderSize.width,
                                        y: moved.y / renderSize.height)
                let viaLayout = layout.remap([landmarkSet(at: point)], clipID: clipID)[0].points[0]
                assertEqual(CGPoint(x: CGFloat(viaLayout.x), y: CGFloat(viaLayout.y)),
                            viaPixels, "\(orientation) \(point)", accuracy: 1e-5)
            }
        }
    }

    // MARK: - 3. モザイクが素材と一緒に回る／反転する

    func test_右回転で顔ランドマークが素材と一緒に回る() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(
            placements: [:], orientations: [clipID: ClipOrientation(rotation: .right90)])
        // 素材の左上（0.1, 0.2）にある顔は、時計回り 90 度で右上（0.8, 0.1）へ動く。
        let moved = layout.remap([landmarkSet(at: CGPoint(x: 0.1, y: 0.2))], clipID: clipID)[0]
        XCTAssertEqual(moved.points[0].x, 0.8, accuracy: 1e-5)
        XCTAssertEqual(moved.points[0].y, 0.1, accuracy: 1e-5)
    }

    func test_左右反転で顔ランドマークが素材と一緒に反転する() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(
            placements: [:], orientations: [clipID: ClipOrientation(isMirrored: true)])
        let moved = layout.remap([landmarkSet(at: CGPoint(x: 0.1, y: 0.2))], clipID: clipID)[0]
        XCTAssertEqual(moved.points[0].x, 0.9, accuracy: 1e-5)
        XCTAssertEqual(moved.points[0].y, 0.2, accuracy: 1e-5)
    }

    func test_右回転で矩形モザイクが素材と一緒に回る() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(
            placements: [:], orientations: [clipID: ClipOrientation(rotation: .right90)])
        // 素材の左上寄りの横長矩形は、時計回り 90 度で右上寄りの縦長矩形になる。
        let source = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1)
        let mapped = layout.remap(source, clipID: clipID)
        assertEqual(CGPoint(x: mapped.minX, y: mapped.minY), CGPoint(x: 0.7, y: 0.1))
        XCTAssertEqual(mapped.width, 0.1, accuracy: 1e-9)
        XCTAssertEqual(mapped.height, 0.4, accuracy: 1e-9)
    }

    func test_左右反転で矩形モザイクが素材と一緒に反転する() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(
            placements: [:], orientations: [clipID: ClipOrientation(isMirrored: true)])
        let mapped = layout.remap(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1), clipID: clipID)
        assertEqual(CGPoint(x: mapped.minX, y: mapped.minY), CGPoint(x: 0.5, y: 0.2))
        XCTAssertEqual(mapped.width, 0.4, accuracy: 1e-9)
        XCTAssertEqual(mapped.height, 0.1, accuracy: 1e-9)
    }

    /// 顔と矩形が**同じ**写像を通ること（片方だけ回ると、矩形で隠したはずの顔がずれる）。
    func test_顔と矩形が同じ写像を通る() {
        let clipID = UUID()
        for orientation in allOrientations {
            let layout = TimelineRenderLayout(placements: [:],
                                              orientations: [clipID: orientation])
            for point in samplePoints {
                let face = layout.remap([landmarkSet(at: point)], clipID: clipID)[0].points[0]
                let rect = layout.remap(CGRect(x: point.x, y: point.y, width: 0, height: 0),
                                        clipID: clipID)
                assertEqual(CGPoint(x: CGFloat(face.x), y: CGFloat(face.y)),
                            CGPoint(x: rect.minX, y: rect.minY),
                            "\(orientation) \(point)", accuracy: 1e-5)
            }
        }
    }

    func test_矩形の逆写像で往復する() {
        let clipID = UUID()
        let display = CGSize(width: 640, height: 360)
        let renderSize = CGSize(width: 480, height: 640)
        let source = CGRect(x: 0.2, y: 0.3, width: 0.25, height: 0.15)
        for orientation in allOrientations {
            let placement = AspectFit.placement(of: orientation.displaySize(display),
                                                in: renderSize)
            let layout = TimelineRenderLayout(placements: [clipID: placement],
                                              orientations: [clipID: orientation])
            let composed = layout.remap(source, clipID: clipID)
            let back = layout.inverseRemap(composed, clipID: clipID)
            XCTAssertNotNil(back, "\(orientation)")
            guard let back else { continue }
            assertEqual(CGPoint(x: back.minX, y: back.minY),
                        CGPoint(x: source.minX, y: source.minY), "\(orientation)", accuracy: 1e-5)
            XCTAssertEqual(back.width, source.width, accuracy: 1e-5, "\(orientation)")
            XCTAssertEqual(back.height, source.height, accuracy: 1e-5, "\(orientation)")
        }
    }

    // MARK: - 角度（傾けた矩形）

    /// **回転しても傾きの値は変わらない。**
    ///
    /// 直感に反するので理由を書いておく: 矩形は「軸平行の rect ＋ 中心まわりの角度」で
    /// 表され、90 度ぶんの形の変化は `map(_ rect:)` の**縦横の入れ替え**と表示フレームの
    /// 縦横の入れ替えが担っている。ここで角度にも 90 度を足すと二重に回り、
    /// 横長の矩形が縦長になって**顔の左右がはみ出す**（`ClipOrientation.mapAngle` の doc）。
    ///
    /// 「見た目として傾きが回る」ことは `test_矩形モザイクの形が映像と一緒に回る` と
    /// `test_写した矩形の辺の向きが素材と一致する` が四隅で固定している。
    func test_右回転では矩形の傾きの値は変わらない() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(
            placements: [:], orientations: [clipID: ClipOrientation(rotation: .right90)])
        XCTAssertEqual(layout.remapAngle(0.2, clipID: clipID), 0.2, accuracy: 1e-9)
    }

    func test_左右反転で矩形の傾きの符号が反転する() {
        let clipID = UUID()
        let layout = TimelineRenderLayout(
            placements: [:], orientations: [clipID: ClipOrientation(isMirrored: true)])
        XCTAssertEqual(layout.remapAngle(0.2, clipID: clipID), -0.2, accuracy: 1e-9)
    }

    func test_角度の写像は往復する() {
        let clipID = UUID()
        for orientation in allOrientations {
            let layout = TimelineRenderLayout(placements: [:],
                                              orientations: [clipID: orientation])
            for angle in [-1.2, -0.3, 0.0, 0.45, 1.5] {
                let back = layout.inverseRemapAngle(
                    layout.remapAngle(angle, clipID: clipID), clipID: clipID)
                XCTAssertEqual(back, angle, accuracy: 1e-9, "\(orientation) \(angle)")
            }
        }
    }

    /// 傾いた矩形の**辺の向き**が、写した後も素材と同じ向きを指すこと
    /// （矩形だけ回して角度を据え置くと、隠す範囲が素材からずれる）。
    ///
    /// **`mapAngle` 単体と突き合わせてはいけない。** 辺の向きは
    /// 「`map(_ rect:)` による縦横の入れ替え」と「`mapAngle` による符号反転」の
    /// **合わせ技**で決まる。`mapAngle` だけを取り出して「辺の向き」と比べると、
    /// 回転ぶんを角度にも足す実装（＝二重回転）が正しく見えてしまう。
    /// ここでは描かれる矩形そのものから辺の向きを測る。
    ///
    /// 比較は **π を法とする**。矩形は 180 度回しても同じ矩形なので、
    /// 左右反転で「a → -a」と「a → π-a」はどちらも同じ矩形を表す。
    func test_写した矩形の辺の向きが素材と一致する() {
        let source = CGSize(width: 640, height: 640)  // 正方形。縦横比の効果を除いて向きだけ見る
        let angle = 0.4
        let rect = CGRect(x: 0.30, y: 0.40, width: 0.30, height: 0.10)
        for orientation in allOrientations {
            // 素材空間での辺の向きに、映像側の回転・反転を掛けたものが「あるべき向き」。
            let expected = orientation.isMirrored ? -angle : angle
            let rotated = expected + orientation.rotation.radians
            let drawn = corners(of: FaceMaskBuilder.rectPath(from: orientation.map(rect),
                                                            angle: orientation.mapAngle(angle),
                                                            in: orientation.displaySize(source)))
            XCTAssertEqual(moduloPi(longEdgeDirection(of: drawn)), moduloPi(rotated),
                           accuracy: 1e-9, "\(orientation)")
        }
    }

    /// 四隅から**長辺**の向き（ラジアン）を求める。
    private func longEdgeDirection(of corners: [CGPoint]) -> Double {
        var best = (length: -1.0, angle: 0.0)
        for (i, point) in corners.enumerated() {
            let next = corners[(i + 1) % corners.count]
            let length = Double(hypot(next.x - point.x, next.y - point.y))
            if length > best.length {
                best = (length, Double(atan2(next.y - point.y, next.x - point.x)))
            }
        }
        return best.angle
    }

    /// プレビュー 2 経路と書き出しが**全て通る** `ObjectMaskResolver.placements` が、
    /// 矩形と角度の両方に向きを掛けること。ここを通さないと、書き出しだけ矩形が
    /// 素材の位置に残る（プレビューの見え方は書き出しの安全の根拠にならない）。
    func test_物体マスクの解決が矩形と角度の両方に向きを掛ける() {
        let clipID = UUID()
        let sourceID = UUID()
        let orientation = ClipOrientation(rotation: .right90)
        let layout = TimelineRenderLayout(placements: [:], orientations: [clipID: orientation])
        let mask = ObjectMask.single(anchor: .clip(clipID: clipID, sourceID: sourceID),
                                     rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1))
        let tilted = mask?.settingKeyframe(atSourceTime: 0,
                                           rect: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1),
                                           angle: 0.3)
        let placements = ObjectMaskResolver.placements([tilted!], clipID: clipID,
                                                       sourceTime: 0, layout: layout)
        XCTAssertEqual(placements.count, 1)
        assertEqual(CGPoint(x: placements[0].rect.minX, y: placements[0].rect.minY),
                    CGPoint(x: 0.7, y: 0.1))
        // 角度に回転は足さない（形の 90 度ぶんは `rect` の縦横入れ替えが担っている。
        // `ClipOrientation.mapAngle` の doc 参照）。反転していないので符号もそのまま。
        XCTAssertEqual(placements[0].angle, 0.3, accuracy: 1e-9)
    }
}

// MARK: - 補助
//
// extension に置いてあるのは `type_body_length`（上限 300）対策
// （extension のメンバーは型本体の行数に数えられない）。

extension ClipOrientationTests {
    /// 角度を [0, π) へ畳む（矩形は 180 度回しても同じ矩形）。
    private func moduloPi(_ angle: Double) -> Double {
        let wrapped = angle.truncatingRemainder(dividingBy: .pi)
        return wrapped < 0 ? wrapped + .pi : wrapped
    }

    private func clockwise(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.y, y: point.x)
    }

    // 別ファイルの extension（`ClipOrientationAdversarialTests.swift`）から使うため internal。
    func landmarkSet(at point: CGPoint) -> FaceLandmarkSet {
        FaceLandmarkSet(points: [FaceLandmark(x: Float(point.x), y: Float(point.y))],
                        confidence: 1)
    }

    /// **矩形モザイクの「形」が映像と一緒に回ることの番人。**
    ///
    /// 既存の一致テストと `test_角度と矩形の写像が同じ回転を表す` は、`map` と `mapAngle` を
    /// **別々に**見ているので、「`map(rect)` が既に 90 度ぶんの入れ替えを担っているのに
    /// `mapAngle` でも足してしまう」という**二重回転**を原理的に検出できない
    /// （どちらの写像も単体としては正しい値を返すため）。
    ///
    /// ここでは描画が実際に通る経路（`FaceMaskBuilder.rectPath`）で四隅を作り、
    /// 「素材空間で描いた矩形を映像の変換で写したもの」と
    /// 「写像後の rect と角度から描いたもの」が同じ四角形になることを見る。
    ///
    /// 素材は**横長**（128 × 36 px）にすること。正方形だと二重回転しても形が変わらず、
    /// このテストが番人にならない。
    func test_矩形モザイクの形が映像と一緒に回る() {
        let source = CGSize(width: 640, height: 360)
        let renderSize = CGSize(width: 480, height: 640)
        let clipID = UUID()
        let rect = CGRect(x: 0.40, y: 0.45, width: 0.20, height: 0.10)
        for orientation in allOrientations {
            for angle in [0.0, 0.3] {
                let placement = AspectFit.placement(of: orientation.displaySize(source),
                                                    in: renderSize)
                let layout = TimelineRenderLayout(placements: [clipID: placement],
                                                  orientations: [clipID: orientation])
                let transform = ClipRenderTransform.make(displaySize: source,
                                                         orientation: orientation,
                                                         placement: placement,
                                                         renderSize: renderSize)
                let truth = corners(of: FaceMaskBuilder.rectPath(from: rect, angle: angle,
                                                                 in: source))
                    .map { $0.applying(transform) }
                let drawn = corners(of: FaceMaskBuilder.rectPath(
                    from: layout.remap(rect, clipID: clipID),
                    angle: layout.remapAngle(angle, clipID: clipID),
                    in: renderSize))
                assertSameCorners(truth, drawn, "\(orientation) angle=\(angle)")
            }
        }
    }

    /// `CGPath` から角の座標を取り出す（`addRect` は始点を閉じるので重複を畳む）。
    private func corners(of path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.pointee.points[0])
            default:
                break
            }
        }
        var unique: [CGPoint] = []
        for point in points
        where !unique.contains(where: { hypot($0.x - point.x, $0.y - point.y) < 1e-6 }) {
            unique.append(point)
        }
        return unique
    }

    /// 四隅の**集合**として一致するか（頂点の並び順は問わない）。
    private func assertSameCorners(_ lhs: [CGPoint], _ rhs: [CGPoint], _ message: String,
                                   accuracy: CGFloat = 1e-6,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, "角の数が違う: \(message)", file: file, line: line)
        for point in lhs {
            guard let nearest = rhs.min(by: {
                hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
            }) else {
                XCTFail("対応する角が無い: \(message)", file: file, line: line)
                return
            }
            XCTAssertEqual(hypot(nearest.x - point.x, nearest.y - point.y), 0, accuracy: accuracy,
                           "角がずれている \(point) vs \(nearest): \(message)",
                           file: file, line: line)
        }
    }

    // 別ファイルの extension（`ClipOrientationAdversarialTests.swift`）から使うため internal。
    func assertEqual(_ lhs: CGPoint, _ rhs: CGPoint, _ message: String = "",
                     accuracy: CGFloat = 1e-9,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, message, file: file, line: line)
    }
}
