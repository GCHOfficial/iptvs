import XCTest
@testable import IptvsPlayerCore

/// Mirrors `android/app/src/test/kotlin/.../player/PlayerBackPolicyTest.kt`
/// (the `nextPlayerBackAction` table only — `PlayerBackGuard`'s duplicate-press
/// window is an Android TV dual-dispatch workaround with no iOS counterpart).
final class PlayerBackPolicyTests: XCTestCase {
  func testBackPeelsExactlyOnePlayerLayer() {
    XCTAssertEqual(
      nextPlayerBackAction(menuOpen: true, infoOpen: true, controlsVisible: true),
      .closeMenu
    )
    XCTAssertEqual(
      nextPlayerBackAction(menuOpen: false, infoOpen: true, controlsVisible: true),
      .closeInfo
    )
    XCTAssertEqual(
      nextPlayerBackAction(menuOpen: false, infoOpen: false, controlsVisible: true),
      .hideControls
    )
    XCTAssertEqual(
      nextPlayerBackAction(menuOpen: false, infoOpen: false, controlsVisible: false),
      .exit
    )
  }
}
