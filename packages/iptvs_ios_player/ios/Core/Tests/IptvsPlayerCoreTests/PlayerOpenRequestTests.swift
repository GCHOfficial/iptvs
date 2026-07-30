import XCTest
@testable import IptvsPlayerCore

/// Pins the `open` payload contract against `_tryOpenNativeHdrPlayer`
/// (`lib/player/player_screen.dart`) and, through it, against Android's
/// `MainActivity`/`HdrPlayerActivity` unpacking of the same map.
///
/// Every assertion here stands in for a failure that is otherwise **silent on a
/// device**: a mistyped key doesn't crash, it just quietly removes the EPG
/// strip, the favorite star, or the VOD resume point. The numeric tests matter
/// most — Dart sends EPG epochs as doubles and `resumeMs` as an int, so a
/// uniform `as? Int` read would work for one and fail for the other.
final class PlayerOpenRequestTests: XCTestCase {
  private func arguments(_ overrides: [String: Any] = [:]) -> [AnyHashable: Any] {
    var map: [AnyHashable: Any] = [
      "url": "https://example.test/live/1.m3u8",
      "title": "Channel One",
      "isLive": true,
    ]
    for (key, value) in overrides { map[key] = value }
    return map
  }

  // MARK: - Acceptance

  func testParsesTheMinimalPayload() {
    let request = PlayerOpenRequest(arguments: arguments())
    XCTAssertEqual(request?.url, "https://example.test/live/1.m3u8")
    XCTAssertEqual(request?.title, "Channel One")
    XCTAssertEqual(request?.isLive, true)
    XCTAssertEqual(request?.resumeMs, 0)
    XCTAssertEqual(request?.canFavorite, false)
    XCTAssertEqual(request?.isFavorite, false)
    XCTAssertNil(request?.sourceName)
    XCTAssertNil(request?.soakAutoCloseMs)
    XCTAssertEqual(request?.headers, [String: String]())
    XCTAssertEqual(request?.subtitles, [PlayerSubtitleSpec]())
  }

  func testRejectsANonMapArgument() {
    XCTAssertNil(PlayerOpenRequest(arguments: nil))
    XCTAssertNil(PlayerOpenRequest(arguments: "not a map"))
    XCTAssertNil(PlayerOpenRequest(arguments: [1, 2, 3]))
  }

  func testRejectsAMissingOrBlankUrl() {
    XCTAssertNil(PlayerOpenRequest(arguments: ["title": "no url"]))
    XCTAssertNil(PlayerOpenRequest(arguments: arguments(["url": ""])))
    XCTAssertNil(PlayerOpenRequest(arguments: arguments(["url": "   \n "])))
    XCTAssertNil(PlayerOpenRequest(arguments: arguments(["url": 42])))
  }

  // MARK: - Numerics (NSNumber bridging)

  func testResumeMsAcceptsAnIntAndClampsNegatives() {
    XCTAssertEqual(PlayerOpenRequest(arguments: arguments(["resumeMs": 90_000]))?.resumeMs, 90_000)
    XCTAssertEqual(PlayerOpenRequest(arguments: arguments(["resumeMs": -5]))?.resumeMs, 0)
    XCTAssertEqual(PlayerOpenRequest(arguments: arguments([:]))?.resumeMs, 0)
  }

  func testEpgEpochsArriveAsDoublesAndStillParse() {
    // `_epgPayload()` sends `millisecondsSinceEpoch.toDouble()`; reading these
    // as `as? Int` would return nil and drop the whole programme.
    let request = PlayerOpenRequest(
      arguments: arguments([
        "epgNowTitle": "The News",
        "epgNowStartMs": 1_700_000_000_000.0,
        "epgNowStopMs": 1_700_003_600_000.0,
        "epgNowDesc": "Headlines",
        "epgNextTitle": "Weather",
        "epgNextStartMs": 1_700_003_600_000.0,
        "epgNextStopMs": 1_700_005_400_000.0,
      ])
    )
    XCTAssertEqual(request?.epgNow?.title, "The News")
    XCTAssertEqual(request?.epgNow?.startMs, 1_700_000_000_000)
    XCTAssertEqual(request?.epgNow?.stopMs, 1_700_003_600_000)
    XCTAssertEqual(request?.epgNow?.description, "Headlines")
    XCTAssertEqual(request?.epgNext?.title, "Weather")
    XCTAssertNil(request?.epgNext?.description, "next has no description key by contract")
  }

  func testSoakAutoCloseSurvivesOnlyWhenPositive() {
    XCTAssertEqual(
      PlayerOpenRequest(arguments: arguments(["soakAutoCloseMs": 4_000]))?.soakAutoCloseMs,
      4_000
    )
    XCTAssertNil(PlayerOpenRequest(arguments: arguments(["soakAutoCloseMs": 0]))?.soakAutoCloseMs)
    XCTAssertNil(PlayerOpenRequest(arguments: arguments(["soakAutoCloseMs": -1]))?.soakAutoCloseMs)
  }

