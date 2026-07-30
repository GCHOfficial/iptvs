import XCTest
@testable import IptvsPlayerCore

/// Pins the `nativePlayback` playback-state/progress payloads.
///
/// Two things here are contract rather than convenience. First, the event
/// strings must match the vocabulary the other three platforms already use
/// (`started`/`stalled`/`resumed`/`ended`/`dropped`), because Dart's
/// `nativePlayback` switch and the exported diagnostics log are read side by
/// side with Android's and Linux's. Second, `message` must never be able to
/// carry a URL: provider URLs embed credentials in both the query string and
/// the path, and an exported diagnostics log is something users are asked to
/// share (CLAUDE.md, "Secrets must never reach logs…").
final class PlaybackStateEventsTests: XCTestCase {
  func testEventNamesMatchTheCrossPlatformVocabulary() {
    XCTAssertEqual(PlaybackStateEvent.started.rawValue, "started")
    XCTAssertEqual(PlaybackStateEvent.stalled.rawValue, "stalled")
    XCTAssertEqual(PlaybackStateEvent.resumed.rawValue, "resumed")
    XCTAssertEqual(PlaybackStateEvent.ended.rawValue, "ended")
    XCTAssertEqual(PlaybackStateEvent.dropped.rawValue, "dropped")
    XCTAssertEqual(PlaybackStateEvent.allCases.count, 5, "a new state needs a doc + Dart decision")
  }

  func testPlaybackStatePayloadShape() {
    let payload = PlaybackEventPayload.playbackState(
      .started,
      positionMs: 1_500,
      durationMs: 7_200_000
    )
    XCTAssertEqual(payload[PlaybackEventPayload.eventKey] as? String, "started")
    XCTAssertEqual(payload[PlaybackEventPayload.positionKey] as? Int, 1_500)
    XCTAssertEqual(payload[PlaybackEventPayload.durationKey] as? Int, 7_200_000)
    XCTAssertNil(payload[PlaybackEventPayload.messageKey], "no message unless one is supplied")
  }

  func testPlaybackStateCarriesAnOptionalShortCode() {
    let payload = PlaybackEventPayload.playbackState(
      .dropped,
      positionMs: 0,
      durationMs: 0,
      message: PlaybackEventPayload.errorCode(domain: "NSURLErrorDomain", code: -1_001)
    )
    XCTAssertEqual(payload[PlaybackEventPayload.messageKey] as? String, "NSURLErrorDomain:-1001")
  }

  func testErrorCodeCarriesNoHumanReadableTextThatCouldEmbedAUrl() {
    let code = PlaybackEventPayload.errorCode(domain: "AVFoundationErrorDomain", code: -11_828)
    XCTAssertEqual(code, "AVFoundationErrorDomain:-11828")
    XCTAssertFalse(code.contains("/"), "an error code must never be able to carry a URL")
    XCTAssertFalse(code.contains(" "))
  }

  func testProgressPayloadShape() {
    let payload = PlaybackEventPayload.progress(
      positionMs: 42_000,
      durationMs: 0,
      playing: true,
      buffering: false
    )
    XCTAssertEqual(payload[PlaybackEventPayload.eventKey] as? String, "progress")
    XCTAssertEqual(payload[PlaybackEventPayload.positionKey] as? Int, 42_000)
    XCTAssertEqual(payload[PlaybackEventPayload.durationKey] as? Int, 0)
    XCTAssertEqual(payload["playing"] as? Bool, true)
    XCTAssertEqual(payload["buffering"] as? Bool, false)
  }

  /// A live stream's duration is `CMTime.indefinite` and a cold position is
  /// `CMTime.invalid`; both convert to NaN/negative seconds. Dart's
  /// `nativeClosed` handler keys "no useful duration" off `durationMs > 0`, so
  /// anything unknown has to arrive as exactly `0` — not `-1`, not a huge
  /// wrapped value.
  func testUnknownTimesNormaliseToZero() {
    XCTAssertEqual(PlaybackEventPayload.normalizedMs(-1), 0)
    XCTAssertEqual(PlaybackEventPayload.normalizedMs(Int64.min), 0)
    XCTAssertEqual(PlaybackEventPayload.normalizedMs(0), 0)
    XCTAssertEqual(PlaybackEventPayload.normalizedMs(1), 1)

    let payload = PlaybackEventPayload.playbackState(.ended, positionMs: -7, durationMs: -7)
    XCTAssertEqual(payload[PlaybackEventPayload.positionKey] as? Int, 0)
    XCTAssertEqual(payload[PlaybackEventPayload.durationKey] as? Int, 0)
  }

  /// `progress` is a tick, not a transition — keeping it off the enum is what
  /// lets the Swift watchdog switch exhaustively over real state changes.
  func testProgressIsNotAStateTransition() {
    XCTAssertFalse(
      PlaybackStateEvent.allCases.map(\.rawValue).contains(PlaybackEventPayload.progressEvent)
    )
  }

  /// All `nativePlayback` payloads travel on one method name, discriminated by
  /// `event` — one inbound method keeps `ChannelHandlerOwner`'s ownership
  /// surface at a single channel (docs/player.md "MethodChannel handler
  /// ownership").
  func testEverythingRidesTheSingleNativePlaybackMethod() {
    XCTAssertEqual(PlaybackEventPayload.method, "nativePlayback")
  }
}
