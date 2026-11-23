import XCTest
@testable import GeorgeCore

/// v7 wave 3, lane "lists", review: bulk Delete's question reads right for one workout.
final class V7W3ListsReviewTests: XCTestCase {
    func testBulkTitleCountsOneWorkoutInTheSingular() {
        XCTAssertEqual(SessionDelete.bulkTitle(count: 1), "Delete 1 workout?")
        XCTAssertEqual(SessionDelete.bulkTitle(count: 2), "Delete 2 workouts?")
        XCTAssertEqual(SessionDelete.bulkTitle(count: 12), "Delete 12 workouts?")
    }

    func testOneSelectedWorkoutRunningElsewhereStillGetsTheMessage() {
        // Select mode with only the workout running on the iPhone ticked: one question, singular.
        let bulk = SessionDelete.bulk([.init(isActive: true, isLiveHere: false, deviceName: "your iPhone")])
        XCTAssertEqual(SessionDelete.bulkTitle(count: 1), "Delete 1 workout?")
        XCTAssertEqual(bulk.deleted, [0])
        XCTAssertEqual(bulk.message, "Running on your iPhone. It stops there too.")
    }
}
