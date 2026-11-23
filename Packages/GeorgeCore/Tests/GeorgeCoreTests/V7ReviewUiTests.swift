import XCTest
@testable import GeorgeCore

/// v7 review, screens on iPhone, iPad and Mac: a page covered by one opened on top of it, and what
/// stays on top when the shown item is deleted.
final class V7ReviewUiTests: XCTestCase {
    /// Stand-ins for the app's `Route` and `DetailItem`.
    private enum Step: Hashable {
        case list(String)
        case item(Int)
    }

    private func wrap(_ id: Int) -> Step { .item(id) }

    // MARK: Covered

    func testShownItemWithSomethingOnTopIsCovered() {
        XCTAssertTrue(ListDetailPath.isCovered(1, shown: 1, onTop: [Step.item(2)], wrap: wrap))
    }

    func testShownItemAloneIsNotCovered() {
        XCTAssertFalse(ListDetailPath.isCovered(1, shown: 1, onTop: [Step](), wrap: wrap))
    }

    func testEntryBelowTheTopIsCovered() {
        // iPhone: the item is in the tab's path with another page pushed on it.
        XCTAssertTrue(ListDetailPath.isCovered(1, shown: nil, onTop: [Step.list("all"), .item(1), .item(2)], wrap: wrap))
    }

    func testTopmostEntryIsNotCovered() {
        XCTAssertFalse(ListDetailPath.isCovered(2, shown: nil, onTop: [Step.list("all"), .item(1), .item(2)], wrap: wrap))
    }

    func testItemNotShownAnywhereIsNotCovered() {
        // Mac: the list switched to another item, or another sidebar list shows.
        XCTAssertFalse(ListDetailPath.isCovered(1, shown: 3, onTop: [Step.item(2)], wrap: wrap))
        XCTAssertFalse(ListDetailPath.isCovered(1, shown: nil, onTop: [Step](), wrap: wrap))
    }

    // MARK: Close

    func testClosingTheShownItemDropsWhatWasOpenedFromIt() {
        // iPad: a workout opened from a template's history goes when the template is deleted.
        XCTAssertEqual(ListDetailPath.close(1, shown: 1, onTop: [Step.item(2), .item(3)], wrap: wrap), [])
    }

    func testClosingAnEntryOnTopKeepsTheOthers() {
        XCTAssertEqual(ListDetailPath.close(2, shown: 1, onTop: [Step.item(2), .item(3)], wrap: wrap), [.item(3)])
    }

    func testClosingSomethingElseKeepsTheStack() {
        XCTAssertEqual(ListDetailPath.close(9, shown: 1, onTop: [Step.item(2)], wrap: wrap), [.item(2)])
        XCTAssertEqual(ListDetailPath.close(9, shown: nil, onTop: [Step](), wrap: wrap), [])
    }
}
