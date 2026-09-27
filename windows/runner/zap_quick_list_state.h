#ifndef RUNNER_ZAP_QUICK_LIST_STATE_H_
#define RUNNER_ZAP_QUICK_LIST_STATE_H_

#include <algorithm>
#include <string>
#include <vector>

// The native mirror of the in-player **quick list** (docs/player.md "Live
// zapping" → "The quick list"), plus the two pieces of arithmetic the Windows
// renderer needs to draw it.
//
// Deliberately **Windows-free** — no <windows.h>, no Flutter headers — for the
// same reason `zap_key_policy.h` is: this is the half of the feature that can
// be reasoned about (and compiled, and asserted on) without a Win32 toolchain,
// and the half most likely to be wrong is the windowing arithmetic rather than
// the GDI calls. `flutter_window.cpp` owns the thin adapter that fills a
// [QuickListState] from the `setQuickList` `EncodableValue`, and every pixel.
//
// **Dart owns the list, the cursor and the decision** (`live_zap_controller.
// dart`); this side holds a *window* of already-formatted rows and prints
// them. Nothing here formats a string, re-derives a flag from a timestamp or
// decides what a key means — a renderer prints, and that rule is why the four
// surfaces cannot disagree about wording the way the badge labels once did.
namespace iptvs {

// Which rung of the quick list's mode stack the payload describes. Mirrors
// `ZapQuickListMode` (`lib/player/zap_quick_list.dart`).
enum class QuickListMode { kCategories, kChannels, kSchedule };

// What a row stands for. Mirrors `ZapQuickListRowKind`.
enum class QuickListRowKind { kCategory, kChannel, kProgramme };

// An unknown name resolves to the payload's most common shape rather than
// failing: a renderer that cannot name a mode must still draw the rows it was
// sent, and the mode only picks a heading glyph here.
inline QuickListMode QuickListModeFromName(const std::string &name) {
  if (name == "categories") {
    return QuickListMode::kCategories;
  }
  if (name == "schedule") {
    return QuickListMode::kSchedule;
  }
  return QuickListMode::kChannels;
}

inline QuickListRowKind QuickListRowKindFromName(const std::string &name) {
  if (name == "category") {
    return QuickListRowKind::kCategory;
  }
  if (name == "programme") {
    return QuickListRowKind::kProgramme;
  }
  return QuickListRowKind::kChannel;
}

// One rendered row. Every string is final copy from Dart.
struct QuickListRow {
  // Absolute index in the full list (not in the window), so a position
  // readout or a scrollbar needs no windowing maths.
  int index = 0;
  // Opaque identity within the mode. Unused by this renderer — the list is
  // not a pointer target here — but carried so a future hit test can name a
  // row rather than an index that may have moved.
  std::string id;
  std::wstring label;
  // The dimmer second line, or empty.
  std::wstring secondary;
  // `ON NOW` / `CATCH-UP`, or empty.
  std::wstring badge;
  QuickListRowKind kind = QuickListRowKind::kChannel;
  bool selected = false;
  // The channel actually playing (channels), or the category the range
  // currently reflects.
  bool playing = false;
  // Schedule: activating this row starts catch-up.
  bool archive = false;
  // Schedule: already ended.
  bool past = false;
  // Schedule: on air now.
  bool live = false;
};

// The whole `setQuickList` payload, parsed.
struct QuickListState {
  // **`false` is a tear-down instruction, not an absence**: a closed list is
  // still pushed, on every controller notification.
  bool open = false;
  QuickListMode mode = QuickListMode::kChannels;
  std::wstring heading;
  // The window: at most `kZapWindowRows` (40) rows starting at
  // [window_start].
  std::vector<QuickListRow> rows;
  // Cursor position, **absolute**.
  int selected_index = 0;
  // Absolute index of `rows[0]`.
  int window_start = 0;
  // Size of the full list — up to 250k, never shipped, only counted.
  int total = 0;
  bool loading = false;
  // Drawn instead of rows when [total] is zero and nothing is loading.
  std::wstring empty_label;
  // Bumped on every real change. Stored so a future animation can tell a real
  // update from an identical re-push; this renderer redraws either way.
  int revision = 0;

  // The cursor's offset inside [rows], or -1 when the window doesn't hold it
  // (only possible for an empty list). Mirrors Dart's `selectedInWindow`.
  int SelectedInWindow() const {
    const int offset = selected_index - window_start;
    return offset >= 0 && offset < static_cast<int>(rows.size()) ? offset : -1;
  }
};

// How many rows fit in [content_height] pixels, capped at [max_rows] and
// never less than one.
//
// One row is drawn even when nothing fits, deliberately: a panel with a
// heading and no rows at all reads as a broken list, while a clipped row reads
// as a small window. Both arguments are guarded because the client size is
// whatever the user dragged the window to.
inline int QuickListVisibleRowCount(int content_height, int row_height,
                                    int max_rows) {
  if (row_height <= 0 || max_rows <= 0) {
    return 1;
  }
  const int fits = content_height / row_height;
  return std::clamp(fits, 1, max_rows);
}

// First index of the [visible]-sized slice of [row_count] rows that contains
// [selected], keeping the cursor centred where the slice is small enough to
// need it and clamping at both ends.
//
// The same arithmetic as Dart's `zapWindowStart` (`zap_quick_list.dart`), one
// level down: Dart windows the *full* list to 40 rows around the cursor, and
// this windows those 40 to however many the panel can draw. A slice that
// misses the cursor draws a list with no visible selection, which on a remote
// is indistinguishable from a frozen screen — the exact failure the EPG grid's
// horizontal reveal already records (docs/tv-navigation.md).
inline int QuickListVisibleStart(int row_count, int selected, int visible) {
  if (visible <= 0 || row_count <= visible) {
    return 0;
  }
  int start = selected - visible / 2;
  if (start > row_count - visible) {
    start = row_count - visible;
  }
  if (start < 0) {
    start = 0;
  }
  return start;
}

} // namespace iptvs

#endif // RUNNER_ZAP_QUICK_LIST_STATE_H_
