import Foundation

/// Exactly one layer consumed by a system/remote Back press.
///
/// Port of Android's `com.gchofficial.iptvs.player.PlayerBackAction`
/// (`android/app/src/main/kotlin/.../player/PlayerBackPolicy.kt`). Mirrors the
/// same enum, in the same order, for the same reason: keeping this decision
/// outside UI event handling prevents one Back press from being interpreted
/// once by a focused control and again by the owning screen.
public enum PlayerBackAction: Equatable {
  case closeMenu
  case closeInfo
  case hideControls
  case exit
}

/// Pure Back-ladder policy shared by every input source that can trigger a
/// Back-equivalent action on the iOS player screen.
///
/// Port of Android's `nextPlayerBackAction`. Table, in priority order:
/// a menu open closes first, then the info panel, then the controls overlay,
/// and only then does Back fall through to exiting the player.
public func nextPlayerBackAction(
  menuOpen: Bool,
  infoOpen: Bool,
  controlsVisible: Bool
) -> PlayerBackAction {
  if menuOpen { return .closeMenu }
  if infoOpen { return .closeInfo }
  if controlsVisible { return .hideControls }
  return .exit
}
