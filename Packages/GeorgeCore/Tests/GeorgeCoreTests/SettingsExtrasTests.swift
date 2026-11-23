import XCTest
@testable import GeorgeCore

final class SettingsExtrasTests: XCTestCase {
    func testMissingOrBrokenDataGivesEmptyExtras() {
        XCTAssertEqual(SettingsExtras(data: nil), SettingsExtras())
        XCTAssertEqual(SettingsExtras(data: Data("not json".utf8)), SettingsExtras())
        XCTAssertEqual(SettingsExtras(data: Data("[1,2]".utf8)), SettingsExtras())
        XCTAssertNil(SettingsExtras().bool(SettingsExtras.Key.thaliaDeliver))
    }

    func testValuesRoundTripAndUnknownKeysAreKept() throws {
        let newer = #"{"later.feature":{"v":1,"groups":{"a":{"category":"3.2"}}},"other":[1,"x",null,true]}"#
        var extras = SettingsExtras(data: Data(newer.utf8))
        extras.set(false, for: SettingsExtras.Key.thaliaDeliver)
        extras.set("Push", for: "name")
        extras.set(2.5, for: "step")
        let data = try XCTUnwrap(extras.encoded())
        let back = SettingsExtras(data: data)
        XCTAssertEqual(back, extras)
        XCTAssertEqual(back.bool(SettingsExtras.Key.thaliaDeliver), false)
        XCTAssertEqual(back.string("name"), "Push")
        XCTAssertEqual(back.number("step"), 2.5)
        XCTAssertNotNil(back["later.feature"], "unknown keys survive a save")
        XCTAssertEqual(back["other"], .array([.number(1), .string("x"), .null, .bool(true)]))
        XCTAssertEqual(extras.encoded(), back.encoded(), "same content, same bytes")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix(#"{"later.feature":"#), "sorted keys")
    }

    func testRemove() {
        var extras = SettingsExtras()
        extras.set(true, for: "a")
        extras.remove("a")
        XCTAssertNil(extras.bool("a"))
        XCTAssertEqual(extras, SettingsExtras())
    }
}
