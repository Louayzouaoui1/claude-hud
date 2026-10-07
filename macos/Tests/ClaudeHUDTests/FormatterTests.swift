import XCTest
@testable import HUDCore

final class FormatterTests: XCTestCase {

  // MARK: - price(_:) tests

  func testPriceFableModel() {
    let result = price("claude-3-fable")
    XCTAssertEqual(result.i, 10)
    XCTAssertEqual(result.o, 50)
    XCTAssertEqual(result.r, 0.25)
  }

  func testPriceMythosModel() {
    let result = price("mythos-v2")
    XCTAssertEqual(result.i, 10)
    XCTAssertEqual(result.o, 50)
    XCTAssertEqual(result.r, 0.25)
  }

  func testPriceMultipleMatchFableOpus() {
    // "fable-opus" matches both "fable" and "opus" checks; first match wins
    let result = price("fable-opus")
    XCTAssertEqual(result.i, 10)
    XCTAssertEqual(result.o, 50)
    XCTAssertEqual(result.r, 0.25)
  }

  func testPriceOpusVariants() {
    XCTAssertEqual(price("opus-5-5").i, 4)
    XCTAssertEqual(price("opus-4-1").i, 15)
    XCTAssertEqual(price("opus-4-2025").i, 15)
    XCTAssertEqual(price("opus-pro").i, 5)
  }

  func testPriceSonnetVariants() {
    XCTAssertEqual(price("sonnet-5").i, 2)
    XCTAssertEqual(price("sonnet-3.5").i, 3)
  }

  func testPriceHaiku() {
    let result = price("haiku-3")
    XCTAssertEqual(result.i, 1)
    XCTAssertEqual(result.o, 5)
    XCTAssertEqual(result.r, 0.1)
  }

  func testPriceDefault() {
    let result = price("unknown-model")
    XCTAssertEqual(result.i, 5)
    XCTAssertEqual(result.o, 25)
    XCTAssertEqual(result.r, 0.5)
  }

  // MARK: - money(_:) tests

  func testMoneyBelowHundred() {
    XCTAssertEqual(money(99.99), "$99.99")
    XCTAssertEqual(money(0.50), "$0.50")
    XCTAssertEqual(money(0.00), "$0.00")
  }

  func testMoneyExactlyHundred() {
    XCTAssertEqual(money(100.0), "$100")
  }

  func testMoneyAboveHundred() {
    XCTAssertEqual(money(150.75), "$151")
    XCTAssertEqual(money(999.99), "$1000")
  }

  // MARK: - fmt(_:) tests

  func testFmtBelowThousand() {
    XCTAssertEqual(fmt(999), "999")
    XCTAssertEqual(fmt(0), "0")
    XCTAssertEqual(fmt(1), "1")
  }

  func testFmtExactlyThousand() {
    XCTAssertEqual(fmt(1000), "1k")
  }

  func testFmtThousands() {
    XCTAssertEqual(fmt(1500), "2k")
    XCTAssertEqual(fmt(999_999), "1000k")
  }

  func testFmtMillion() {
    XCTAssertEqual(fmt(1_000_000), "1.0M")
    XCTAssertEqual(fmt(1_500_000), "1.5M")
  }

  // MARK: - span(_:) tests

  func testSpanZero() {
    XCTAssertEqual(span(0), "0m")
  }

  func testSpanMinutes() {
    XCTAssertEqual(span(60), "1m")
    XCTAssertEqual(span(3599), "59m")
  }

  func testSpanHours() {
    XCTAssertEqual(span(3600), "1h 0m")
    XCTAssertEqual(span(7200), "2h 0m")
  }

  func testSpanDays() {
    XCTAssertEqual(span(86400), "1d 0h")
    XCTAssertEqual(span(172800), "2d 0h")
  }

  func testSpanNegative() {
    XCTAssertEqual(span(-100), "0m")
  }

  // MARK: - clock(_:) tests

  func testClockToday() {
    let now = Date()
    let result = clock(now)
    // Should be in HH:mm format for today
    XCTAssertTrue(result.contains(":"))
    XCTAssertFalse(result.contains(" "))
  }

  func testClockFutureDate() {
    // A date far in the future
    let future = Date(timeIntervalSinceNow: 86400 * 10)
    let result = clock(future)
    // Should be in "EEE HH:mm" format (e.g., "Wed 14:30")
    XCTAssertTrue(result.contains(" "))
  }
}
