import XCTest
@testable import Veil

final class GlyphCacheTests: XCTestCase {
    private var cache: GlyphCache!
    private let defaultFg = 0x000000
    private let defaultBg = 0xFFFFFF

    override func setUp() {
        super.setUp()
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let cellSize = CGSize(width: 8, height: 16)
        cache = GlyphCache(font: font, cellSize: cellSize)
    }

    override func tearDown() {
        cache = nil
        super.tearDown()
    }

    func testCacheMissRendersNonNilImage() {
        let attrs = CellAttributes()
        let image = cache.get(text: "A", attrs: attrs, defaultFg: defaultFg, defaultBg: defaultBg)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    func testCacheHitReturnsSameObject() {
        let attrs = CellAttributes()
        let image1 = cache.get(text: "B", attrs: attrs, defaultFg: defaultFg, defaultBg: defaultBg)
        let image2 = cache.get(text: "B", attrs: attrs, defaultFg: defaultFg, defaultBg: defaultBg)
        XCTAssertTrue(image1 === image2, "Cache hit should return the same CGImage instance")
    }

    func testDifferentAttributesProduceDifferentImages() {
        let attrs1 = CellAttributes()
        let attrs2 = CellAttributes(bold: true)
        let image1 = cache.get(text: "C", attrs: attrs1, defaultFg: defaultFg, defaultBg: defaultBg)
        let image2 = cache.get(text: "C", attrs: attrs2, defaultFg: defaultFg, defaultBg: defaultBg)
        XCTAssertFalse(
            image1 === image2, "Different attributes should produce different cached images")
    }

    func testInvalidateClearsCache() {
        let attrs = CellAttributes()
        let image1 = cache.get(text: "D", attrs: attrs, defaultFg: defaultFg, defaultBg: defaultBg)
        cache.invalidate()
        let image2 = cache.get(text: "D", attrs: attrs, defaultFg: defaultFg, defaultBg: defaultBg)
        XCTAssertFalse(image1 === image2, "After invalidation, a new image should be rendered")
    }
}
