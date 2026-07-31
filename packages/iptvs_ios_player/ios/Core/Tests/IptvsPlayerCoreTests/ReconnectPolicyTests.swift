import XCTest
@testable import IptvsPlayerCore

/// Mirrors `android/app/src/test/kotlin/.../player/ReconnectPolicyTest.kt` and
/// `test/reconnect_policy_test.dart`'s `reconnectMinGapMs` group. Values here
/// must stay numerically identical to both.
final class ReconnectPolicyTests: XCTestCase {
  func testFirstAttemptWaitsOneStallInterval() {
    XCTAssertEqual(
      ReconnectPolicy.minGapMs(priorAttempts: 0, force: false),
      ReconnectPolicy.stallReconnectMs
    )
  }

  func testBackoffGrowsWithEachPriorAttempt() {
    XCTAssertEqual(
      ReconnectPolicy.minGapMs(priorAttempts: 1, force: false),
      ReconnectPolicy.stallReconnectMs * 2
    )
    XCTAssertEqual(
      ReconnectPolicy.minGapMs(priorAttempts: 2, force: false),
      ReconnectPolicy.stallReconnectMs * 3
    )
  }

  func testBackoffIsCappedAtTheMaximum() {
    XCTAssertEqual(
      ReconnectPolicy.minGapMs(priorAttempts: 3, force: false),
      ReconnectPolicy.maxBackoffMs
    )
    XCTAssertEqual(
      ReconnectPolicy.minGapMs(priorAttempts: 10, force: false),
      ReconnectPolicy.maxBackoffMs
    )
  }

  func testForcedReconnectAlwaysUsesTheBaseStallThreshold() {
    XCTAssertEqual(
      ReconnectPolicy.minGapMs(priorAttempts: 5, force: true),
      ReconnectPolicy.stallReconnectMs
    )
  }
}
