import XCTest
@testable import RivenCore

final class StringEllipsisTests: XCTestCase {
    func testShortStringReturnedVerbatim() {
        XCTAssertEqual("hello".middleEllipsized(), "hello")
        XCTAssertEqual("a".middleEllipsized(maxLength: 3), "a")
        // Exactly the cap: still untouched.
        XCTAssertEqual(String(repeating: "x", count: 24).middleEllipsized(),
                       String(repeating: "x", count: 24))
    }

    func testEllipsizesAtDefaultCap() {
        // 30 chars → 24 chars output, ellipsis in the middle, leading
        // half keeps the extra character on odd splits.
        let input = "AReallyLongFilenameForRiven.swift"  // 33 chars
        let out = input.middleEllipsized()
        XCTAssertEqual(out.count, 24)
        XCTAssertTrue(out.contains("\u{2026}"))
        // Prefix preserved, suffix preserved.
        XCTAssertTrue(out.hasPrefix("AReally"))
        XCTAssertTrue(out.hasSuffix(".swift"))
    }

    func testRespectsCustomMaxLength() {
        let input = "ABCDEFGHIJKLMNOPQR"  // 18 chars
        // maxLength = 10 → 9 chars + ellipsis, head = 5, tail = 4
        let out = input.middleEllipsized(maxLength: 10)
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out, "ABCDE\u{2026}OPQR")
    }
}
