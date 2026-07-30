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

  /// docs/tv-navigation.md, Back-ladder section: **iOS has no hardware Back**,
  /// so touch is the ladder's input — "tapping outside the chrome … closes an
  /// open menu, then the info panel … while tapping the exposed video with
  /// chrome hidden just toggles the chrome visible".
  ///
  /// The first three rungs must be identical to the Back ladder's, and only the
  /// terminal one differs: a tap can never exit, because exiting is the
  /// overlay's X alone.
  func testTapPeelsTheSameRungsButRevealsInsteadOfExiting() {
    XCTAssertEqual(
      playerTapAction(menuOpen: true, infoOpen: true, controlsVisible: true),
      .closeMenu
    )
    XCTAssertEqual(
      playerTapAction(menuOpen: false, infoOpen: true, controlsVisible: true),
      .closeInfo
    )
    XCTAssertEqual(
      playerTapAction(menuOpen: false, infoOpen: false, controlsVisible: true),
      .hideControls
    )
    XCTAssertEqual(
      playerTapAction(menuOpen: false, infoOpen: false, controlsVisible: false),
      .showControls,
      "a tap on hidden chrome reveals it; only the X exits"
    )
  }

  /// The two ladders are one table with a swapped last rung, and this asserts
  /// exactly that — so a future edit to either has to break this test before it
  /// can let them disagree about rung *order*.
  func testTapAndBackAgreeOnEveryRungExceptTheTerminalOne() {
    for menuOpen in [true, false] {
      for infoOpen in [true, false] {
        for controlsVisible in [true, false] {
          let back = nextPlayerBackAction(
            menuOpen: menuOpen,
            infoOpen: infoOpen,
            controlsVisible: controlsVisible
          )
          let tap = playerTapAction(
            menuOpen: menuOpen,
            infoOpen: infoOpen,
            controlsVisible: controlsVisible
          )
          switch back {
          case .closeMenu: XCTAssertEqual(tap, .closeMenu)
          case .closeInfo: XCTAssertEqual(tap, .closeInfo)
          case .hideControls: XCTAssertEqual(tap, .hideControls)
          case .exit: XCTAssertEqual(tap, .showControls)
          }
        }
      }
    }
  }
}
