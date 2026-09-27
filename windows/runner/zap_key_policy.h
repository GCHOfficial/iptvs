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
  kDigit,
  kActivate,
  kBack,
};

// One key's outcome. `command()` is the string to send to Dart on the shared
// zap vocabulary, or empty when nothing is sent.
struct ZapKeyDecision {
  ZapKeyAction action = ZapKeyAction::kNone;
  int digit = -1;

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

// Whether the quick list exists yet.
//
// Dart answers `zap:list` with "not consumed" until Phase 6 wires the quick
// list, and the window procedure cannot wait for that answer — it has to
// return synchronously. So rather than consume Left into a silent no-op
// (Left's present job, revealing the chrome, would simply stop working), this
// flag keeps it out of the policy entirely until the list is real. Phase 6
// flips it; both settings are already expressed below. Mirrors Kotlin's
// `ZapKeyPolicy.QUICK_LIST_ENABLED`.
inline constexpr bool kZapQuickListEnabled = false;

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
inline ZapKeyDecision DecideZapKey(
    int virtual_key, bool zap_active, bool controls_visible,
    bool digits_pending, bool is_repeat,
    bool quick_list_enabled = kZapQuickListEnabled) {
  if (!zap_active) {
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
