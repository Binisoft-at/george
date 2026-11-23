import XCTest
@testable import GeorgeCore

/// v7 wave 2 lane "width": iPad list + detail – a tab's path split into the list column and the
/// detail column, and joined again when the window gets narrow.
final class V7W2WidthTests: XCTestCase {
    /// Stand-ins for the app's `Route` and `DetailItem`.
    private enum Step: Hashable {
        case list(String)
        case item(Int)
    }

    private func itemOf(_ step: Step) -> Int? {
        if case .item(let id) = step { return id }
        return nil
    }

    // MARK: Split

    func testSplitAtTheFirstItem() {
        let parts = ListDetailPath.split([Step.list("templates"), .item(1), .item(2), .list("program")], item: itemOf)
        XCTAssertEqual(parts.lists, [.list("templates")])
        XCTAssertEqual(parts.item, 1)
        XCTAssertEqual(parts.onTop, [.item(2), .list("program")])
    }

    func testSplitWithoutAnItemKeepsTheLists() {
        let parts = ListDetailPath.split([Step.list("templates"), .list("library")], item: itemOf)
        XCTAssertEqual(parts.lists, [.list("templates"), .list("library")])
        XCTAssertNil(parts.item)
        XCTAssertEqual(parts.onTop, [])
    }

    func testSplitOfAnEmptyPath() {
        let parts = ListDetailPath.split([Step](), item: itemOf)
        XCTAssertEqual(parts.lists, [])
        XCTAssertNil(parts.item)
        XCTAssertEqual(parts.onTop, [])
    }

    func testSplitWithTheItemAtTheRoot() {
        let parts = ListDetailPath.split([Step.item(7)], item: itemOf)
        XCTAssertEqual(parts.lists, [])
        XCTAssertEqual(parts.item, 7)
        XCTAssertEqual(parts.onTop, [])
    }

    // MARK: Join

    func testJoinIsTheInverseOfSplit() {
        let paths: [[Step]] = [
            [],
            [.list("templates")],
            [.item(1)],
            [.list("templates"), .item(1), .item(2)],
            [.list("program"), .item(3), .list("library"), .item(4)],
        ]
        for path in paths {
            let parts = ListDetailPath.split(path, item: itemOf)
            XCTAssertEqual(ListDetailPath.join(lists: parts.lists, item: parts.item, onTop: parts.onTop, wrap: Step.item), path)
        }
    }

    func testJoinKeepsWhatIsOnTopOfAClosedItem() {
        // The item next to the list was deleted; what was opened from it stays reachable.
        let path = ListDetailPath.join(lists: [Step.list("templates")], item: nil, onTop: [.item(2)], wrap: Step.item)
        XCTAssertEqual(path, [.list("templates"), .item(2)])
    }

    // MARK: Push

    func testPushAddsOnTop() {
        XCTAssertEqual(ListDetailPath.push(2, shown: 1, onTop: [Step](), wrap: Step.item), [.item(2)])
        XCTAssertEqual(ListDetailPath.push(3, shown: 1, onTop: [Step.item(2)], wrap: Step.item), [.item(2), .item(3)])
    }

    func testPushDoesNotRepeatWhatShows() {
        // The item itself, with nothing on top.
        XCTAssertEqual(ListDetailPath.push(1, shown: 1, onTop: [Step](), wrap: Step.item), [])
        // The topmost entry.
        XCTAssertEqual(ListDetailPath.push(2, shown: 1, onTop: [Step.item(2)], wrap: Step.item), [.item(2)])
    }

    func testPushTheShownItemAgainFromFurtherUp() {
        // A template's workout links back to the template: it opens on top, with Back.
        XCTAssertEqual(ListDetailPath.push(1, shown: 1, onTop: [Step.item(2)], wrap: Step.item), [.item(2), .item(1)])
    }

    func testPushWithNothingShown() {
        XCTAssertEqual(ListDetailPath.push(4, shown: nil, onTop: [Step](), wrap: Step.item), [.item(4)])
    }
}
