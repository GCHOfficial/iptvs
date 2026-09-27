#ifndef RUNNER_ZAP_KEY_POLICY_H_
#define RUNNER_ZAP_KEY_POLICY_H_

#include <string>

// Pure key policy for in-player live zapping on the Windows native HWND
// surface, consulted by `FlutterWindow::MessageHandler` **before** every other
// key branch on that surface — the same placement Android's
// `HdrPlayerActivity.dispatchKeyEvent` gives `ZapKeyPolicy`, and for the same
// reason: one physical press must not be interpreted once here and again by
// the overlay's own focus ring.
//
// This is a structural mirror of
// `android/app/src/main/kotlin/com/gchofficial/iptvs/player/ZapKeyPolicy.kt`.
// Keep the two in step: the vocabulary they emit is parsed by one function
// (`parseZapCommand`, `lib/player/zap_command.dart`), so a divergence here is
// a navigation rule that differs per surface, which is exactly what the shared
// vocabulary exists to prevent.
//
// Deliberately **Windows-free** (raw virtual-key codes as plain ints, mirrored
// below rather than pulled from <windows.h>) so it can be reasoned about — and
// unit-tested, if this runner ever grows a C++ harness — without a Win32
// toolchain. `flutter_window.cpp` static_asserts each mirrored constant
// against the real `VK_*`, so a typo cannot ship silently.
//
// The state it needs is tiny, and all of it is already on this side of the
// wire: **Dart owns the channel list and the cursor**
// (`lib/player/live_zap_controller.dart`), so this decides only *which command
// to send*, never where the cursor lands.
namespace iptvs {

// [kSwallow] is not [kNone]: the key **was** ours and must be consumed without
// doing anything — a repeat of a key whose action makes no sense repeated.
// Returning [kNone] there would leak a held digit into the overlay's own focus
// traversal (and reveal the chrome), which is the same class of bug the live
// tab's digit handler swallows repeats to avoid.
enum class ZapKeyAction {
  kNone,
  kSwallow,
  kChannelUp,
  kChannelDown,
  kPreviousChannel,
  kOpenList,
  kCloseList,
  // Quick list open: move the cursor by [ZapKeyDecision::delta] rows. Separate
  // from [kChannelUp]/[kChannelDown] because the two diverge while the list is
  // on screen — D-pad Up must move the highlight *up*, while CHANNEL_UP still
  // means "the next channel", which is the next row *down* (docs/player.md,
  // "While the list is open, it owns navigation").
  kMove,
  // Right inside the quick list: one rung *down* the mode stack. Separate from
  // [kActivate] because in the channels mode OK plays while Right opens that
  // channel's schedule — giving Right its own string keeps this surface
  // mode-blind, which it has to be: Dart owns the mode stack.
  kDescend,
  kDigit,
  kActivate,
  kBack,
};

// One key's outcome. `command()` is the string to send to Dart on the shared
// zap vocabulary, or empty when nothing is sent.
struct ZapKeyDecision {
  ZapKeyAction action = ZapKeyAction::kNone;
  int digit = -1;
  // Signed row delta for [ZapKeyAction::kMove]; unused otherwise.
  int delta = 0;

  // Whether the window procedure must consume this press (return 0).
  bool consumed() const { return action != ZapKeyAction::kNone; }

