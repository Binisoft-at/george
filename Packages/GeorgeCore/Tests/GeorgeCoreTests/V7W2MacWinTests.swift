import XCTest
@testable import GeorgeCore

/// v7 wave 2, Mac window structure: the list column's width next to its detail.
final class V7W2MacWinTests: XCTestCase {
    private let column = ResizableColumn(range: 300...560, ideal: 380)

    func testWidthStaysInRange() {
        XCTAssertEqual(column.clamped(380), 380)
        XCTAssertEqual(column.clamped(120), 300)
        XCTAssertEqual(column.clamped(900), 560)
        XCTAssertEqual(column.clamped(300), 300)
        XCTAssertEqual(column.clamped(560), 560)
    }

    func testUnusableWidthFallsBackToIdeal() {
        XCTAssertEqual(column.clamped(.nan), 380)
        XCTAssertEqual(column.clamped(.infinity), 380)
        XCTAssertEqual(column.clamped(-.infinity), 380)
    }

    func testIdealOutsideRangeIsClamped() {
        XCTAssertEqual(ResizableColumn(range: 300...560, ideal: 1000).ideal, 560)
        XCTAssertEqual(ResizableColumn(range: 300...560, ideal: 10).ideal, 300)
    }

    func testDragCountsFromItsStart() {
        // The edge follows the pointer: start + translation, not added up on every change.
        XCTAssertEqual(column.width(draggedFrom: 380, by: 40), 420)
        XCTAssertEqual(column.width(draggedFrom: 380, by: -50), 330)
        XCTAssertEqual(column.width(draggedFrom: 380, by: 0), 380)
    }

    func testDragStopsAtTheEnds() {
        XCTAssertEqual(column.width(draggedFrom: 380, by: 500), 560)
        XCTAssertEqual(column.width(draggedFrom: 380, by: -500), 300)
    }

    func testDragFromAStoredWidthOutsideTheRange() {
        // A width stored before the range changed starts the drag from the nearest end.
        XCTAssertEqual(column.width(draggedFrom: 700, by: -20), 540)
        XCTAssertEqual(column.width(draggedFrom: 100, by: 20), 320)
        XCTAssertEqual(column.width(draggedFrom: .nan, by: 10), 390)
        XCTAssertEqual(column.width(draggedFrom: 400, by: .nan), 400)
    }
}
