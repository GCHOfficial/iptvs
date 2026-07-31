import XCTest
@testable import IptvsPlayerCore

/// Ports the badge-formatting table from Android's
/// `PlayerUiState`/`PlayerControls.kt` (there is no standalone Kotlin test
/// file for these — they're exercised only through Compose preview/manual
/// QA — so this table is derived directly from the Kotlin implementation).
final class BadgeFormattingTests: XCTestCase {
  func testResolutionBadgeBucketsByHeightOrWidth() {
    XCTAssertNil(BadgeFormatting.resolutionBadge(width: 0, height: 0))
    XCTAssertNil(BadgeFormatting.resolutionBadge(width: -1, height: 1080))
    XCTAssertEqual(BadgeFormatting.resolutionBadge(width: 640, height: 480), "SD")
    XCTAssertEqual(BadgeFormatting.resolutionBadge(width: 1280, height: 720), "720p")
    XCTAssertEqual(BadgeFormatting.resolutionBadge(width: 1920, height: 1080), "1080p")
    XCTAssertEqual(BadgeFormatting.resolutionBadge(width: 2560, height: 1440), "1440p")
    XCTAssertEqual(BadgeFormatting.resolutionBadge(width: 3840, height: 2160), "4K")
    // Width alone can cross a bucket boundary even if height doesn't (an
    // ultra-wide / anamorphic source), matching the Kotlin `||` gate.
    XCTAssertEqual(BadgeFormatting.resolutionBadge(width: 3500, height: 480), "4K")
  }

  func testHdrBadgeDerivesFromTheFormattedDynamicRangeLabel() {
    XCTAssertEqual(BadgeFormatting.hdrBadge(dynamicRange: "Dolby Vision"), "DV")
    XCTAssertEqual(BadgeFormatting.hdrBadge(dynamicRange: "HDR10+ · PQ"), "HDR10+")
    XCTAssertEqual(BadgeFormatting.hdrBadge(dynamicRange: "HDR10 · PQ"), "HDR10")
    XCTAssertEqual(BadgeFormatting.hdrBadge(dynamicRange: "HLG"), "HLG")
    XCTAssertEqual(BadgeFormatting.hdrBadge(dynamicRange: "HDR · BT.2020"), "HDR")
    XCTAssertNil(BadgeFormatting.hdrBadge(dynamicRange: "SDR"))
    XCTAssertNil(BadgeFormatting.hdrBadge(dynamicRange: ""))
  }

  func testFpsBadgeFormatsWholeAndFractionalRatesDifferently() {
    XCTAssertNil(BadgeFormatting.fpsBadge(fps: 0))
    XCTAssertNil(BadgeFormatting.fpsBadge(fps: -25))
    XCTAssertEqual(BadgeFormatting.fpsBadge(fps: 25), "25fps")
    XCTAssertEqual(BadgeFormatting.fpsBadge(fps: 50), "50fps")
    XCTAssertEqual(BadgeFormatting.fpsBadge(fps: 23.976), "23.976fps")
    XCTAssertEqual(BadgeFormatting.fpsBadge(fps: 29.97), "29.97fps")
  }

  func testSourceBadgeTrimsAndTruncatesLongNames() {
    XCTAssertNil(BadgeFormatting.sourceBadge(name: nil))
    XCTAssertNil(BadgeFormatting.sourceBadge(name: "   "))
    XCTAssertEqual(BadgeFormatting.sourceBadge(name: "  My Provider  "), "My Provider")
    XCTAssertEqual(
      BadgeFormatting.sourceBadge(name: "Exactly Twenty Chars"),
      "Exactly Twenty Chars"
    )
    XCTAssertEqual(
      BadgeFormatting.sourceBadge(name: "A Provider Name That Is Far Too Long"),
      "A Provider Name Tha…"
    )
  }

  func testFormatTimeMirrorsTheAndroidLabelShape() {
    XCTAssertEqual(BadgeFormatting.formatTime(ms: 0), "0:00")
    XCTAssertEqual(BadgeFormatting.formatTime(ms: -500), "0:00")
    XCTAssertEqual(BadgeFormatting.formatTime(ms: 5_000), "0:05")
    XCTAssertEqual(BadgeFormatting.formatTime(ms: 187_000), "3:07")
    XCTAssertEqual(BadgeFormatting.formatTime(ms: 3_723_000), "1:02:03")
  }
}
