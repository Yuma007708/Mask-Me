import CoreGraphics
import XCTest
@testable import MosaicCore

/// `CropHandleMath` の契約。
///
/// **期待値はテスト側で本番と同じ式から計算しない。** 性質（固定点のビット同一・
/// 比率・包含・下限・単調性・最大性）か、手計算した具体値の literal だけで書く
/// （この案件で「テストが自分の写しを検査して退行を素通りさせた」事故が過去にある）。
final class CropHandleMathTests: XCTestCase {
    private let frame = CGSize(width: 1000, height: 1000) // 正方形フレーム → ピクセル比=正規化比
    private let full = CropRect.full

    // MARK: - 対角・対辺の固定点

    func test_角ハンドルは対角をビット同一で残す() {
        let crop = CropRect(rect: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4))
        for handle: CropHandle in [.topLeft, .topRight, .bottomRight, .bottomLeft] {
            let result = CropHandleMath.dragged(crop, handle: handle, by: CGSize(width: 0.05, height: 0.05),
                                                lock: .free, inFrame: frame)
            switch handle {
            case .topLeft:
                XCTAssertEqual(result.rect.maxX, crop.rect.maxX)
                XCTAssertEqual(result.rect.maxY, crop.rect.maxY)
            case .topRight:
                XCTAssertEqual(result.rect.minX, crop.rect.minX)
                XCTAssertEqual(result.rect.maxY, crop.rect.maxY)
            case .bottomRight:
                XCTAssertEqual(result.rect.minX, crop.rect.minX)
                XCTAssertEqual(result.rect.minY, crop.rect.minY)
            case .bottomLeft:
                XCTAssertEqual(result.rect.maxX, crop.rect.maxX)
                XCTAssertEqual(result.rect.minY, crop.rect.minY)
            default: break
            }
        }
    }

    func test_辺ハンドルは対辺をビット同一で残す() {
        let crop = CropRect(rect: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertEqual(CropHandleMath.dragged(crop, handle: .top, by: CGSize(width: 0, height: 0.05),
                                              lock: .free, inFrame: frame).rect.maxY, crop.rect.maxY)
        XCTAssertEqual(CropHandleMath.dragged(crop, handle: .bottom, by: CGSize(width: 0, height: -0.05),
                                              lock: .free, inFrame: frame).rect.minY, crop.rect.minY)
        XCTAssertEqual(CropHandleMath.dragged(crop, handle: .left, by: CGSize(width: 0.05, height: 0),
                                              lock: .free, inFrame: frame).rect.maxX, crop.rect.maxX)
        XCTAssertEqual(CropHandleMath.dragged(crop, handle: .right, by: CGSize(width: -0.05, height: 0),
                                              lock: .free, inFrame: frame).rect.minX, crop.rect.minX)
    }

    // MARK: - 反転しない

    func test_最小辺で止まり辺が反転しない() {
        let crop = CropRect(rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        // 右辺を左へ大きく引く（最小辺を大きく割り込む量）。
        let result = CropHandleMath.dragged(crop, handle: .right, by: CGSize(width: -10, height: 0),
                                            lock: .free, inFrame: frame)
        XCTAssertEqual(result.rect.width, CropRect.minimumSide, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(result.rect.minX, 0)
        XCTAssertLessThanOrEqual(result.rect.maxX, 1)
        // 対辺（左）は固定のまま。
        XCTAssertEqual(result.rect.minX, crop.rect.minX)

        // 角ハンドルでも同様。
        let cornerResult = CropHandleMath.dragged(crop, handle: .bottomRight,
                                                   by: CGSize(width: -10, height: -10),
                                                   lock: .free, inFrame: frame)
        XCTAssertEqual(cornerResult.rect.width, CropRect.minimumSide, accuracy: 1e-9)
        XCTAssertEqual(cornerResult.rect.height, CropRect.minimumSide, accuracy: 1e-9)
    }

    // MARK: - 内側ドラッグ

    func test_内側ドラッグは大きさをビット同一で保つ() {
        let crop = CropRect(rect: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.25))
        let result = CropHandleMath.dragged(crop, handle: .inside, by: CGSize(width: 0.1, height: -0.05),
                                            lock: .original, inFrame: frame)
        XCTAssertEqual(result.rect.width, crop.rect.width)
        XCTAssertEqual(result.rect.height, crop.rect.height)
    }

    func test_内側ドラッグは枠端で原点だけ止まる() {
        let crop = CropRect(rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let result = CropHandleMath.dragged(crop, handle: .inside, by: CGSize(width: -10, height: -10),
                                            lock: .free, inFrame: frame)
        XCTAssertEqual(result.rect.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(result.rect.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(result.rect.width, crop.rect.width)
        XCTAssertEqual(result.rect.height, crop.rect.height)
    }

    // MARK: - 比率固定

    func test_比率固定は全7比率で保たれる() {
        let crop = CropRect(rect: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
        for lock in CropAspectLock.allCases {
            let result = CropHandleMath.dragged(crop, handle: .bottomRight,
                                                 by: CGSize(width: 0.05, height: 0.2),
                                                 lock: lock, inFrame: frame)
            guard let pixelRatio = lock.pixelRatio(inFrame: frame) else {
                continue // .free は比率制約なし。
            }
            // frame が正方形なので正規化比 == ピクセル比。
            let gotRatio = result.rect.width / result.rect.height
            XCTAssertEqual(gotRatio, pixelRatio, accuracy: 1e-6, "lock=\(lock)")
        }
    }

    func test_比率固定は枠端で比率を崩さず縮む() {
        // 右下ハンドルを固定点にし、右端ぎりぎりに置いたクロップを右下へ大きくドラッグ。
        // フレーム境界に当たっても 16:9 の比率は保たれたまま縮む。
        let crop = CropRect(rect: CGRect(x: 0.7, y: 0.1, width: CropRect.minimumSide, height: 0.2))
        let result = CropHandleMath.dragged(crop, handle: .bottomRight, by: CGSize(width: 5, height: 5),
                                            lock: .landscape16x9, inFrame: frame)
        XCTAssertLessThanOrEqual(result.rect.maxX, 1.0 + 1e-9)
        XCTAssertLessThanOrEqual(result.rect.maxY, 1.0 + 1e-9)
        let gotRatio = result.rect.width / result.rect.height
        XCTAssertEqual(gotRatio, 16.0 / 9.0, accuracy: 1e-6)
    }

    // MARK: - 比率選び直し

    func test_比率を選び直すと中心を保った枠内最大になる() {
        let crop = CropRect(rect: CGRect(x: 0.2, y: 0.35, width: 0.3, height: 0.2))
        let center = CGPoint(x: crop.rect.midX, y: crop.rect.midY)
        let result = CropHandleMath.applying(.square, to: crop, inFrame: frame)

        XCTAssertEqual(result.rect.midX, center.x, accuracy: 1e-9)
        XCTAssertEqual(result.rect.midY, center.y, accuracy: 1e-9)
        XCTAssertEqual(result.rect.width / result.rect.height, 1.0, accuracy: 1e-9)

        // **最大性**: 1.001 倍すると、枠を出るか比率が崩れる。
        let scaled = CGSize(width: result.rect.width * 1.001, height: result.rect.height * 1.001)
        let scaledRect = CGRect(x: center.x - scaled.width / 2, y: center.y - scaled.height / 2,
                                width: scaled.width, height: scaled.height)
        let staysInFrame = scaledRect.minX >= -1e-9 && scaledRect.minY >= -1e-9
            && scaledRect.maxX <= 1 + 1e-9 && scaledRect.maxY <= 1 + 1e-9
        XCTAssertFalse(staysInFrame, "1.001倍しても枠内に収まってしまった。最大ではない: \(scaledRect)")
    }

    func test_比率をfreeへ戻すと全面になる() {
        let crop = CropRect(rect: CGRect(x: 0.2, y: 0.35, width: 0.3, height: 0.2))
        let result = CropHandleMath.applying(.free, to: crop, inFrame: frame)
        XCTAssertTrue(result.isFull)
    }

    // MARK: - フューザ（乱数、固定シード）

    /// 固定シードの線形合同法。テスト実行のたびに同じ乱数列を再現するために使う
    /// （`Double.random` は再現できない）。
    private struct SeededGenerator {
        var state: UInt64
        mutating func next() -> Double {
            state = 6364136223846793005 &* state &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    func test_乱数ドラッグでも常に枠内かつ最小辺以上() {
        var generator = SeededGenerator(state: 0xC20F_A1B2)
        let locks = CropAspectLock.allCases
        let handles = CropHandle.allCases
        for _ in 0..<10_000 {
            let cropRect = CGRect(x: generator.next() * 0.8, y: generator.next() * 0.8,
                                  width: 0.05 + generator.next() * 0.5,
                                  height: 0.05 + generator.next() * 0.5)
            let crop = CropRect(rect: cropRect)
            let handle = handles[Int(generator.next() * Double(handles.count)) % handles.count]
            let lock = locks[Int(generator.next() * Double(locks.count)) % locks.count]
            let translation = CGSize(width: (generator.next() - 0.5) * 2,
                                     height: (generator.next() - 0.5) * 2)
            let result = CropHandleMath.dragged(crop, handle: handle, by: translation,
                                                lock: lock, inFrame: frame)
            XCTAssertGreaterThanOrEqual(result.rect.minX, 0, "handle=\(handle) lock=\(lock)")
            XCTAssertGreaterThanOrEqual(result.rect.minY, 0, "handle=\(handle) lock=\(lock)")
            XCTAssertLessThanOrEqual(result.rect.maxX, 1.0 + 1e-6, "handle=\(handle) lock=\(lock)")
            XCTAssertLessThanOrEqual(result.rect.maxY, 1.0 + 1e-6, "handle=\(handle) lock=\(lock)")
            XCTAssertGreaterThanOrEqual(result.rect.width, CropRect.minimumSide - 1e-6,
                                        "handle=\(handle) lock=\(lock)")
            XCTAssertGreaterThanOrEqual(result.rect.height, CropRect.minimumSide - 1e-6,
                                        "handle=\(handle) lock=\(lock)")
        }
    }

    // MARK: - 単調性

    func test_引いた方向へ単調に伸縮する() {
        let crop = CropRect(rect: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
        var previousWidth = crop.rect.width
        for step in 1...5 {
            let translation = CGSize(width: CGFloat(step) * 0.02, height: 0)
            let result = CropHandleMath.dragged(crop, handle: .right, by: translation,
                                                lock: .free, inFrame: frame)
            XCTAssertGreaterThanOrEqual(result.rect.width, previousWidth,
                                        "右へ引くほど幅は単調非減少のはず (step=\(step))")
            previousWidth = result.rect.width
        }

        var previousShrinkWidth = crop.rect.width
        for step in 1...4 {
            let translation = CGSize(width: -CGFloat(step) * 0.02, height: 0)
            let result = CropHandleMath.dragged(crop, handle: .right, by: translation,
                                                lock: .free, inFrame: frame)
            XCTAssertLessThanOrEqual(result.rect.width, previousShrinkWidth,
                                     "左へ引くほど幅は単調非増加のはず (step=\(step))")
            previousShrinkWidth = result.rect.width
        }
    }

    // MARK: - 手計算 literal

    /// 100×100 の枠、全面から右辺を -0.25 動かすと `(0,0,0.75,1)`（手計算）。
    func test_手計算_全面から右辺を引く() {
        let result = CropHandleMath.dragged(full, handle: .right, by: CGSize(width: -0.25, height: 0),
                                            lock: .free, inFrame: CGSize(width: 100, height: 100))
        XCTAssertEqual(result.rect, CGRect(x: 0, y: 0, width: 0.75, height: 1), accuracy: 1e-9)
    }

    /// 全面(0,0,1,1)から内側ドラッグで (0.1, 0.1) 動かすと、大きさそのまま (0.1,0.1,1,1)…
    /// だが 1×1 は枠を超えるため、原点は 0 に留め置かれ全面のまま。
    func test_手計算_内側ドラッグで全面は動かない() {
        let result = CropHandleMath.dragged(full, handle: .inside, by: CGSize(width: 0.1, height: 0.1),
                                            lock: .free, inFrame: frame)
        XCTAssertEqual(result.rect, CGRect(x: 0, y: 0, width: 1, height: 1), accuracy: 1e-9)
    }
}

private func XCTAssertEqual(_ lhs: CGRect, _ rhs: CGRect, accuracy: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.minX, rhs.minX, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.minY, rhs.minY, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.width, rhs.width, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.height, rhs.height, accuracy: accuracy, file: file, line: line)
}