  // MARK: - EPG validity (port of HdrPlayerActivity.epgEntry)

  func testEpgEntryNeedsATitleAndAForwardTimeRange() {
    func epg(_ overrides: [String: Any]) -> PlayerEpgEntry? {
      PlayerOpenRequest(arguments: arguments(overrides))?.epgNow
    }
    XCTAssertNil(epg(["epgNowStartMs": 10.0, "epgNowStopMs": 20.0]), "no title")
    XCTAssertNil(epg(["epgNowTitle": "  ", "epgNowStartMs": 10.0, "epgNowStopMs": 20.0]))
    XCTAssertNil(epg(["epgNowTitle": "T", "epgNowStartMs": -1.0, "epgNowStopMs": 20.0]))
    XCTAssertNil(epg(["epgNowTitle": "T", "epgNowStartMs": 20.0, "epgNowStopMs": 20.0]), "zero span")
    XCTAssertNil(epg(["epgNowTitle": "T", "epgNowStartMs": 30.0, "epgNowStopMs": 20.0]), "reversed")
    XCTAssertNil(epg(["epgNowTitle": "T", "epgNowStartMs": 10.0]), "missing stop")
    XCTAssertNotNil(epg(["epgNowTitle": "T", "epgNowStartMs": 10.0, "epgNowStopMs": 20.0]))
  }

  func testEpgProgressIsClampedToTheProgrammeWindow() {
    let entry = PlayerEpgEntry(title: "T", startMs: 1_000, stopMs: 3_000)
    XCTAssertEqual(entry.progress(at: 0), 0)
    XCTAssertEqual(entry.progress(at: 1_000), 0)
    XCTAssertEqual(entry.progress(at: 2_000), 0.5)
    XCTAssertEqual(entry.progress(at: 3_000), 1)
    XCTAssertEqual(entry.progress(at: 9_999), 1)
  }

  func testDegenerateProgrammeSpanDoesNotDivideByZero() {
    let entry = PlayerEpgEntry(title: "T", startMs: 5, stopMs: 5)
    XCTAssertEqual(entry.progress(at: 5), 0)
  }

  // MARK: - Headers

  func testHeadersDropBlankKeysAndValuesAndStringifyNonStrings() {
    let request = PlayerOpenRequest(
      arguments: arguments([
        "headers": [
          "User-Agent": "MAG250",
          "Referer": "http://portal.test/",
          "": "orphan value",
          "   ": "blank key",
          "Blank": "",
          "Numeric": 7,
        ] as [AnyHashable: Any],
      ])
    )
    XCTAssertEqual(request?.headers["User-Agent"], "MAG250")
    XCTAssertEqual(request?.headers["Referer"], "http://portal.test/")
    XCTAssertEqual(request?.headers["Numeric"], "7")
    XCTAssertNil(request?.headers[""])
    XCTAssertNil(request?.headers["   "])
    XCTAssertNil(request?.headers["Blank"])
  }

  func testAbsentOrMistypedHeadersAreAnEmptyMapNotAFailure() {
    XCTAssertEqual(PlayerOpenRequest(arguments: arguments([:]))?.headers, [String: String]())
    XCTAssertEqual(
      PlayerOpenRequest(arguments: arguments(["headers": "nope"]))?.headers,
      [String: String]()
    )
  }

  // MARK: - Subtitles

  func testSubtitlesDropBlankUrlsAndDefaultLabels() {
    let request = PlayerOpenRequest(
      arguments: arguments([
        "subtitles": [
          ["url": "https://example.test/a.srt", "label": "English", "language": "en"],
          ["url": "https://example.test/b.srt"],
          ["url": ""],
          ["label": "no url"],
          "not a map",
        ] as [Any],
      ])
    )
    XCTAssertEqual(request?.subtitles.count, 2)
    XCTAssertEqual(
      request?.subtitles.first,
      PlayerSubtitleSpec(url: "https://example.test/a.srt", label: "English", language: "en")
    )
    XCTAssertEqual(
      request?.subtitles.last,
      PlayerSubtitleSpec(url: "https://example.test/b.srt", label: "", language: "")
    )
  }

  // MARK: - Favorite seed

  func testFavoriteSeedRoundTrips() {
    let request = PlayerOpenRequest(
      arguments: arguments(["canFavorite": true, "isFavorite": true])
    )
    XCTAssertEqual(request?.canFavorite, true)
    XCTAssertEqual(request?.isFavorite, true)
  }
}
