import XCTest
@testable import IptvsPlayerCore

/// Mirrors the rule table documented on `selectEngine` and on Dart's
/// `selectIosEngine` (`lib/player/ios_engine.dart`) — this Swift copy omits
/// only that function's rule 1 (the per-session AVPlayer-failure memo), which
/// is caller-side runtime state rather than a pure function of the URL.
final class EngineSelectionTests: XCTestCase {
  func testKnownAvPlayerContainersRouteToAvPlayer() {
    XCTAssertEqual(selectEngine(url: "https://host/live/1.m3u8"), .avPlayer)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.mp4"), .avPlayer)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.m4v"), .avPlayer)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.mov"), .avPlayer)
    XCTAssertEqual(selectEngine(url: "http://host/audio/track.m4a"), .avPlayer)
    XCTAssertEqual(selectEngine(url: "http://host/audio/track.mp3"), .avPlayer)
    XCTAssertEqual(selectEngine(url: "http://host/audio/track.aac"), .avPlayer)
  }

  func testKnownMpvOnlyContainersRouteToMpv() {
    XCTAssertEqual(selectEngine(url: "http://host/live/1.ts"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/live/1.m2ts"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.mkv"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.avi"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.flv"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.webm"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.mpg"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.mpeg"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.wmv"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.vob"), .mpv)
  }

  func testNoExtensionOrUnknownExtensionRoutesToMpv() {
    // Extension-less locators are the common Stalker/MAG `create_link` shape.
    XCTAssertEqual(selectEngine(url: "http://host/play/create_link/abc123"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie.xyz"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host"), .mpv)
  }

  func testDisallowedSchemesAlwaysRouteToMpvRegardlessOfExtension() {
    XCTAssertEqual(selectEngine(url: "rtmp://host/live/1.m3u8"), .mpv)
    XCTAssertEqual(selectEngine(url: "rtsp://host/live/1.mp4"), .mpv)
    XCTAssertEqual(selectEngine(url: "udp://239.0.0.1:1234"), .mpv)
    XCTAssertEqual(selectEngine(url: "mms://host/stream"), .mpv)
  }

  func testFileSchemeIsAllowed() {
    XCTAssertEqual(selectEngine(url: "file:///var/mobile/Containers/movie.mp4"), .avPlayer)
  }

  func testQueryStringAndFragmentAreStrippedBeforeReadingTheExtension() {
    // The real extension is `.ts`; a naive parser that didn't strip the
    // query could be fooled by the `ext=.mp4` query param into misreading it.
    XCTAssertEqual(selectEngine(url: "http://host/live/1.ts?token=x&ext=.mp4"), .mpv)
    XCTAssertEqual(selectEngine(url: "http://host/live/1.m3u8#t=30"), .avPlayer)
  }

  func testCaseInsensitiveSchemeAndExtension() {
    XCTAssertEqual(selectEngine(url: "HTTP://host/vod/MOVIE.MP4"), .avPlayer)
  }

  func testUnparseableUrlRoutesToMpv() {
    XCTAssertEqual(selectEngine(url: ""), .mpv)
  }

  func testDotfileLastSegmentIsNotMistakenForAnExtension() {
    // A segment that IS the dot (nothing before it, e.g. a bare ".mp4" path
    // component) is a dotfile, not "extension mp4" — mirrors Dart's
    // `_extensionOf`, which excludes `dot <= 0`.
    XCTAssertEqual(selectEngine(url: "http://host/vod/.mp4"), .mpv)
  }

  func testTrailingDotWithNothingAfterHasNoExtension() {
    XCTAssertEqual(selectEngine(url: "http://host/vod/movie."), .mpv)
  }
}
