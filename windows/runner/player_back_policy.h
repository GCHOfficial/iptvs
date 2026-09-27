#ifndef RUNNER_PLAYER_BACK_POLICY_H_
#define RUNNER_PLAYER_BACK_POLICY_H_

// Pure Back-ladder policy for the Windows native HWND player surface.
//
// A structural mirror of
// `android/app/src/main/kotlin/com/gchofficial/iptvs/player/PlayerBackPolicy.kt`
// (`nextPlayerBackAction`), and it exists for the same reason the Kotlin one
// does: **one press peels exactly one layer**. Escape used to exit the player
// outright from `FlutterWindow::MessageHandler`, even with a menu, the info
// panel or the whole control row on screen — so a user who had opened the
// audio menu and changed their mind was thrown back to the channel list.
//
// Deliberately **Windows-free** (no `<windows.h>`, no Flutter header), like
// `zap_key_policy.h` and `zap_quick_list_state.h`: this runner has no test
// harness, so the half of a decision that can at least be compiled and
// asserted on with a plain `g++` should be the half where a mistake is
// invisible.
//
// **Two rungs sit above this ladder and are deliberately not here**, both
// claimed by `iptvs::DecideZapKey` (`zap_key_policy.h`) before
// `MessageHandler` ever reaches the Escape branch:
//
//   1. a half-typed channel number, which Escape clears (`zap:back`), and
//   2. the quick list, whose mode stack is Dart's — Escape sends `zap:back`
//      and Dart decides which rung that meant.
//
// Kotlin *does* carry the quick-list rung in its ladder, because Android also
// reaches `nextPlayerBackAction` from the gesture-Back dispatcher, which never
// passes through `ZapKeyPolicy`. This surface has no second Back path — the
// overlay's visible Back arrow is an explicit Exit command, not a system Back
// — so repeating the rung here could only ever peel two of them for one press.
namespace iptvs {

// Exactly one layer consumed by one Escape press.
enum class PlayerBackAction {
  kCloseMenu,
  kCloseInfo,
  kHideControls,
  kExit,
};

// @param menu_open        a list menu (audio / subtitles / speed) is open.
// @param info_open        the stream-info panel is open.
// @param controls_visible the chrome (top bar + control row) is on screen.
//                         Read from `FlutterWindow::native_controls_visible_`,
//                         the chrome's authority — **not** from the overlay
//                         window's own visibility, which stays up for the zap
//                         banner and the quick list with the chrome down.
inline PlayerBackAction NextPlayerBackAction(bool menu_open, bool info_open,
                                             bool controls_visible) {
  if (menu_open) {
    return PlayerBackAction::kCloseMenu;
  }
  if (info_open) {
    return PlayerBackAction::kCloseInfo;
  }
  if (controls_visible) {
    return PlayerBackAction::kHideControls;
  }
  return PlayerBackAction::kExit;
}

} // namespace iptvs

#endif // RUNNER_PLAYER_BACK_POLICY_H_