  std::string command() const {
    switch (action) {
      case ZapKeyAction::kChannelUp:
        return "zap:up";
      case ZapKeyAction::kChannelDown:
        return "zap:down";
      case ZapKeyAction::kPreviousChannel:
        return "zap:prev";
      case ZapKeyAction::kOpenList:
        return "zap:list";
      case ZapKeyAction::kCloseList:
        return "zap:close";
      case ZapKeyAction::kMove:
        return "zap:move:" + std::to_string(delta);
      case ZapKeyAction::kDescend:
        return "zap:descend";
      case ZapKeyAction::kDigit:
        return "zap:digit:" + std::to_string(digit);
      case ZapKeyAction::kActivate:
        return "zap:activate";
      case ZapKeyAction::kBack:
        return "zap:back";
      case ZapKeyAction::kNone:
      case ZapKeyAction::kSwallow:
        break;
    }
    return std::string();
  }
};

// Mirrors of the `VK_*` / character virtual-key codes this policy reads,
// static_asserted against <windows.h> in flutter_window.cpp.
inline constexpr int kZapVkBack = 0x08;    // VK_BACK (backspace)
inline constexpr int kZapVkReturn = 0x0D;  // VK_RETURN
inline constexpr int kZapVkEscape = 0x1B;  // VK_ESCAPE
inline constexpr int kZapVkPrior = 0x21;   // VK_PRIOR (Page Up)
inline constexpr int kZapVkNext = 0x22;    // VK_NEXT  (Page Down)
inline constexpr int kZapVkLeft = 0x25;    // VK_LEFT
inline constexpr int kZapVkUp = 0x26;      // VK_UP
inline constexpr int kZapVkRight = 0x27;   // VK_RIGHT
inline constexpr int kZapVkDown = 0x28;    // VK_DOWN
inline constexpr int kZapVkSelect = 0x29;  // VK_SELECT (a remote's OK)
inline constexpr int kZapVkDigit0 = 0x30;  // '0'
inline constexpr int kZapVkDigit9 = 0x39;  // '9'
inline constexpr int kZapVkNumpad0 = 0x60; // VK_NUMPAD0
inline constexpr int kZapVkNumpad9 = 0x69; // VK_NUMPAD9
// This surface's stand-in for a remote's dedicated `GUIDE` key, which has no
// Win32 virtual-key code at all — the same stand-in relationship Page
// Up/Page Down have with CHANNEL_UP/CHANNEL_DOWN above. 'G' was picked
// because the native HWND surface's other letter shortcuts are F
// (fullscreen), M (mini-player), I (info) and S (star) and Dart's own
// `CallbackShortcuts` map binds no other letter, so nothing on this screen
// loses a key. A real remote reaches the list through Left.
inline constexpr int kZapVkGuide = 0x47; // 'G'

// Whether the quick list exists.
//
// This gated Left (and the guide key) out of the policy while Dart answered
// `zap:list` with "not consumed": the window procedure cannot wait for that
// answer — it has to return synchronously — so claiming Left into a decided
// no-op would have silently broken its present job of revealing the chrome.
// **Dart now consumes the whole quick-list vocabulary** (Phase 6), so this is
// true; the flag stays as the one switch that turns the rungs below off
// again, and both settings are still expressed. Mirrors Kotlin's
// `ZapKeyPolicy.QUICK_LIST_ENABLED`, which Phase 6b flips.
inline constexpr bool kZapQuickListEnabled = true;

// Returns the digit a key carries, or -1.
inline int ZapDigitOf(int virtual_key) {
  if (virtual_key >= kZapVkDigit0 && virtual_key <= kZapVkDigit9) {
    return virtual_key - kZapVkDigit0;
  }
  if (virtual_key >= kZapVkNumpad0 && virtual_key <= kZapVkNumpad9) {
    return virtual_key - kZapVkNumpad0;
  }
  return -1;
}

// A cursor move of [delta] rows. Written as a helper rather than an aggregate
// initialiser so no call site has to remember that `digit` sits between the
// action and the delta.
inline ZapKeyDecision ZapMoveDecision(int delta) {
  ZapKeyDecision decision;
  decision.action = ZapKeyAction::kMove;
  decision.delta = delta;
  return decision;
}

// @param virtual_key       the `WM_KEYDOWN` wParam.
// @param zap_active        a live route with a zap controller behind it. VOD,
//                          and a live route opened without one (the EPG grid's
//                          own play path), keep every key they have today —
//                          claiming the arrows there would turn them into dead
//                          keys, since Dart would decline the command and the
//                          chrome would never be revealed.
// @param controls_visible  with the chrome up the arrows belong to the control
//                          row; they are the only ambiguous keys, so they are
//                          the only ones this gates.
// @param digits_pending    a channel number is half-typed. Read from the
//                          **native** mirror of `setZapBanner`'s `digits` plus
//                          an optimistic flag set when a digit is dispatched,
//                          never from a round trip to Dart: this decision is
//                          synchronous. The worst a stale mirror can do is let
//                          one Back press peel a control layer instead of
//                          clearing the buffer, which is recoverable; waiting
//                          on a reply would mean returning "not consumed" for
//                          a key that is about to be consumed, which is not.
// @param is_repeat         `lParam` bit 30 — the key was already down.
// @param quick_list_open   the quick list is on screen. Read from the native
//                          mirror of `setQuickList`'s `open` — the same
//                          synchronous-decision reason `digits_pending` is a
//                          mirror. While it is set the list **owns
//                          navigation** (docs/player.md): every arrow means a
//                          cursor move, not a channel change, and the chrome
//                          test below no longer applies, because a list on
//                          screen is unambiguous whether the bars are up or
//                          not — handing Up to the control row there would
//                          move two cursors with one press.
inline ZapKeyDecision DecideZapKey(
    int virtual_key, bool zap_active, bool controls_visible,
    bool digits_pending, bool is_repeat, bool quick_list_open,
    bool quick_list_enabled = kZapQuickListEnabled) {
  if (!zap_active) {
    return ZapKeyDecision{};
  }

  if (quick_list_open && quick_list_enabled) {
    const int list_digit = ZapDigitOf(virtual_key);
    if (list_digit >= 0) {
      // Digits move the cursor rather than zapping while the list is up, but
      // that is Dart's rule to apply — the string is the same one, and a held
      // key must not stack the same number four times either way.
      return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                       : ZapKeyDecision{ZapKeyAction::kDigit, list_digit};
    }
    switch (virtual_key) {
    case kZapVkUp:
      // Repeats pass: holding an arrow is how a 250k-row list is scanned, and
      // the cursor clamps at both ends rather than wrapping.
      return ZapMoveDecision(-1);
    case kZapVkDown:
      return ZapMoveDecision(1);
    case kZapVkLeft:
    case kZapVkEscape:
    case kZapVkBack:
      // One rung up the mode stack, and at the top it closes. Ahead of the
      // ordinary Escape/Back branch in `MessageHandler`, because the list's
      // rungs sit above the player's chrome ladder (docs/tv-navigation.md,
      // "The in-player quick list").
      return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                       : ZapKeyDecision{ZapKeyAction::kBack};
    case kZapVkRight:
      return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                       : ZapKeyDecision{ZapKeyAction::kDescend};
    case kZapVkReturn:
    case kZapVkSelect:
      return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                       : ZapKeyDecision{ZapKeyAction::kActivate};
    case kZapVkPrior:
      // The dedicated keys keep their list-*order* meaning: "the next
      // channel" is the next row down, exactly as it is for playback.
      return ZapKeyDecision{ZapKeyAction::kChannelUp};
    case kZapVkNext:
      return ZapKeyDecision{ZapKeyAction::kChannelDown};
    case kZapVkGuide:
      // A dedicated key that did nothing the second time reads as a dead
      // remote, so it toggles — the same rule Dart's `guide` binding applies.
      return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                       : ZapKeyDecision{ZapKeyAction::kCloseList};
    default:
      break;
    }
    // Everything else keeps its ordinary meaning on this screen: the list is
    // a readout over the video, not a modal that swallows the keyboard.
    return ZapKeyDecision{};
  }

  const int digit = ZapDigitOf(virtual_key);
  if (digit >= 0) {
    // A held digit key must not stack the same number four times, and must
    // not fall through to the overlay either.
    if (is_repeat) {
      return ZapKeyDecision{ZapKeyAction::kSwallow};
    }
    return ZapKeyDecision{ZapKeyAction::kDigit, digit};
  }

  // Unambiguous by construction: Page Up/Down are this surface's stand-in for
  // a remote's CHANNEL_UP/CHANNEL_DOWN, and mean one thing whether the chrome
  // is up or not. Repeats are allowed — holding the key is how a user scans,
  // and the 600 ms settle in Dart is what keeps that to one `create_link`.
  if (virtual_key == kZapVkPrior) {
    return ZapKeyDecision{ZapKeyAction::kChannelUp};
  }
  if (virtual_key == kZapVkNext) {
    return ZapKeyDecision{ZapKeyAction::kChannelDown};
  }
  if (virtual_key == kZapVkGuide && quick_list_enabled) {
    // Unambiguous like the two above, so it opens the list whether the chrome
    // is up or not — unlike Left, which is contested.
    return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                     : ZapKeyDecision{ZapKeyAction::kOpenList};
  }

  // OK commits a half-typed number early, and Back/Escape clears it — both
  // *above* their ordinary meanings on this screen, and only while there is a
  // number to act on. Escape in particular must fall through to the overlay's
  // own back handling the moment the buffer is empty.
  if (digits_pending) {
    if (virtual_key == kZapVkReturn || virtual_key == kZapVkSelect) {
      return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                       : ZapKeyDecision{ZapKeyAction::kActivate};
    }
    if (virtual_key == kZapVkEscape || virtual_key == kZapVkBack) {
      return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                       : ZapKeyDecision{ZapKeyAction::kBack};
    }
  }

  // The arrows are the contested keys: with the chrome up they walk the
  // control row, so zapping only claims them while it is hidden.
  if (controls_visible) {
    return ZapKeyDecision{};
  }
  if (virtual_key == kZapVkUp) {
    // Up is the next *higher* channel, i.e. the next row down the launch list.
    return ZapKeyDecision{ZapKeyAction::kChannelUp};
  }
  if (virtual_key == kZapVkDown) {
    return ZapKeyDecision{ZapKeyAction::kChannelDown};
  }
  if (virtual_key == kZapVkRight) {
    // Holding it would toggle back and forth; one press, one swap.
    return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                     : ZapKeyDecision{ZapKeyAction::kPreviousChannel};
  }
  if (virtual_key == kZapVkLeft) {
    if (!quick_list_enabled) {
      return ZapKeyDecision{};
    }
    return is_repeat ? ZapKeyDecision{ZapKeyAction::kSwallow}
                     : ZapKeyDecision{ZapKeyAction::kOpenList};
  }
  return ZapKeyDecision{};
}

} // namespace iptvs

#endif // RUNNER_ZAP_KEY_POLICY_H_
