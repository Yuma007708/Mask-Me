import CoreGraphics
import XCTest
@testable import MosaicCore

/// `PreviewImageGeometry` の契約。
///
/// プレビューに重ねるものはすべてこの換算を通るので、ここが狂うと
/// 顔の枠も手動矩形もまとめてずれる。
final class PreviewImageGeometryTests: XCTestCase {
    /// 横長コンテナに縦長画像 → 左右に黒帯。
    private let pillarboxed = PreviewImageGeometry(containerSize: CGSize(width: 400, height: 200),
                                                   imageSize: CGSize(width: 100, height: 200))
    /// 縦長コンテナに横長画像 → 上下に黒帯。
    private let letterboxed = PreviewImageGeometry(containerSize: CGSize(width: 200, height: 400),
                                                   imageSize: CGSize(width: 200, height: 100))

    // MARK: - 画像の占める矩形

    func test_imageRect_centersWithinContainer() {
        XCTAssertEqual(pillarboxed.imageRect, CGRect(x: 150, y: 0, width: 100, height: 200))
        XCTAssertEqual(letterboxed.imageRect, CGRect(x: 0, y: 150, width: 200, height: 100))
    }

    func test_imageRect_fillsContainerWhenAspectMatches() {
        let exact = PreviewImageGeometry(containerSize: CGSize(width: 200, height: 100),
                                         imageSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(exact.imageRect, CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    /// 画像がまだ無いときはコンテナ全体（換算を破綻させない）。
    func test_imageRect_withoutImage_isWholeContainer() {
        let loading = PreviewImageGeometry(containerSize: CGSize(width: 300, height: 100),
                                           imageSize: nil)
        XCTAssertEqual(loading.imageRect, CGRect(x: 0, y: 0, width: 300, height: 100))
    }

    /// 潰れた入力でも 0 除算にしない。
    func test_imageRect_withDegenerateSizes_doesNotDivideByZero() {
        let zeroImage = PreviewImageGeometry(containerSize: CGSize(width: 100, height: 100),
                                             imageSize: CGSize(width: 0, height: 0))
        XCTAssertEqual(zeroImage.imageRect, CGRect(x: 0, y: 0, width: 100, height: 100))
        let zeroContainer = PreviewImageGeometry(containerSize: .zero,
                                                 imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(zeroContainer.imageRect, .zero)
    }

    // MARK: - 往復

    func test_screenRect_andBack_roundTrips() {
        let normalized = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let screen = pillarboxed.screenRect(from: normalized)
        XCTAssertEqual(screen, CGRect(x: 175, y: 100, width: 50, height: 50))
        let back = pillarboxed.normalizedRect(from: screen)
        XCTAssertEqual(back.origin.x, normalized.origin.x, accuracy: 1e-9)
        XCTAssertEqual(back.origin.y, normalized.origin.y, accuracy: 1e-9)
        XCTAssertEqual(back.width, normalized.width, accuracy: 1e-9)
        XCTAssertEqual(back.height, normalized.height, accuracy: 1e-9)
    }

    /// **黒帯の分を無視して素通ししていないこと。** コンテナ基準で換算すると
    /// レターボックスのぶんだけ全部ずれる（この 1 件が退行を捕まえる）。
    func test_screenRect_accountsForLetterbox() {
        let full = letterboxed.screenRect(from: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(full, CGRect(x: 0, y: 150, width: 200, height: 100))
    }

    /// はみ出しは切り落とす。
    func test_normalizedRect_clipsOutsideTheImage() {
        let overflowing = CGRect(x: 100, y: -50, width: 400, height: 400)
        let result = letterboxed.normalizedRect(from: overflowing)
        XCTAssertEqual(result.origin.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.origin.y, 0.0, accuracy: 1e-9)
        XCTAssertEqual(result.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.height, 1.0, accuracy: 1e-9)
    }

    /// **画像とまったく交差しない矩形で `.null` を返さないこと。**
    /// `.null` は origin が無限大で、混ぜると NaN が伝播して呼び出し側が黙って壊れる。
    func test_normalizedRect_withNoIntersection_isFiniteZero() {
        let outside = CGRect(x: 0, y: 0, width: 10, height: 10) // 黒帯の中だけ
        let result = letterboxed.normalizedRect(from: outside)
        XCTAssertEqual(result, .zero)
        XCTAssertFalse(result.isNull)
        XCTAssertTrue(result.origin.x.isFinite && result.origin.y.isFinite)
    }

    // MARK: - 点（タップ）

    func test_normalizedPoint_insideTheImage() {
        let point = letterboxed.normalizedPoint(from: CGPoint(x: 100, y: 200))
        XCTAssertEqual(point?.x ?? .nan, 0.5, accuracy: 1e-9)
        XCTAssertEqual(point?.y ?? .nan, 0.5, accuracy: 1e-9)
    }

    /// **黒帯のタップは nil。** 端へ丸めると、画像の端に居る顔が誤って選ばれる。
    func test_normalizedPoint_onLetterbox_isNil() {
        XCTAssertNil(letterboxed.normalizedPoint(from: CGPoint(x: 100, y: 10)),
                     "上の黒帯を押したのに画像内として扱われた")
        XCTAssertNil(letterboxed.normalizedPoint(from: CGPoint(x: 100, y: 390)),
                     "下の黒帯を押したのに画像内として扱われた")
        XCTAssertNil(pillarboxed.normalizedPoint(from: CGPoint(x: 10, y: 100)),
                     "左の黒帯を押したのに画像内として扱われた")
    }
}
