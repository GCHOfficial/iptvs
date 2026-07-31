import XCTest
@testable import IptvsPlayerCore

/// Ports the table from `test/dynamic_range_test.dart`. Output strings must
/// stay byte-identical to the Dart `dynamicRangeLabelFrom`/`isHdrColorimetry`
/// pair, including the middle-dot separator.
final class DynamicRangeLabelTests: XCTestCase {
  func testPqGammaIsHdr10PqUpgradedToHdr10PlusWithDynamicMetadata() {
    XCTAssertEqual(dynamicRangeLabel(gamma: "pq"), "HDR10 · PQ")
    XCTAssertEqual(dynamicRangeLabel(gamma: "pq", hdr10Plus: true), "HDR10+ · PQ")
  }

  func testHlgGammaIsHlg() {
    XCTAssertEqual(dynamicRangeLabel(gamma: "hlg"), "HLG")
  }

  func testDolbyVisionWinsFromEitherGammaOrMatrix() {
    XCTAssertEqual(dynamicRangeLabel(matrix: "dolbyvision"), "Dolby Vision")
    XCTAssertEqual(dynamicRangeLabel(gamma: "dolby"), "Dolby Vision")
  }

  func testBt2020PrimariesWithoutAPqHlgGammaIsHdrBt2020() {
    XCTAssertEqual(dynamicRangeLabel(primaries: "bt.2020"), "HDR · BT.2020")
  }

  func testEmptyColorimetryIsUnknownPopulatedButPlainIsSdr() {
    XCTAssertEqual(dynamicRangeLabel(), "")
    XCTAssertEqual(dynamicRangeLabel(gamma: "bt.1886", primaries: "bt.709"), "SDR")
  }

  func testIsHdrColorimetryTrueForPqHlgDolbyVisionBt2020() {
    XCTAssertTrue(isHdrColorimetry(gamma: "pq"))
    XCTAssertTrue(isHdrColorimetry(gamma: "hlg"))
    XCTAssertTrue(isHdrColorimetry(matrix: "dolbyvision"))
    XCTAssertTrue(isHdrColorimetry(primaries: "bt.2020"))
  }

  func testIsHdrColorimetryFalseForSdrAndForUnknownEmptyColorimetry() {
    XCTAssertFalse(isHdrColorimetry(gamma: "bt.1886", primaries: "bt.709"))
    XCTAssertFalse(isHdrColorimetry())
    XCTAssertFalse(isHdrColorimetry(gamma: "", primaries: "", matrix: ""))
  }
}
