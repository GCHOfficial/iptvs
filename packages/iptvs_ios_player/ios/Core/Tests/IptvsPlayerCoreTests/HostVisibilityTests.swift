import XCTest
@testable import IptvsPlayerCore

/// Pins the Swift half of the `engineFailed` / `hostVisibility` contract that
/// `lib/player/player_screen.dart` parses (`_handleIosEngineFailed`,
/// `_handleIosHostVisibility`, `decideIosFallbackAction`) and that
/// `test/ios_fallback_gate_test.dart` covers from the Dart side.
///
/// The one behaviour worth a test rather than a comment: an unknown PiP state
/// must be an **omitted key**, not `false`. Dart distinguishes the two — a
/// missing key is "no opinion", a `false` is an authoritative "PiP is off" that
/// clears the veto — so a plugin build with no PiP controller yet must not
/// accidentally tell Dart it is safe to open libmpv.
final class HostVisibilityTests: XCTestCase {
  func testHostVisibilityPayloadCarriesAppState() {
    let payload = PlaybackEventPayload.hostVisibility(
      HostVisibility(appActive: true, pipActive: false)
    )
    XCTAssertEqual(
      payload[PlaybackEventPayload.eventKey] as? String,
      PlaybackEventPayload.hostVisibilityEvent
    )
    XCTAssertEqual(payload["appActive"] as? Bool, true)
    XCTAssertEqual(payload["pipActive"] as? Bool, false)
  }

  func testUnknownPipStateIsOmittedRatherThanReportedFalse() {
    let payload = PlaybackEventPayload.hostVisibility(
      HostVisibility(appActive: false, pipActive: nil)
    )
    XCTAssertEqual(payload["appActive"] as? Bool, false)
    XCTAssertNil(
      payload["pipActive"],
      "an unknown PiP state must reach Dart as an absent key, never as false"
    )
  }

  func testEngineFailedPayloadShape() {
    let payload = PlaybackEventPayload.engineFailed(
      reason: "AVPlayerItemFailedToPlayToEndTime",
      positionMs: 42_000,
      pipWasActive: true,
      visibility: HostVisibility(appActive: false, pipActive: true)
    )
    XCTAssertEqual(
      payload[PlaybackEventPayload.eventKey] as? String,
      PlaybackEventPayload.engineFailedEvent
    )
    XCTAssertEqual(payload["positionMs"] as? Int, 42_000)
    XCTAssertEqual(payload["pipWasActive"] as? Bool, true)
    XCTAssertEqual(payload["reason"] as? String, "AVPlayerItemFailedToPlayToEndTime")
    // The emit-time host snapshot rides on the failure event itself, so Dart's
    // very first evaluation already has the authoritative facts and never has
    // to guess from a lifecycle state that may not have moved.
    XCTAssertEqual(payload["appActive"] as? Bool, false)
    XCTAssertEqual(payload["pipActive"] as? Bool, true)
  }

  func testEngineFailedOmitsAbsentReason() {
    let payload = PlaybackEventPayload.engineFailed(
      reason: nil,
      positionMs: 0,
      pipWasActive: false,
      visibility: HostVisibility(appActive: true, pipActive: nil)
    )
    XCTAssertNil(payload["reason"])
    XCTAssertNil(payload["pipActive"])
    XCTAssertEqual(payload["positionMs"] as? Int, 0)
  }

  // Results are hoisted into locals before asserting: `changeToEmit` is
  // `mutating`, and calling it inside an `XCTAssert*` autoclosure is needless
  // risk in a file no local toolchain can compile.
  func testTrackerEmitsOnlyOnChange() {
    var tracker = HostVisibilityTracker()
    let active = HostVisibility(appActive: true, pipActive: false)
    let first = tracker.changeToEmit(active)
    let repeated = tracker.changeToEmit(active)
    let backgrounded = tracker.changeToEmit(HostVisibility(appActive: false, pipActive: false))
    let returned = tracker.changeToEmit(active)
    XCTAssertEqual(first, active)
    XCTAssertNil(repeated)
    XCTAssertEqual(backgrounded, HostVisibility(appActive: false, pipActive: false))
    XCTAssertEqual(returned, active)
  }

  func testTrackerTreatsUnknownPipAsDistinctFromFalse() {
    var tracker = HostVisibilityTracker()
    let unknown = tracker.changeToEmit(HostVisibility(appActive: true, pipActive: nil))
    let known = tracker.changeToEmit(HostVisibility(appActive: true, pipActive: false))
    XCTAssertNotNil(unknown)
    XCTAssertNotNil(
      known,
      "gaining a real PiP answer is a change Dart must be told about"
    )
  }

  func testTrackerResetForcesTheNextEmit() {
    var tracker = HostVisibilityTracker()
    let active = HostVisibility(appActive: true, pipActive: false)
    let first = tracker.changeToEmit(active)
    let repeated = tracker.changeToEmit(active)
    tracker.reset()
    let afterReset = tracker.changeToEmit(active)
    XCTAssertNotNil(first)
    XCTAssertNil(repeated)
    XCTAssertNotNil(
      afterReset,
      "a new Dart channel owner has seen nothing, so the memo must not suppress"
    )
  }
}
