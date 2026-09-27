#include "flutter_window.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <cstdint>
#include <iterator>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#include <wingdi.h>
#pragma comment(lib, "Msimg32.lib")

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "zap_key_policy.h"
#include "zap_quick_list_state.h"

// The zap key policy mirrors its virtual-key codes rather than including
// <windows.h>, so it can be read (and, if this runner ever grows a C++ test
// harness, exercised) without a Win32 toolchain. These are the ZapKeyPolicyTest
// equivalent: a typo in the mirror fails the build instead of shipping a key
// that silently means nothing.
static_assert(iptvs::kZapVkBack == VK_BACK, "VK_BACK mirror");
static_assert(iptvs::kZapVkReturn == VK_RETURN, "VK_RETURN mirror");
static_assert(iptvs::kZapVkEscape == VK_ESCAPE, "VK_ESCAPE mirror");
static_assert(iptvs::kZapVkPrior == VK_PRIOR, "VK_PRIOR mirror");
static_assert(iptvs::kZapVkNext == VK_NEXT, "VK_NEXT mirror");
static_assert(iptvs::kZapVkLeft == VK_LEFT, "VK_LEFT mirror");
static_assert(iptvs::kZapVkUp == VK_UP, "VK_UP mirror");
static_assert(iptvs::kZapVkRight == VK_RIGHT, "VK_RIGHT mirror");
static_assert(iptvs::kZapVkDown == VK_DOWN, "VK_DOWN mirror");
static_assert(iptvs::kZapVkSelect == VK_SELECT, "VK_SELECT mirror");
static_assert(iptvs::kZapVkDigit0 == '0', "digit-0 mirror");
static_assert(iptvs::kZapVkDigit9 == '9', "digit-9 mirror");
static_assert(iptvs::kZapVkNumpad0 == VK_NUMPAD0, "VK_NUMPAD0 mirror");
static_assert(iptvs::kZapVkNumpad9 == VK_NUMPAD9, "VK_NUMPAD9 mirror");
// The quick list's guide key is a plain letter, not a `VK_*`: Win32 has no
// virtual-key code for a remote's GUIDE at all (see kZapVkGuide). Asserted
// here anyway, so the mirror is checked the same way as the rest.
static_assert(iptvs::kZapVkGuide == 'G', "guide-key mirror");

FlutterWindow::FlutterWindow(const flutter::DartProject &project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {

constexpr const wchar_t kNativeVideoSurfaceClassName[] =
    L"IPTVS_NATIVE_VIDEO_SURFACE";
constexpr const wchar_t kNativeControlsClassName[] =
    L"IPTVS_NATIVE_VIDEO_CONTROLS";
constexpr const char kNativeHdrPlayerChannel[] = "iptvs/native_hdr_player";
constexpr UINT kNativeVideoSurfaceInputMessage = WM_APP + 0x4D;
constexpr UINT kNativeControlCommandMessage = WM_APP + 0x4E;
constexpr UINT kNativeControlsLayoutMessage = WM_APP + 0x4F;
constexpr UINT_PTR kNativeControlsHideTimer = 0x5031;
constexpr UINT_PTR kNativeVideoResyncTimer = 0x5032;
constexpr UINT_PTR kNativeZapBannerTimer = 0x5033;
// How long the zap banner stays up after a press. Mirrors Kotlin
// `ZAP_BANNER_VISIBLE_MS` and the Lua OSD's `ZAP_BANNER_VISIBLE_S`: long
// enough to read a channel name and its now/next after a single press, short
// enough not to sit over the picture once the user has stopped zapping. A
// half-typed number or a transient note outlives it (see ZapBannerShown).
constexpr UINT kNativeZapBannerVisibleMs = 3000;
// Verification passes after a discrete window transition (fullscreen /
// mini-player). The immediate resync in ResizeNativeVideoSurface covers the
// common case; these re-checks catch an mpv VO window that is (re)created
// moments *after* the transition — chiefly the HDR embedded→native
// escalation, which hot-swaps `wid`/`vo` on an already-playing player.
constexpr UINT kNativeVideoResyncIntervalMs = 250;
constexpr int kNativeVideoResyncPasses = 4;
constexpr int kNativeTopControlsHeight = 64;
// The bottom bar is a single row for live (no scrubber) and two rows for VOD
// (scrubber row + control row).
constexpr int kNativeBottomControlsHeightLive = 80;
constexpr int kNativeBottomControlsHeightVod = 116;
// Live with an EPG snapshot gets a taller bar: a programme row (title + progress
// + next) sits where the VOD scrubber would be.
constexpr int kNativeBottomControlsHeightLiveEpg = 150;
// The live EPG strip's own height, from its top edge to the bottom of the
// "Next ·" line. The one number both the bottom bar and the zap banner lay
// their copy of the strip out against (DrawLiveEpgStrip).
constexpr int kNativeEpgStripHeight = 64;
// The channel-identity run ("12 · BBC One"), drawn above the strip. 26 px is
// Kotlin's `ChannelIdentityRow` and the Lua OSD's `IDENTITY_ROW_PX`.
constexpr int kNativeIdentityRowHeight = 26;
// Gap between the identity run and the strip below it (Compose's
// `Spacer(10.dp)`).
constexpr int kNativeIdentityRowGap = 10;
constexpr int kNativeMenuWidth = 300;
constexpr int kNativeMenuHeaderHeight = 36;
constexpr int kNativeMenuRowHeight = 40;
constexpr int kNativeMenuMaxRows = 5;
constexpr int kNativeMenuPadding = 10;
constexpr int kNativeControlsKindOverlay = 0;
#ifndef NDEBUG
// Debug-only native resource counters, surfaced via the "debugCounters"
// method on kNativeHdrPlayerChannel. Touched only from the platform/UI
// thread (all FlutterWindow methods run there), so plain ints are fine.
int g_debug_surface_count = 0;
int g_debug_overlay_count = 0;
// Counts the cached overlay back-buffer DIB/DC pair (0 or 1). Surfaced via
// debugCounters as "windowsOverlayDibs"; the lifecycle soak asserts it returns
// to 0 after the overlay is destroyed (ReleaseOverlayBackBuffer, called from
// DestroyNativeControls). Not folded into windowsOverlays because that counts
// windows, not the paint-time back-buffer.
int g_debug_overlay_dib_count = 0;
#endif

// Cached back-buffer for the layered controls overlay. The overlay is a
// full-window layered window, but only the top/bottom bars (+ any open
// menu/info panel) are ever drawn or visible (the rest is clipped away by the
// window region). Previously every WM_PAINT allocated a fresh full-window ARGB
// DIB, ZeroMemory'd it, and UpdateLayeredWindow'd the whole surface — a ~33 MB
// alloc + memset + composite per paint at 4K, several times a second while the
// overlay is up (and pinned visible through a reconnect). This caches the DIB +
// memory DC and reuses them across paints, recreating only when the client size
// changes; each paint clears and re-composites just the union of the control
// rects (see PaintNativeControlBar). It lives at file scope, alongside
// g_native_control_state, because PaintNativeControlBar is a free function
// driven by the overlay WndProc and there is exactly one overlay window per
// process — the same single-overlay invariant those globals already assume.
struct OverlayBackBuffer {
  HDC dc = nullptr;
  HBITMAP bitmap = nullptr;
  HBITMAP old_bitmap = nullptr;
  void *bits = nullptr;
  int width = 0;
  int height = 0;
  // Control rects touched by the previous paint, so the next paint can clear
  // and re-composite anything a shrinking/closing control vacated (making
  // correctness independent of when the window region is rebuilt).
  std::vector<RECT> prev_rects;
};
OverlayBackBuffer g_overlay_back_buffer;
bool g_native_video_cursor_visible = true;
// Mini-player mode (see SetNativeWindowMiniPlayer): dragging the video moves
// the whole window.
bool g_native_window_mini = false;
POINT g_last_video_mouse{-1, -1};
POINT g_last_controls_mouse{-1, -1};
int g_native_menu_scroll_offset = 0;
int g_native_focus_index = 0;
bool g_native_keyboard_focus_visible = false;

// Which slider the pointer is currently dragging, if any.
//
// The overlay used to act on `WM_LBUTTONDOWN` alone, so both sliders answered a
// *click* and ignored a drag outright — press-and-move did nothing, and because
// nothing captured the mouse the gesture also swallowed the button-up that
// would have ended it. Grabbing them behaves like a slider now: capture on
// press, track on move, release on up.
enum class NativeSliderDrag { kNone, kVolume, kSeek };
NativeSliderDrag g_native_slider_drag = NativeSliderDrag::kNone;

// While the seek bar is being dragged, the ratio the thumb is drawn at.
//
// Volume is applied continuously (it is cheap, and hearing the change is the
// point), but a seek is not: dragging across a full-width scrubber would ask
// the player for a thousand seeks. So the drag paints a preview and commits
// once, on release — which is also what the Flutter scrubber does. Negative
// means "not dragging"; the painter falls back to the real position.
double g_native_seek_preview = -1.0;

// Last ratio a live drag posted, so a move within the same pixel stays silent.
double g_native_slider_last_sent = -1.0;

enum class NativeFocusItem {
  kBack,
  kFavorite,
  kPlay,
  kSeekBack,
  kSeekForward,
  kMute,
  kSpeed,
  kAudio,
  kSubtitles,
  kAspect,
  kInfo,
  kFullscreen,
  kGoLive,
};

HWND NativeControlsOwner(HWND hwnd) {
  if (HWND owner = GetWindow(hwnd, GW_OWNER)) {
    return owner;
  }
  return GetParent(hwnd);
}

struct NativeMenuOption {
  std::string id;
  std::wstring label;
};

// Which secondary list-menu (if any) is currently open. The menus all share one
// rendering / hit-test / scroll path; only the backing option list differs.
enum class NativeMenuKind { kNone, kAudio, kSubtitles, kSpeed };

struct NativeControlState {
  std::wstring title;
  bool is_live = false;
  bool live_synced = true; // at the live edge (red badge) vs behind (grey + button)
  bool can_favorite = false; // live channel with a favorites store (show the star)
  bool is_favorite = false;  // current favorite state (Dart owns the store)
  bool reconnecting = false; // live reconnect watchdog re-establishing the stream
  bool playing = false;
  bool fullscreen = false;
  NativeMenuKind open_menu = NativeMenuKind::kNone;
  bool info_open = false;
  double position_ms = 0.0;
  double duration_ms = 0.0;
  double volume = 100.0;
  std::string selected_subtitle_id = "auto";
  std::string selected_audio_id = "auto";
  std::string selected_speed_id;
  std::vector<NativeMenuOption> subtitle_tracks;
  std::vector<NativeMenuOption> audio_tracks;
  std::vector<NativeMenuOption> speed_options;
  std::wstring aspect_label;
  // Stream info (for the badges + info panel). Empty / zero means "unknown",
  // in which case the corresponding row/badge is omitted.
  int video_width = 0;
  int video_height = 0;
  double fps = 0.0;
  std::wstring dynamic_range;
  std::wstring video_codec;
  std::wstring audio_codec;
  std::wstring audio_channels;
  // Active source name (badge).
  std::wstring source_name;
  // Whether this route has a `LiveZapController` behind it (Windows-only key
  // on setControlState). The key ring reads it to decide whether the arrows
  // belong to zapping: a live route opened *without* a controller (the EPG
  // grid's own play path) must keep them, or Dart would decline the command
  // and they would become dead keys.
  bool zap_enabled = false;
  // Live EPG now/next snapshot (epoch ms; 0 = absent).
  std::wstring epg_now_title;
  double epg_now_start_ms = 0.0;
  double epg_now_stop_ms = 0.0;
  std::wstring epg_now_desc;
  std::wstring epg_next_title;
  double epg_next_start_ms = 0.0;
  double epg_next_stop_ms = 0.0;
};

NativeControlState g_native_control_state;

// In-player live zapping (docs/player.md "Live zapping").
//
// Pushed from Dart on `setZapBanner` — **not** folded into setControlState,
// whose 2 Hz coalescer would drop presses: a banner has to track every key,
// not the state a few times a second. Dart owns the channel list and the
// cursor; every field here is presentation only, and none of them decides
// anything about playback.
//
// It describes the **cursor's** channel, which during a held key is ahead of
// the one playing — that is the whole point of the banner, and why it cannot
// reuse `NativeControlState`'s `epg_now_*`/`epg_next_*`, which describe the
// channel actually on screen.
struct NativeZapState {
  // Set by the first push, so a session that never zaps renders exactly as it
  // did before this existed (the Lua OSD's `zap_block() ~= nil`).
  bool has_banner = false;
  bool has_channel_number = false;
  int channel_number = 0;
  std::wstring channel_name;
  // Half-typed channel number.
  std::wstring digits;
  // Transient note ("No channel 123", a failed zap). Empty = none.
  std::wstring message;
  // True while Dart is stopping/resolving/opening the settled channel. Nothing
  // draws it; it exists so UpdateNativeControlState can tell a zap's
  // deliberate stop from a user pause (see the `zap_settling` guard there).
  bool settling = false;
  // 1-based cursor position in the launch range, and the range's size.
  int position = 0;
  int total = 0;
  // The **cursor** channel's now/next (epoch ms; 0 = absent).
  std::wstring epg_now_title;
  double epg_now_start_ms = 0.0;
  double epg_now_stop_ms = 0.0;
  std::wstring epg_next_title;
  double epg_next_start_ms = 0.0;
  double epg_next_stop_ms = 0.0;
  // Within the kNativeZapBannerVisibleMs window since the last push. Owned by
  // this side, exactly as it is Compose's on Android: Dart says *what* the
  // banner reads and *that the user pressed something*, never whether it is on
  // screen.
  bool visible = false;
};

NativeZapState g_native_zap_state;

// The in-player quick list, as the last `setQuickList` push described it
// (docs/player.md "The quick list"). Parsed into a Win32-free value type
// (`zap_quick_list_state.h`) so the windowing arithmetic this renderer depends
// on can be reasoned about — and compiled — without a Win32 toolchain.
//
// Dart owns the list, the cursor and the mode stack; this is a view. Nothing
// here is ever mutated by a key press, only replaced by the next push.
iptvs::QuickListState g_native_quick_list;

// Mirror of the chrome's visibility for the free functions in this namespace
// (the authority is FlutterWindow::native_controls_visible_, which writes this
// in ShowNativeControls). The overlay window can be visible while the chrome
// is not — that is precisely the zap-banner case — so the paint, the clip
// region and the key policy all need to tell the two apart.
bool g_native_controls_chrome_visible = true;

// Set the moment a digit key is dispatched, cleared by the next
// `setZapBanner`, which carries the authoritative buffer.
//
// The round trip to Dart and back is asynchronous, and the very next key — OK
// to commit, Back to clear — can arrive before the banner does. Without this
// that key falls through to the chrome and the half-typed number is stranded.
// Kotlin's `HdrPlayerActivity` keeps the same optimistic flag beside its own
// mirror, for the same reason.
bool g_native_zap_digits_optimistic = false;

// A live route with a zap controller behind it.
bool ZapActive() {
  return g_native_control_state.is_live && g_native_control_state.zap_enabled;
}

bool ZapDigitsPending() {
  return !g_native_zap_state.digits.empty() || g_native_zap_digits_optimistic;
}

// Whether the quick list is on screen. `open` is Dart's instruction and the
// only input — a closed list is still pushed, so an absent field cannot be
// read as "leave it up".
bool QuickListShown() {
  return g_native_control_state.is_live && g_native_quick_list.open;
}

// Whether the banner has anything to acknowledge. A half-typed number and a
// transient note outlive the plain 3 s timer on purpose: both are
// mid-interaction states, and hiding them would take the feedback away while
// the user is still typing. Mirrors Kotlin `showZapBanner` / the Lua OSD's
// `show_zap_banner`; the "chrome is hidden" half of the gate lives at the call
// sites, same as on both of those.
bool ZapBannerShown() {
  const NativeZapState &z = g_native_zap_state;
  // **The banner yields to the list.** Both sit in the lower-left and both
  // describe the cursor's channel, so drawn together they would print it
  // twice, from two different cursors — the same rule Dart's
  // `_zapBannerVisible` applies to the shared Flutter overlay. Enforced here
  // rather than at the call sites because the paint, the clip region and the
  // overlay's own visibility all have to agree about it.
  if (QuickListShown()) {
    return false;
  }
  return g_native_control_state.is_live && z.has_banner &&
         (z.visible || !z.digits.empty() || !z.message.empty());
}

// Whether the **bottom bar** draws the identity run: only when it says
// something the top bar's title does not — a channel number, a half-typed
// number, or a transient note. Mirrors Kotlin `showsChannelIdentity`, so a
// session that never zaps keeps the layout it always had.
bool ShowsChannelIdentity() {
  const NativeZapState &z = g_native_zap_state;
  return g_native_control_state.is_live && z.has_banner &&
         (z.has_channel_number || !z.digits.empty() || !z.message.empty());
}

void ResetNativeZapState() {
  g_native_zap_state = NativeZapState{};
  g_native_quick_list = iptvs::QuickListState{};
  g_native_zap_digits_optimistic = false;
}

bool ControlsPinnedByOverlay() {
  return g_native_control_state.open_menu != NativeMenuKind::kNone ||
         g_native_control_state.info_open ||
         // A live reconnect pins the chrome, so the "Reconnecting…" badge
         // cannot auto-hide out from under a stall. Windows draws that badge
         // *inside* the auto-hiding overlay, so without this the platform's
         // primary live path (native HDR) showed a frozen picture with no
         // explanation at all. Android and iOS instead draw their notice
         // outside the visibility gate; the Linux Lua OSD both draws it
         // ungated and pins. Pinning is the smaller change here and gives the
         // same user-visible result for the auto-hide case, which is the one
         // that actually bites — the hide timer is the only thing that takes
         // the chrome away mid-stall.
         g_native_control_state.reconnecting;
}

const std::vector<NativeMenuOption> &MenuOptions(NativeMenuKind kind) {
  static const std::vector<NativeMenuOption> kEmpty;
  switch (kind) {
  case NativeMenuKind::kAudio:
    return g_native_control_state.audio_tracks;
  case NativeMenuKind::kSubtitles:
    return g_native_control_state.subtitle_tracks;
  case NativeMenuKind::kSpeed:
    return g_native_control_state.speed_options;
  default:
    return kEmpty;
  }
}

const std::string &MenuSelectedId(NativeMenuKind kind) {
  static const std::string kNone;
  switch (kind) {
  case NativeMenuKind::kAudio:
    return g_native_control_state.selected_audio_id;
  case NativeMenuKind::kSubtitles:
    return g_native_control_state.selected_subtitle_id;
  case NativeMenuKind::kSpeed:
    return g_native_control_state.selected_speed_id;
  default:
    return kNone;
  }
}

std::wstring MenuHeader(NativeMenuKind kind) {
  switch (kind) {
  case NativeMenuKind::kAudio:
    return L"Audio";
  case NativeMenuKind::kSubtitles:
    return L"Subtitles";
  case NativeMenuKind::kSpeed:
    return L"Playback speed";
  default:
    return L"";
  }
}

std::string MenuSelectCommandPrefix(NativeMenuKind kind) {
  switch (kind) {
  case NativeMenuKind::kAudio:
    return "audioTrack:";
  case NativeMenuKind::kSubtitles:
    return "subtitleTrack:";
  case NativeMenuKind::kSpeed:
    return "speed:";
  default:
    return "";
  }
}

std::wstring Utf8ToWide(const std::string &value) {
  if (value.empty()) {
    return L"";
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return L"";
  }
  std::wstring wide(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      wide.data(), size);
  return wide;
}

int EncodableIntArg(const flutter::EncodableValue *args, const char *key,
                    int fallback) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return fallback;
  }
  const auto &map = std::get<flutter::EncodableMap>(*args);
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) {
    return fallback;
  }
  if (std::holds_alternative<int32_t>(found->second)) {
    return std::get<int32_t>(found->second);
  }
  if (std::holds_alternative<int64_t>(found->second)) {
    return static_cast<int>(std::get<int64_t>(found->second));
  }
  return fallback;
}

// Whether [key] is present and non-null. Needed where "absent" and "zero" are
// different answers — `channelNumber`, which `bannerPayload` omits entirely
// for a channel the provider gave no number for.
bool EncodableHasKey(const flutter::EncodableValue *args, const char *key) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return false;
  }
  const auto &map = std::get<flutter::EncodableMap>(*args);
  const auto found = map.find(flutter::EncodableValue(key));
  return found != map.end() &&
         !std::holds_alternative<std::monostate>(found->second);
}

bool EncodableBoolArg(const flutter::EncodableValue *args, const char *key,
                      bool fallback) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return fallback;
  }
  const auto &map = std::get<flutter::EncodableMap>(*args);
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end() || !std::holds_alternative<bool>(found->second)) {
    return fallback;
  }
  return std::get<bool>(found->second);
}

double EncodableDoubleArg(const flutter::EncodableValue *args, const char *key,
                          double fallback) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return fallback;
  }
  const auto &map = std::get<flutter::EncodableMap>(*args);
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) {
    return fallback;
  }
  if (std::holds_alternative<double>(found->second)) {
    return std::get<double>(found->second);
  }
  if (std::holds_alternative<int32_t>(found->second)) {
    return static_cast<double>(std::get<int32_t>(found->second));
  }
  if (std::holds_alternative<int64_t>(found->second)) {
    return static_cast<double>(std::get<int64_t>(found->second));
  }
  return fallback;
}

std::wstring EncodableStringArg(const flutter::EncodableValue *args,
                                const char *key, const std::wstring &fallback) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return fallback;
  }
  const auto &map = std::get<flutter::EncodableMap>(*args);
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end() ||
      !std::holds_alternative<std::string>(found->second)) {
    return fallback;
  }
  return Utf8ToWide(std::get<std::string>(found->second));
}

std::string EncodableStdStringArg(const flutter::EncodableValue *args,
                                  const char *key,
                                  const std::string &fallback) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return fallback;
  }
  const auto &map = std::get<flutter::EncodableMap>(*args);
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end() ||
      !std::holds_alternative<std::string>(found->second)) {
    return fallback;
  }
  return std::get<std::string>(found->second);
}

std::vector<NativeMenuOption> ParseMenuOptions(
    const flutter::EncodableValue *args, const char *key) {
  std::vector<NativeMenuOption> out;
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return out;
  }
  const auto &map = std::get<flutter::EncodableMap>(*args);
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end() ||
      !std::holds_alternative<flutter::EncodableList>(found->second)) {
    return out;
  }
  for (const auto &item : std::get<flutter::EncodableList>(found->second)) {
    if (!std::holds_alternative<flutter::EncodableMap>(item)) {
      continue;
    }
    const auto &item_map = std::get<flutter::EncodableMap>(item);
    const auto id = item_map.find(flutter::EncodableValue("id"));
    const auto label = item_map.find(flutter::EncodableValue("label"));
    if (id == item_map.end() || label == item_map.end() ||
        !std::holds_alternative<std::string>(id->second) ||
        !std::holds_alternative<std::string>(label->second)) {
      continue;
    }
    out.push_back(NativeMenuOption{
        std::get<std::string>(id->second),
        Utf8ToWide(std::get<std::string>(label->second)),
    });
  }
  return out;
}

std::wstring FormatTime(double milliseconds) {
  const int total_seconds = std::max(0, static_cast<int>(milliseconds / 1000));
  const int hours = total_seconds / 3600;
  const int minutes = (total_seconds % 3600) / 60;
  const int seconds = total_seconds % 60;
  wchar_t buffer[32];
  if (hours > 0) {
    swprintf_s(buffer, L"%d:%02d:%02d", hours, minutes, seconds);
  } else {
    swprintf_s(buffer, L"%d:%02d", minutes, seconds);
  }
  return buffer;
}

bool HasPointerMoved(LPARAM lparam, POINT *last_point) {
  const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  if (point.x == last_point->x && point.y == last_point->y) {
    return false;
  }
  *last_point = point;
  return true;
}

RECT RectFrom(int left, int top, int right, int bottom) {
  return RECT{left, top, right, bottom};
}

int MaxInt(int a, int b) { return a > b ? a : b; }

int RectWidth(const RECT &rect) {
  return MaxInt(0, static_cast<int>(rect.right - rect.left));
}

int RectHeight(const RECT &rect) {
  return MaxInt(0, static_cast<int>(rect.bottom - rect.top));
}

bool PointInRect(int x, int y, const RECT &rect) {
  return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
}

// Loads the bundled Inter weights (embedded as RCDATA) so the GDI overlay can
// render in the app's typeface without requiring Inter to be installed.
void LoadBundledFonts() {
  static bool loaded = false;
  if (loaded) {
    return;
  }
  loaded = true;
  HMODULE module = GetModuleHandle(nullptr);
  const int ids[] = {IDR_FONT_INTER_REGULAR, IDR_FONT_INTER_SEMIBOLD,
                     IDR_FONT_INTER_BOLD};
  for (int id : ids) {
    HRSRC res = FindResource(module, MAKEINTRESOURCE(id), RT_RCDATA);
    if (!res) {
      continue;
    }
    HGLOBAL handle = LoadResource(module, res);
    if (!handle) {
      continue;
    }
    void *data = LockResource(handle);
    const DWORD size = SizeofResource(module, res);
    if (data && size > 0) {
      DWORD count = 0;
      AddFontMemResourceEx(data, size, nullptr, &count);
    }
  }
}

// Default family is Inter (bundled). Inter's SemiBold is a separate GDI family
// ("Inter SemiBold"); Regular/Bold share the "Inter" family via weight. Pass an
// explicit [family] (e.g. the Segoe MDL2 icon font) to bypass this mapping.
HFONT UiFont(int size, int weight = FW_NORMAL, const wchar_t *family = nullptr) {
  const wchar_t *face = family;
  int lf_weight = weight;
  if (face == nullptr) {
    if (weight >= FW_SEMIBOLD && weight < FW_BOLD) {
      face = L"Inter SemiBold";
      lf_weight = FW_NORMAL;
    } else {
      face = L"Inter";
    }
  }
  // **Grayscale AA, not ClearType.** This overlay is a per-pixel-alpha layered
  // window (`UpdateLayeredWindowIndirect` over a premultiplied ARGB DIB), and
  // GDI's ClearType is a subpixel filter that writes RGB without ever touching
  // the alpha channel it is being blended through. The result is coloured
  // fringing along every glyph edge, worst on the thinnest strokes — which is
  // why button labels read as rough while the heavier badges looked fine, and
  // why it stands out most on an HDR surface, where the compositor lifts SDR
  // content into a higher-luminance space and lifts the fringes with it.
  // `ANTIALIASED_QUALITY` is the correct choice for a layered surface.
  return CreateFont(size, 0, 0, 0, lf_weight, FALSE, FALSE, FALSE,
                    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                    ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_SWISS, face);
}

void FillRectColor(HDC hdc, const RECT &rect, COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  FillRect(hdc, &rect, brush);
  DeleteObject(brush);
}

HBITMAP Create32BitDIBSection(HDC hdc, int width, int height, void **bits) {
  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  return CreateDIBSection(hdc, &bmi, DIB_RGB_COLORS, bits, nullptr, 0);
}

// Frees the cached overlay back-buffer (see OverlayBackBuffer). Called from
// DestroyNativeControls, and by EnsureOverlayBackBuffer on a size change.
void ReleaseOverlayBackBuffer() {
  OverlayBackBuffer &b = g_overlay_back_buffer;
  if (b.dc) {
    if (b.old_bitmap) {
      SelectObject(b.dc, b.old_bitmap);
    }
    DeleteDC(b.dc);
  }
  if (b.bitmap) {
    DeleteObject(b.bitmap);
#ifndef NDEBUG
    --g_debug_overlay_dib_count;
#endif
  }
  b.prev_rects.clear();
  b.dc = nullptr;
  b.bitmap = nullptr;
  b.old_bitmap = nullptr;
  b.bits = nullptr;
  b.width = 0;
  b.height = 0;
}

// Returns the cached back-buffer, (re)creating the DIB + memory DC only when
// the target size changes. A fresh CreateDIBSection is zero-initialised (fully
// transparent), and prev_rects is seeded to the whole window so the first paint
// after a (re)create composites the entire surface once.
OverlayBackBuffer &EnsureOverlayBackBuffer(HDC hdc, int width, int height) {
  OverlayBackBuffer &b = g_overlay_back_buffer;
  if (b.dc && b.bitmap && b.width == width && b.height == height) {
    return b;
  }
  ReleaseOverlayBackBuffer();
  b.dc = CreateCompatibleDC(hdc);
  b.bitmap = Create32BitDIBSection(hdc, width, height, &b.bits);
  b.old_bitmap = static_cast<HBITMAP>(SelectObject(b.dc, b.bitmap));
  b.width = width;
  b.height = height;
  b.prev_rects = {RECT{0, 0, width, height}};
#ifndef NDEBUG
  if (b.bitmap) {
    ++g_debug_overlay_dib_count;
  }
#endif
  return b;
}

// Zeroes (fully transparent) the pixels of one rect in the top-down DIB,
// clamped to the buffer bounds. Used to reset only the control bands each
// paint instead of ZeroMemory'ing the whole (mostly transparent) surface.
void ZeroDibRect(uint32_t *pixels, int dib_width, int dib_height,
                 const RECT &r) {
  const int left = std::max(0, static_cast<int>(r.left));
  const int top = std::max(0, static_cast<int>(r.top));
  const int right = std::min(dib_width, static_cast<int>(r.right));
  const int bottom = std::min(dib_height, static_cast<int>(r.bottom));
  if (right <= left || bottom <= top) {
    return;
  }
  const size_t span = static_cast<size_t>(right - left) * sizeof(uint32_t);
  for (int y = top; y < bottom; ++y) {
    ZeroMemory(pixels + static_cast<size_t>(y) * dib_width + left, span);
  }
}

// One stop of a vertical black-scrim ramp: [position] runs 0 (top edge of the
// rect) to 1 (bottom edge), [alpha] is 0-255.
struct ScrimStop {
  double position;
  int alpha;
};

// Fills [rect] with a vertical black scrim whose alpha follows a piecewise
// linear ramp through [stops], writing premultiplied ARGB straight into the
// top-down DIB.
//
// This replaced a flat 20%-black fill so the native bars fade into the video
// the way the shared Flutter overlay's `LinearGradient`s do
// (`player_overlay.dart`). A Windows user moves between the two surfaces
// routinely — native for HDR, embedded for the SDR preview->fullscreen handoff
// — so a hard-edged bar on one and a fade on the other read as two different
// players. The ramps here mirror that overlay's: top bar 0xB3 at the window
// edge fading to nothing, bottom bar nothing at the video edge deepening
// through 0x99 (45%) to 0xCC at the window edge.
//
// Premultiplication is free because the scrim is pure black: every colour
// channel is 0 whatever the alpha, so a pixel is just `alpha << 24`, which is
// exactly what `UpdateLayeredWindow`'s AC_SRC_ALPHA blend wants.
//
// **The alpha floor of 1 is load-bearing.** GDI leaves the alpha byte at 0 on
// everything it draws, and NormalizeNativeControlBitmapAlpha relies on exactly
// that to tell drawn pixels (forced opaque) from the pre-filled backdrop (left
// alone). A scanline that reached a true 0 would be indistinguishable from
// drawn content and come back **opaque black** — a solid bar where the fade
// should be. 1/255 of black is not visible.
//
// The ramp is measured against the unclipped [rect] so clamping to the DIB
// bounds shifts nothing.
void FillVerticalScrim(uint32_t *pixels, int dib_width, int dib_height,
                       const RECT &rect, const ScrimStop *stops,
                       size_t stop_count) {
  if (pixels == nullptr || stops == nullptr || stop_count == 0) {
    return;
  }
  const int left = std::max(0, static_cast<int>(rect.left));
  const int top = std::max(0, static_cast<int>(rect.top));
  const int right = std::min(dib_width, static_cast<int>(rect.right));
  const int bottom = std::min(dib_height, static_cast<int>(rect.bottom));
  if (right <= left || bottom <= top) {
    return;
  }
  const double last_row =
      std::max(1.0, static_cast<double>(rect.bottom - rect.top) - 1.0);
  for (int y = top; y < bottom; ++y) {
    const double t = std::clamp(
        (static_cast<double>(y) - static_cast<double>(rect.top)) / last_row,
        0.0, 1.0);
    double alpha = static_cast<double>(stops[0].alpha);
    for (size_t i = 1; i < stop_count; ++i) {
      const ScrimStop &prev = stops[i - 1];
      const ScrimStop &next = stops[i];
      if (t <= next.position || i == stop_count - 1) {
        const double span = next.position - prev.position;
        const double local =
            span <= 0.0 ? 1.0
                        : std::clamp((t - prev.position) / span, 0.0, 1.0);
        alpha = static_cast<double>(prev.alpha) +
                (static_cast<double>(next.alpha) -
                 static_cast<double>(prev.alpha)) *
                    local;
        break;
      }
    }
    const uint32_t a = static_cast<uint32_t>(
        std::clamp(static_cast<int>(alpha + 0.5), 1, 255));
    const uint32_t pixel = a << 24;
    uint32_t *row = pixels + static_cast<size_t>(y) * dib_width;
    for (int x = left; x < right; ++x) {
      row[x] = pixel;
    }
  }
}

// Collapses overlapping rects into disjoint bounding boxes (N is tiny: the two
// bars plus at most one open menu/info panel). Non-overlapping rects — chiefly
// the top and bottom bars with the transparent middle between them — stay
// separate, so each is cleared/composited without touching the gap.
std::vector<RECT> MergeDirtyRects(std::vector<RECT> rects) {
  rects.erase(std::remove_if(rects.begin(), rects.end(),
                             [](const RECT &r) {
                               return r.right <= r.left || r.bottom <= r.top;
                             }),
              rects.end());
  bool merged = true;
  while (merged) {
    merged = false;
    for (size_t i = 0; i < rects.size() && !merged; ++i) {
      for (size_t j = i + 1; j < rects.size(); ++j) {
        RECT scratch;
        if (IntersectRect(&scratch, &rects[i], &rects[j])) {
          UnionRect(&rects[i], &rects[i], &rects[j]);
          rects.erase(rects.begin() + j);
          merged = true;
          break;
        }
      }
    }
  }
  return rects;
}

// How much of the pixel centred on ([px], [py]) a rounded rect covers, in
// [0, 1]. Only the four corners ever return a fraction; everywhere else inside
// the rect the nearest corner-circle centre clamps onto the pixel itself.
double RoundRectCoverage(double px, double py, const RECT &rect,
                         double radius) {
  const double cx = std::clamp(px, static_cast<double>(rect.left) + radius,
                               static_cast<double>(rect.right) - radius);
  const double cy = std::clamp(py, static_cast<double>(rect.top) + radius,
                               static_cast<double>(rect.bottom) - radius);
  const double dx = px - cx;
  const double dy = py - cy;
  return std::clamp(radius + 0.5 - std::sqrt(dx * dx + dy * dy), 0.0, 1.0);
}

// Rounds the corners of an already-composited region by scaling its
// premultiplied pixels down to the shape's coverage.
//
// It has to be a post-pass because nothing in GDI can say "transparent here":
// `RoundRect` leaves the pixels outside its curve untouched, and
// [NormalizeNativeControlBitmapAlpha] then reads an untouched pixel's zero
// alpha as "GDI drew this" and forces it **fully opaque**. So a rounded panel
// floating over the video came back as a hard black square with the rounded
// fill invisible inside it — which is what the stream-info panel looked like.
// Only shapes that sit *outside* the control bars need this; a button's corner
// falls on the bars' gradient backdrop, which already carries a non-zero alpha
// and is left alone.
//
// Coverage is fractional at the curve, so the corners come out smooth — GDI's
// own `RoundRect` is not antialiased.
void ApplyRoundRectAlphaMask(uint32_t *pixels, int width, int height,
                             const RECT &rect, int radius) {
  if (pixels == nullptr) {
    return;
  }
  const double r = std::min(
      {static_cast<double>(radius), RectWidth(rect) / 2.0,
       RectHeight(rect) / 2.0});
  if (r <= 0.0) {
    return;
  }
  const int left = std::max(0, static_cast<int>(rect.left));
  const int top = std::max(0, static_cast<int>(rect.top));
  const int right = std::min(width, static_cast<int>(rect.right));
  const int bottom = std::min(height, static_cast<int>(rect.bottom));
  for (int y = top; y < bottom; ++y) {
    uint32_t *row = pixels + (static_cast<size_t>(y) * width);
    for (int x = left; x < right; ++x) {
      const double coverage =
          RoundRectCoverage(x + 0.5, y + 0.5, rect, r);
      if (coverage >= 1.0) {
        continue;
      }
      uint32_t &pixel = row[x];
      if (coverage <= 0.0) {
        pixel = 0;
        continue;
      }
      // Premultiplied, so every channel scales with the alpha. Written by bit
      // position rather than by name: this DIB's channel order is whatever
      // [NormalizeNativeControlBitmapAlpha] wrote, and the operation is the
      // same for all four either way.
      const uint32_t a =
          static_cast<uint32_t>(((pixel >> 24) & 0xFF) * coverage + 0.5);
      const uint32_t c2 =
          static_cast<uint32_t>(((pixel >> 16) & 0xFF) * coverage + 0.5);
      const uint32_t c1 =
          static_cast<uint32_t>(((pixel >> 8) & 0xFF) * coverage + 0.5);
      const uint32_t c0 =
          static_cast<uint32_t>((pixel & 0xFF) * coverage + 0.5);
      pixel = (a << 24) | (c2 << 16) | (c1 << 8) | c0;
    }
  }
}

void NormalizeNativeControlBitmapAlpha(uint32_t *pixels,
                                       int width,
                                       int height,
                                       const RECT &rect,
                                       COLORREF background_color,
                                       BYTE background_alpha) {
  const uint32_t background_rgb = (GetBValue(background_color)) |
                                  (GetGValue(background_color) << 8) |
                                  (GetRValue(background_color) << 16);
  for (int y = rect.top; y < rect.bottom; ++y) {
    uint32_t *row = pixels + (y * width);
    for (int x = rect.left; x < rect.right; ++x) {
      uint32_t &pixel = row[x];
      const uint32_t rgb = pixel & 0x00FFFFFF;
      uint32_t alpha = pixel >> 24;
      if (rgb == background_rgb) {
        alpha = background_alpha;
      } else if (alpha == 0) {
        alpha = 0xFF;
      }
      const uint32_t red = (GetRValue(pixel) * alpha + 127) / 255;
      const uint32_t green = (GetGValue(pixel) * alpha + 127) / 255;
      const uint32_t blue = (GetBValue(pixel) * alpha + 127) / 255;
      pixel = (alpha << 24) | (blue << 16) | (green << 8) | red;
    }
  }
}

// The DIB the overlay is currently painting into.
//
// A file-scope target rather than a parameter threaded through every draw
// helper: there is exactly one overlay, painting is synchronous, and the
// alternative is changing the signature of every `Draw*` in this file plus each
// of their call sites. [FillRoundRectAA] falls back to GDI when no target is
// set, so nothing depends on it having been established.
struct OverlayPaintTarget {
  uint32_t *pixels = nullptr;
  int width = 0;
  int height = 0;
};
OverlayPaintTarget g_overlay_paint_target;

// Scopes [g_overlay_paint_target] to one paint, including the early returns.
class ScopedOverlayPaintTarget {
public:
  ScopedOverlayPaintTarget(uint32_t *pixels, int width, int height) {
    g_overlay_paint_target = OverlayPaintTarget{pixels, width, height};
  }
  ~ScopedOverlayPaintTarget() { g_overlay_paint_target = OverlayPaintTarget{}; }
  ScopedOverlayPaintTarget(const ScopedOverlayPaintTarget &) = delete;
  ScopedOverlayPaintTarget &
  operator=(const ScopedOverlayPaintTarget &) = delete;
};

// [radius] is a **corner radius**, as everywhere else in this app.
//
// GDI's `RoundRect` does not take one: its last two arguments are the width and
// height of the ellipse the corner is a quarter of, i.e. twice the radius. Every
// call here used to pass the radius straight through, so a shape asking for 12
// was drawn with a 6px corner — half of what the same constant means in the
// Flutter and Compose overlays, and half of what [FillRoundRectAA] and
// [ApplyRoundRectAlphaMask] produce from the same number.
void FillRoundRect(HDC hdc, const RECT &rect, int radius, COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  HBRUSH old_brush = static_cast<HBRUSH>(SelectObject(hdc, brush));
  HPEN pen = CreatePen(PS_SOLID, 1, color);
  HPEN old_pen = static_cast<HPEN>(SelectObject(hdc, pen));
  RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, radius * 2,
            radius * 2);
  SelectObject(hdc, old_pen);
  SelectObject(hdc, old_brush);
  DeleteObject(pen);
  DeleteObject(brush);
}

// An **antialiased** rounded fill, composited straight into the overlay's DIB.
//
// GDI's `RoundRect` has no antialiasing, so every corner in the control bars
// was a visible staircase — obvious on a button sitting over a bright frame,
// and worst on the volume thumb, which is a circle drawn as a round rect. There
// is no GDI quality flag for this; the shape has to be rasterized with coverage.
//
// **Only safe over pixels whose alpha is already correct**, which in this
// overlay means the control bars' gradient backdrop (written directly by
// [FillVerticalScrim]) and anything already composited by this function. It
// must *not* be used over a surface GDI drew, because GDI leaves the alpha byte
// at 0 until [NormalizeNativeControlBitmapAlpha] runs at the very end of the
// paint — blending against that reads the destination as transparent. That is
// why the floating panels and the menu's own rows stay on plain [FillRoundRect]
// plus [ApplyRoundRectAlphaMask], and everything inside the bars uses this.
void FillRoundRectAA(HDC hdc, const RECT &rect, int radius, COLORREF color) {
  const OverlayPaintTarget target = g_overlay_paint_target;
  if (target.pixels == nullptr) {
    FillRoundRect(hdc, rect, radius, color);
    return;
  }
  // GDI batches drawing per thread; anything still queued for this DC has to
  // land before the CPU touches the same bits.
  GdiFlush();
  const double r =
      std::min({static_cast<double>(radius), RectWidth(rect) / 2.0,
                RectHeight(rect) / 2.0});
  // A COLORREF is 0x00BBGGRR; a 32bpp BI_RGB DIB is B,G,R,A in memory, i.e.
  // blue in the low bits. (`NormalizeNativeControlBitmapAlpha` names its
  // channels the other way round, which is harmless there because it only ever
  // scales each one in place.)
  const uint32_t src_b = GetBValue(color);
  const uint32_t src_g = GetGValue(color);
  const uint32_t src_r = GetRValue(color);
  const int left = std::max(0, static_cast<int>(rect.left));
  const int top = std::max(0, static_cast<int>(rect.top));
  const int right = std::min(target.width, static_cast<int>(rect.right));
  const int bottom = std::min(target.height, static_cast<int>(rect.bottom));
  for (int y = top; y < bottom; ++y) {
    uint32_t *row = target.pixels + (static_cast<size_t>(y) * target.width);
    for (int x = left; x < right; ++x) {
      const double coverage =
          r <= 0.0 ? 1.0 : RoundRectCoverage(x + 0.5, y + 0.5, rect, r);
      if (coverage <= 0.0) {
        continue;
      }
      uint32_t &pixel = row[x];
      if (coverage >= 1.0) {
        pixel = (0xFFu << 24) | (src_r << 16) | (src_g << 8) | src_b;
        continue;
      }
      // Source-over, both sides premultiplied; the source is opaque, so its
      // premultiplied contribution is simply `channel * coverage`.
      const double inv = 1.0 - coverage;
      const uint32_t a = static_cast<uint32_t>(
          255.0 * coverage + ((pixel >> 24) & 0xFF) * inv + 0.5);
      if (a == 0) {
        // Leaving it untouched matters: a zero-alpha pixel is what
        // [NormalizeNativeControlBitmapAlpha] reads as "GDI drew here" and
        // forces opaque, so writing one would plant a black dot.
        continue;
      }
      const uint32_t nr = static_cast<uint32_t>(
          src_r * coverage + ((pixel >> 16) & 0xFF) * inv + 0.5);
      const uint32_t ng = static_cast<uint32_t>(
          src_g * coverage + ((pixel >> 8) & 0xFF) * inv + 0.5);
      const uint32_t nb =
          static_cast<uint32_t>(src_b * coverage + (pixel & 0xFF) * inv + 0.5);
      pixel = (std::min(a, 255u) << 24) | (std::min(nr, 255u) << 16) |
              (std::min(ng, 255u) << 8) | std::min(nb, 255u);
    }
  }
}

// One size for every control-bar button, shared with the other two overlays.
//
// The Flutter overlay's pointer metrics are 44x40 with a 12px radius
// (`EmbeddedOverlayMetrics`, `_chrome`), and Android's Compose overlay is 44dp
// (`PlayerDimens.ButtonSize`). This surface had grown four different sizes —
// play 42x42, the seek buttons 44x36, the icon buttons 36x36 and the aspect
// button 52x36 — so the row stepped up and down across its own length while the
// other two players stayed uniform. Text buttons still set their own width;
// nothing sets its own height.
constexpr int kNativeButtonWidth = 44;
constexpr int kNativeButtonHeight = 40;
constexpr int kNativeButtonRadius = 12;

// Padding either side of a measured text chip's label. Mirrors the Lua OSD's
// `text_button_width` (`pad_h * 2 + measure(text)`), so the two surfaces size a
// chip the same way rather than one measuring and the other guessing.
constexpr int kNativeChipPaddingX = 14;

// The palette the zap banner and the identity run share with Kotlin
// `PlayerColors` and the Lua OSD's `COLOR` table, named here because those two
// surfaces draw the same rows and must not drift apart on colour either.
// `kNativeLiveColor` is this file's existing LIVE-badge red, reused rather
// than a second red introduced beside it.
const COLORREF kNativeAccentColor = RGB(123, 108, 246);
const COLORREF kNativeTextHiColor = RGB(238, 240, 247);
const COLORREF kNativeTextLoColor = RGB(154, 161, 178);
const COLORREF kNativeLiveColor = RGB(255, 64, 112);
const COLORREF kNativeZapBannerBg = RGB(22, 24, 31);

// The zap banner's own geometry, mirroring the Lua OSD's `draw_zap_banner`
// (which mirrors Compose's `ZapBanner` padding).
constexpr int kNativeZapBannerMarginX = 20;
constexpr int kNativeZapBannerMarginBottom = 18;
constexpr int kNativeZapBannerPadX = 16;
constexpr int kNativeZapBannerPadY = 12;
constexpr int kNativeZapBannerRadius = 12;

// The two floating surfaces. Named because their corners are rounded twice —
// once by GDI's fill, once by [ApplyRoundRectAlphaMask] cutting the alpha —
// and the two radii have to agree.
constexpr int kNativeInfoPanelRadius = 12;
constexpr int kNativeMenuRadius = 16;

// The in-player quick list, drawn as a **mode of the existing list menu**:
// same background, same radius, same header height, same padding, same fonts
// — only the rows differ, because a quick-list row carries a second line, a
// badge and a playing marker where a track row carries a label. Two panels
// that look like two different apps is exactly the drift the shared "Go to
// live"/badge copy rules exist to prevent, and this one shows up beside the
// audio menu on the same screen.
constexpr int kNativeQuickListWidth = 360;
constexpr int kNativeQuickListRowHeight = 46;
constexpr int kNativeQuickListMaxRows = 9;
// Left-anchored on the banner's own margin, so the list and the banner it
// replaces start at the same x.
constexpr int kNativeQuickListMarginX = kNativeZapBannerMarginX;
// The panel is banded **between where the bars would be**, whether they are on
// screen or not: the chrome can be revealed over an open list (a mouse move
// does it), and a panel that jumped when the bars appeared would move the
// cursor's row out from under the eye. It also keeps the panel clear of both
// bars' own alpha normalization, which must not run twice over one pixel.
constexpr int kNativeQuickListMarginTop = kNativeTopControlsHeight + 10;
constexpr int kNativeQuickListMarginBottom =
    kNativeBottomControlsHeightLiveEpg + 10;
// Below this there is no room for a legible panel, and it is not drawn at all.
constexpr int kNativeQuickListMinWidth = 180;

void DrawTextWithFont(HDC hdc, const std::wstring &text, RECT rect, UINT format,
                      HFONT font, COLORREF color) {
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  SetTextColor(hdc, color);
  DrawText(hdc, text.c_str(), -1, &rect, format);
  SelectObject(hdc, old_font);
}

// [active] is the *focused/engaged* chrome (accent fill). [fg_override] tints
// only the glyph, which is a different thing: the favorite star is accent when
// favourited but keeps a neutral background unless it is also focused — the
// same split the Flutter overlay draws, where `_button` takes an icon `color`
// independently of its `active` flag.
void DrawIconButton(HDC hdc, const RECT &rect, const std::wstring &icon,
                    bool active = false,
                    std::optional<COLORREF> fg_override = std::nullopt,
                    int radius = kNativeButtonRadius, int icon_size = 20) {
  const COLORREF bg = active ? RGB(38, 34, 78) : RGB(18, 20, 28);
  const COLORREF fg = fg_override.value_or(active ? RGB(255, 255, 255)
                                                  : RGB(232, 235, 244));
  FillRoundRectAA(hdc, rect, radius, bg);
  HFONT icon_font = UiFont(icon_size, FW_NORMAL, L"Segoe MDL2 Assets");
  DrawTextWithFont(hdc, icon, rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                   icon_font, fg);
  DeleteObject(icon_font);
}

// Width of a text chip sized to its own label, the way every other overlay
// does it.
//
// The chip used to carry a hand-set width covering the *longest* label in its
// cycle, which meant every shorter label sat in an oversized box — visibly so
// once "Stretch" joined the aspect cycle and dragged "Fit" out to its width.
// The Flutter and Compose overlays wrap their content, and the Lua OSD measures
// (`text_button_width`); this makes the Windows chip agree with all three.
//
// Measured against a screen DC because `ComputeBottomLayout` runs outside a
// paint and has no device context of its own. It uses the same font
// `DrawTextButton` will draw with, so the number is the real glyph width rather
// than an estimate. Floored at an icon button's width so a two-letter label
// never renders narrower than the buttons beside it.
int MeasureTextChipWidth(const std::wstring &label) {
  // Cached per label. `ComputeBottomLayout` runs from the paint, the hit test
  // and the focus-ring walk — several times a frame while the overlay is up —
  // and creating a font plus a screen DC for each of those, to re-measure one
  // of five fixed strings, is work with a known answer. The key set is the
  // aspect cycle, so the map never grows past a handful of entries. UI thread
  // only, like everything else in this file's layout path.
  static std::map<std::wstring, int> cache;
  const auto hit = cache.find(label);
  if (hit != cache.end()) {
    return hit->second;
  }
  HDC screen = GetDC(nullptr);
  if (screen == nullptr) {
    return kNativeButtonWidth;
  }
  HFONT font = UiFont(13, FW_BOLD);
  HFONT old_font = static_cast<HFONT>(SelectObject(screen, font));
  SIZE size{};
  GetTextExtentPoint32(screen, label.c_str(), static_cast<int>(label.size()),
                       &size);
  SelectObject(screen, old_font);
  DeleteObject(font);
  ReleaseDC(nullptr, screen);
  const int width = size.cx + kNativeChipPaddingX * 2;
  const int clamped = width < kNativeButtonWidth ? kNativeButtonWidth : width;
  cache.emplace(label, clamped);
  return clamped;
}

void DrawTextButton(HDC hdc, const RECT &rect, const std::wstring &label,
                    bool active = false) {
  const COLORREF bg = active ? RGB(38, 34, 78) : RGB(18, 20, 28);
  const COLORREF fg = active ? RGB(255, 255, 255) : RGB(232, 235, 244);
  FillRoundRectAA(hdc, rect, kNativeButtonRadius, bg);
  // Bold, matching the badges — a button label is a handful of short words at
  // 13px on top of moving video, and SemiBold left them looking thin next to
  // the badge row drawn a few pixels above.
  HFONT font = UiFont(13, FW_BOLD);
  DrawTextWithFont(hdc, label, rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                   font, fg);
  DeleteObject(font);
}

double RatioFromX(int x, const RECT &rect) {
  return std::clamp(static_cast<double>(x - rect.left) /
                        static_cast<double>(std::max(1, RectWidth(rect))),
                    0.0, 1.0);
}

RECT TopControlsRect(const RECT &rect) {
  return RectFrom(0, 0, rect.right, kNativeTopControlsHeight);
}

bool HasLiveEpg() {
  return g_native_control_state.is_live &&
         !g_native_control_state.epg_now_title.empty() &&
         g_native_control_state.epg_now_stop_ms >
             g_native_control_state.epg_now_start_ms;
}

int BottomControlsHeight() {
  if (g_native_control_state.is_live) {
    int height = HasLiveEpg() ? kNativeBottomControlsHeightLiveEpg
                              : kNativeBottomControlsHeightLive;
    // The identity run adds its own row above the strip, on the same terms as
    // the strip itself: only when there is something to say (see
    // ShowsChannelIdentity), so a non-zapping session's bar is unchanged.
    if (ShowsChannelIdentity()) {
      height += kNativeIdentityRowHeight + kNativeIdentityRowGap;
    }
    return height;
  }
  return kNativeBottomControlsHeightVod;
}

RECT BottomControlsRect(const RECT &rect) {
  return RectFrom(0, MaxInt(0, rect.bottom - BottomControlsHeight()),
                  rect.right, rect.bottom);
}

RECT OffsetRectToLocal(RECT rect, int dx, int dy) {
  rect.left -= dx;
  rect.right -= dx;
  rect.top -= dy;
  rect.bottom -= dy;
  return rect;
}

// Single source of truth for the bottom-bar geometry, shared by paint,
// hit-testing, the click-through region, and the menu anchor. The right cluster
// is laid out from the right edge leftward so hidden (contextual) buttons don't
// leave gaps.
struct BottomLayout {
  RECT bottom;
  int control_center_y = 0;
  RECT play;
  bool has_seek = false;
  RECT seek_back;
  RECT seek_forward;
  RECT mute;
  RECT volume; // thin slider track
  bool has_scrubber = false;
  RECT progress; // thin slider track
  RECT position_text;
  RECT duration_text;
  // The zap identity run ("12 · BBC One"), above the strip. Drawn only while
  // it says something the top bar's title does not.
  bool has_identity = false;
  RECT identity;
  // Live EPG strip (programme title + progress + next), where the scrubber
  // sits. One band: DrawLiveEpgStrip lays its three rows out inside it, so the
  // bar and the zap banner cannot end up with two different strips.
  bool has_epg = false;
  RECT epg;
  bool has_speed = false;
  bool has_audio = false;
  bool has_subtitles = false;
  RECT speed;
  RECT audio;
  RECT subtitles;
  RECT aspect;
  RECT info;
  RECT fullscreen;
  bool has_go_live = false;
  RECT go_live; // live-only "jump to live edge" button
  bool has_favorite = false;
  RECT favorite;
};

BottomLayout ComputeBottomLayout(const RECT &rect) {
  BottomLayout l;
  l.bottom = BottomControlsRect(rect);
  const int by = l.bottom.top;
  const int right = MaxInt(0, static_cast<int>(rect.right));
  const bool live = g_native_control_state.is_live;
  // Control row sits a fixed 40px above the bottom edge in every layout
  // (VOD = scrubber above; live-EPG = programme row above; bare live = single row).
  const int cy = by + (BottomControlsHeight() - 40);
  l.control_center_y = cy;
  const int kBtn = kNativeButtonWidth;
  const int top = cy - kNativeButtonHeight / 2;
  const int bot = top + kNativeButtonHeight;

  int x = 16;
  l.play = RectFrom(x, top, x + kBtn, bot);
  x += kBtn + 8;
  l.has_seek = !live;
  if (l.has_seek) {
    l.seek_back = RectFrom(x, top, x + kBtn, bot);
    x += kBtn + 8;
    l.seek_forward = RectFrom(x, top, x + kBtn, bot);
    x += kBtn + 14;
  }
  l.mute = RectFrom(x, top, x + kBtn, bot);
  x += kBtn + 8;
  l.volume = RectFrom(x, cy - 3, x + 84, cy + 3);

  int rx = right - 16;
  const auto place = [&](RECT &out, int w) {
    out = RectFrom(rx - w, top, rx, bot);
    rx -= w + 8;
  };
  place(l.fullscreen, kBtn);
  place(l.info, kBtn);
  // Sized to the label it is about to draw. `DrawTextButton` renders with
  // `DT_SINGLELINE` and no `DT_NOCLIP`, so a chip narrower than its text clips
  // rather than overflowing visibly — and a chip sized for the cycle's longest
  // label leaves every shorter one rattling around in it.
  place(l.aspect, MeasureTextChipWidth(
                      g_native_control_state.aspect_label.empty()
                          ? L"Fit"
                          : g_native_control_state.aspect_label));
  l.has_subtitles = !g_native_control_state.subtitle_tracks.empty();
  if (l.has_subtitles) {
    place(l.subtitles, kBtn);
  }
  l.has_audio = !g_native_control_state.audio_tracks.empty();
  if (l.has_audio) {
    place(l.audio, kBtn);
  }
  l.has_speed = !g_native_control_state.speed_options.empty();
  if (l.has_speed) {
    // Left as a constant: every speed label is within a few pixels of the
    // others ("0.5x" to "1.25x"), so there is no oversized-box problem to
    // solve, and `ShortSpeed` is defined below this function.
    place(l.speed, 54);
  }
  // The favorite star, between "Go to live" and speed — the slot Android's
  // `RightCluster` puts it in. It used to live in the *top* bar among the
  // badges at compact size; here it is an ordinary member of this row and takes
  // the row's geometry, so all three overlays agree on place and size.
  l.has_favorite = g_native_control_state.can_favorite;
  if (l.has_favorite) {
    place(l.favorite, kBtn);
  }
  // "Go to live" button, shown only once behind the live edge; left end of the
  // right cluster. 92px carries the full label at 13px semibold (the old 54
  // sized a bare "LIVE").
  l.has_go_live = live && !g_native_control_state.live_synced;
  if (l.has_go_live) {
    place(l.go_live, 92);
  }

  l.has_scrubber = !live;
  if (l.has_scrubber) {
    const int sy = by + 30;
    const int time_w = 62;
    l.position_text = RectFrom(16, sy - 12, 16 + time_w, sy + 12);
    l.duration_text =
        RectFrom(right - 16 - time_w, sy - 12, right - 16, sy + 12);
    l.progress =
        RectFrom(16 + time_w + 12, sy - 3, right - 16 - time_w - 12, sy + 3);
  }

  // The live block sits in the upper part of the (taller) live bar, well clear
  // of the control row below: the identity run first when there is one, then
  // the programme strip.
  int ey = by + 18;
  l.has_identity = ShowsChannelIdentity();
  if (l.has_identity) {
    l.identity = RectFrom(16, ey, MaxInt(20, right - 16),
                          ey + kNativeIdentityRowHeight);
    ey += kNativeIdentityRowHeight + kNativeIdentityRowGap;
  }
  l.has_epg = HasLiveEpg();
  if (l.has_epg) {
    l.epg = RectFrom(16, ey, MaxInt(20, right - 16), ey + kNativeEpgStripHeight);
  }
  return l;
}

int MenuAnchorX(const BottomLayout &l) {
  switch (g_native_control_state.open_menu) {
  case NativeMenuKind::kAudio:
    return (l.audio.left + l.audio.right) / 2;
  case NativeMenuKind::kSubtitles:
    return (l.subtitles.left + l.subtitles.right) / 2;
  case NativeMenuKind::kSpeed:
    return (l.speed.left + l.speed.right) / 2;
  default:
    return (l.fullscreen.left + l.fullscreen.right) / 2;
  }
}

// The overlay is two rows, and arrow-key navigation treats them differently:
// Left/Right cycles within a row, Up returns to Back, Down drops into the
// transport. Back is the only control in the top row — the favorite star used
// to sit beside it and now lives in the control row with everything else.
bool IsTopBarFocusItem(NativeFocusItem item) {
  return item == NativeFocusItem::kBack;
}

std::vector<NativeFocusItem> FocusableItems(const BottomLayout &l) {
  std::vector<NativeFocusItem> out;
  out.push_back(NativeFocusItem::kBack);
  out.push_back(NativeFocusItem::kPlay);
  if (l.has_seek) {
    out.push_back(NativeFocusItem::kSeekBack);
    out.push_back(NativeFocusItem::kSeekForward);
  }
  out.push_back(NativeFocusItem::kMute);
  // Match visual order: LIVE is leftmost in the right cluster, before CC/audio,
  // aspect, info, and fullscreen.
  if (l.has_go_live) out.push_back(NativeFocusItem::kGoLive);
  if (l.has_favorite) out.push_back(NativeFocusItem::kFavorite);
  if (l.has_speed) out.push_back(NativeFocusItem::kSpeed);
  if (l.has_audio) out.push_back(NativeFocusItem::kAudio);
  if (l.has_subtitles) out.push_back(NativeFocusItem::kSubtitles);
  out.push_back(NativeFocusItem::kAspect);
  out.push_back(NativeFocusItem::kInfo);
  out.push_back(NativeFocusItem::kFullscreen);
  return out;
}

std::string CommandForFocusedItem(NativeFocusItem item) {
  switch (item) {
  case NativeFocusItem::kBack:
    return "back";
  case NativeFocusItem::kFavorite:
    return "favorite";
  case NativeFocusItem::kPlay:
    return "playPause";
  case NativeFocusItem::kSeekBack:
    return "seekBack";
  case NativeFocusItem::kSeekForward:
    return "seekForward";
  case NativeFocusItem::kMute:
    return "muteToggle";
  case NativeFocusItem::kSpeed:
    return "menu:speed";
  case NativeFocusItem::kAudio:
    return "menu:audio";
  case NativeFocusItem::kSubtitles:
    return "menu:subtitles";
  case NativeFocusItem::kAspect:
    return "aspect";
  case NativeFocusItem::kInfo:
    return "info";
  case NativeFocusItem::kFullscreen:
    return "fullscreen";
  case NativeFocusItem::kGoLive:
    return "goLive";
  }
  return "show";
}

void EnsureSelectedMenuVisible();

void ApplyOverlayOwnedCommand(HWND controls_hwnd,
                              HWND owner_hwnd,
                              const std::string &command) {
  if (command.rfind("menu:", 0) == 0) {
    const NativeMenuKind kind = command == "menu:audio"
                                    ? NativeMenuKind::kAudio
                                : command == "menu:subtitles"
                                    ? NativeMenuKind::kSubtitles
                                : command == "menu:speed"
                                    ? NativeMenuKind::kSpeed
                                    : NativeMenuKind::kNone;
    if (g_native_control_state.open_menu == kind) {
      g_native_control_state.open_menu = NativeMenuKind::kNone;
    } else {
      g_native_control_state.open_menu = kind;
      g_native_control_state.info_open = false;
      g_native_menu_scroll_offset = 0;
      EnsureSelectedMenuVisible();
    }
    if (owner_hwnd) {
      KillTimer(owner_hwnd, kNativeControlsHideTimer);
      PostMessage(owner_hwnd, kNativeControlsLayoutMessage, 0, 0);
    }
    if (controls_hwnd) {
      InvalidateRect(controls_hwnd, nullptr, FALSE);
    }
    return;
  }

  if (command == "info") {
    g_native_control_state.info_open = !g_native_control_state.info_open;
    if (g_native_control_state.info_open) {
      g_native_control_state.open_menu = NativeMenuKind::kNone;
    }
    if (owner_hwnd) {
      KillTimer(owner_hwnd, kNativeControlsHideTimer);
      PostMessage(owner_hwnd, kNativeControlsLayoutMessage, 0, 0);
    }
    if (controls_hwnd) {
      InvalidateRect(controls_hwnd, nullptr, FALSE);
    }
  }
}

int MenuVisibleRowCount() {
  const auto &options = MenuOptions(g_native_control_state.open_menu);
  if (options.empty()) {
    return 1;
  }
  return std::clamp(static_cast<int>(options.size()), 1, kNativeMenuMaxRows);
}

int MenuMaxScrollOffset() {
  const auto &options = MenuOptions(g_native_control_state.open_menu);
  return MaxInt(0, static_cast<int>(options.size()) - kNativeMenuMaxRows);
}

void ClampMenuScrollOffset() {
  g_native_menu_scroll_offset =
      std::clamp(g_native_menu_scroll_offset, 0, MenuMaxScrollOffset());
}

void EnsureSelectedMenuVisible() {
  const auto &options = MenuOptions(g_native_control_state.open_menu);
  const auto &selected_id = MenuSelectedId(g_native_control_state.open_menu);
  int selected = -1;
  for (size_t i = 0; i < options.size(); i++) {
    if (options[i].id == selected_id) {
      selected = static_cast<int>(i);
      break;
    }
  }
  if (selected < 0) {
    ClampMenuScrollOffset();
    return;
  }
  if (selected < g_native_menu_scroll_offset) {
    g_native_menu_scroll_offset = selected;
  } else if (selected >= g_native_menu_scroll_offset + kNativeMenuMaxRows) {
    g_native_menu_scroll_offset = selected - kNativeMenuMaxRows + 1;
  }
  ClampMenuScrollOffset();
}

RECT MenuRect(const RECT &rect, int anchor_x) {
  const auto &options = MenuOptions(g_native_control_state.open_menu);
  const int width = RectWidth(rect);
  const int height = RectHeight(rect);
  const int menu_width = std::min(kNativeMenuWidth, MaxInt(1, width - 24));
  const int rows =
      std::clamp(static_cast<int>(options.empty() ? 1 : options.size()), 1,
                 kNativeMenuMaxRows);
  const int menu_height = kNativeMenuHeaderHeight + rows * kNativeMenuRowHeight +
                          kNativeMenuPadding;
  const int menu_left = std::clamp(anchor_x - (menu_width / 2), 12,
                                   MaxInt(12, width - menu_width - 12));
  const int menu_top =
      MaxInt(8, height - BottomControlsHeight() - menu_height - 8);
  return RectFrom(menu_left, menu_top, menu_left + menu_width,
                  menu_top + menu_height);
}

RECT CurrentMenuRect(const RECT &rect) {
  if (g_native_control_state.open_menu == NativeMenuKind::kNone) {
    return RectFrom(0, 0, 0, 0);
  }
  const BottomLayout layout = ComputeBottomLayout(rect);
  return MenuRect(rect, MenuAnchorX(layout));
}

std::vector<RECT> MenuOptionRects(const RECT &rect) {
  std::vector<RECT> out;
  const int visible_rows = MenuVisibleRowCount();
  const int left = 10;
  const int right = rect.right - 10;
  int top = kNativeMenuHeaderHeight;
  for (int i = 0; i < visible_rows; i++) {
    out.push_back(RectFrom(left, top, right, top + kNativeMenuRowHeight - 4));
    top += kNativeMenuRowHeight;
  }
  return out;
}

// Tiers match Kotlin `PlayerUiState.resolutionBadge`, Swift
// `BadgeFormatting.resolutionBadge` and Dart `resolutionBadgeLabel`. They are
// deliberately loose: a 1088-tall or 1912-wide stream (both common from IPTV
// providers) is still 1080p, which the old exact `h >= 1080` test called 720p.
std::wstring ResolutionBadge() {
  const int w = g_native_control_state.video_width;
  const int h = g_native_control_state.video_height;
  if (w <= 0 || h <= 0) {
    return L"";
  }
  if (h >= 2000 || w >= 3500) {
    return L"4K";
  }
  if (h >= 1400 || w >= 2400) {
    return L"1440p";
  }
  if (h >= 1000 || w >= 1800) {
    return L"1080p";
  }
  if (h >= 700 || w >= 1200) {
    return L"720p";
  }
  return L"SD";
}

std::wstring HdrBadge() {
  const std::wstring &dr = g_native_control_state.dynamic_range;
  if (dr.find(L"Dolby") != std::wstring::npos ||
      dr.find(L"DV") != std::wstring::npos) {
    return L"DV";
  }
  if (dr.find(L"HDR10+") != std::wstring::npos) {
    return L"HDR10+";
  }
  if (dr.find(L"HDR10") != std::wstring::npos) {
    return L"HDR10";
  }
  if (dr.find(L"HLG") != std::wstring::npos) {
    return L"HLG";
  }
  if (dr.find(L"HDR") != std::wstring::npos) {
    return L"HDR";
  }
  return L"";
}

std::wstring FormatFps(double fps) {
  if (fps <= 0.0) {
    return L"";
  }
  wchar_t buffer[32];
  if (std::abs(fps - std::round(fps)) < 0.01) {
    swprintf_s(buffer, L"%.0f fps", fps);
  } else {
    swprintf_s(buffer, L"%.3f fps", fps);
    std::wstring text(buffer);
    const size_t space = text.find(L' ');
    std::wstring number = text.substr(0, space);
    while (!number.empty() && number.back() == L'0') {
      number.pop_back();
    }
    if (!number.empty() && number.back() == L'.') {
      number.pop_back();
    }
    return number + L" fps";
  }
  return buffer;
}

int64_t NowMs() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

// Date + time for the top-bar clock badge, e.g. "Fri 26 Jun · 23:09" (locale names).
std::wstring FormatClock() {
  std::time_t t = std::time(nullptr);
  std::tm local{};
  if (localtime_s(&local, &t) != 0) {
    return L"";
  }
  wchar_t buffer[64];
  // `%#d` is MSVC's "no leading zero" flag: "Sat 8 Aug", the same shape Kotlin's
  // `EEE d MMM` and Dart's `playerClockLabel` produce. `%d` here was the only
  // one padding it to "Sat 08 Aug".
  if (wcsftime(buffer, 64, L"%a %#d %b · %H:%M", &local) == 0) {
    return L"";
  }
  return buffer;
}

// Wall-clock HH:mm for EPG programme start/stop labels.
std::wstring FormatClockHm(double epoch_ms) {
  if (epoch_ms <= 0.0) {
    return L"";
  }
  std::time_t t = static_cast<std::time_t>(epoch_ms / 1000.0);
  std::tm local{};
  if (localtime_s(&local, &t) != 0) {
    return L"";
  }
  wchar_t buffer[16];
  if (wcsftime(buffer, 16, L"%H:%M", &local) == 0) {
    return L"";
  }
  return buffer;
}

// Badge form of the frame rate: "25fps" / "23.976fps", **no space** — matching
// Kotlin `fpsBadge`, Swift `BadgeFormatting.fpsBadge` and Dart `fpsBadgeLabel`.
// The info panel keeps [FormatFps]'s spaced "25 fps", which is a reading line
// rather than a badge (the natives split it the same way).
std::wstring FpsBadge(double fps) {
  std::wstring text = FormatFps(fps);
  const size_t space = text.find(L' ');
  if (space != std::wstring::npos) {
    text.erase(space, 1);
  }
  return text;
}

std::wstring TruncateBadge(const std::wstring &text, size_t max_len) {
  if (text.size() <= max_len) {
    return text;
  }
  return text.substr(0, max_len - 1) + L"…";
}

std::vector<std::pair<std::wstring, std::wstring>> InfoRows() {
  std::vector<std::pair<std::wstring, std::wstring>> rows;
  const auto &s = g_native_control_state;
  if (s.video_width > 0 && s.video_height > 0) {
    rows.push_back({L"Resolution", std::to_wstring(s.video_width) + L"×" +
                                       std::to_wstring(s.video_height)});
  }
  const std::wstring fps = FormatFps(s.fps);
  if (!fps.empty()) {
    rows.push_back({L"Frame rate", fps});
  }
  if (!s.dynamic_range.empty()) {
    rows.push_back({L"Dynamic range", s.dynamic_range});
  }
  if (!s.video_codec.empty()) {
    rows.push_back({L"Video", s.video_codec});
  }
  if (!s.audio_codec.empty() || !s.audio_channels.empty()) {
    std::wstring audio = s.audio_codec;
    if (!s.audio_channels.empty()) {
      if (!audio.empty()) {
        audio += L" ";
      }
      audio += s.audio_channels;
    }
    rows.push_back({L"Audio", audio});
  }
  return rows;
}

bool HasInfoPanel() {
  return g_native_control_state.info_open && !InfoRows().empty();
}

RECT InfoPanelRect(const RECT &rect) {
  const int rows = static_cast<int>(InfoRows().size());
  const int width = 224;
  const int height = 12 + 22 + rows * 22 + 10;
  const int left = MaxInt(12, static_cast<int>(rect.right) - 14 - width);
  const int top = kNativeTopControlsHeight + 10;
  return RectFrom(left, top, left + width, top + height);
}

void DrawSlider(HDC hdc, const RECT &track, double ratio, int thumb_radius) {
  const int cy = (track.top + track.bottom) / 2;
  FillRoundRectAA(hdc, RectFrom(track.left, cy - 3, track.right, cy + 3), 6,
                  RGB(39, 43, 58));
  const int fill_x =
      track.left + static_cast<int>(RectWidth(track) * std::clamp(ratio, 0.0,
                                                                  1.0));
  FillRoundRectAA(hdc, RectFrom(track.left, cy - 3, fill_x, cy + 3), 6,
                  RGB(123, 108, 246));
  // A square of side 2r at radius r is a circle — and now a smooth one.
  FillRoundRectAA(hdc,
                  RectFrom(fill_x - thumb_radius, cy - thumb_radius,
                           fill_x + thumb_radius, cy + thumb_radius),
                  thumb_radius, RGB(154, 141, 255));
}

// Draws a pill badge ending at [right_edge]; returns the horizontal space it
// consumed (badge width + trailing gap) so callers can stack badges leftward.
// [aa] is false for a badge drawn inside a floating panel, whose background
// GDI has just laid down with its alpha still at 0 — the antialiased
// compositor would read that as transparent and blend into nothing. Same
// split as FillRoundRectMaybeAA, which is declared below this and so cannot
// be called from here.
int DrawBadge(HDC hdc, int right_edge, int center_y, const std::wstring &text,
              COLORREF bg, COLORREF fg, bool aa = true) {
  HFONT font = UiFont(11, FW_BOLD);
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  SIZE size{};
  GetTextExtentPoint32(hdc, text.c_str(), static_cast<int>(text.size()),
                       &size);
  SelectObject(hdc, old_font);
  const int width = size.cx + 18;
  const RECT badge =
      RectFrom(right_edge - width, center_y - 11, right_edge, center_y + 11);
  if (aa) {
    FillRoundRectAA(hdc, badge, 7, bg);
  } else {
    FillRoundRect(hdc, badge, 7, bg);
  }
  DrawTextWithFont(hdc, text, badge, DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                   font, fg);
  DeleteObject(font);
  return width + 8;
}

std::wstring ShortSpeed(const std::string &id) {
  if (id.empty()) {
    return L"1×";
  }
  const double value = atof(id.c_str());
  wchar_t buffer[16];
  if (std::abs(value - std::round(value)) < 0.01) {
    swprintf_s(buffer, L"%.0f×", value);
    return buffer;
  }
  swprintf_s(buffer, L"%.2f×", value);
  std::wstring text(buffer);
  const size_t mult = text.find(L'×');
  std::wstring number = text.substr(0, mult);
  while (!number.empty() && number.back() == L'0') {
    number.pop_back();
  }
  if (!number.empty() && number.back() == L'.') {
    number.pop_back();
  }
  return number + L"×";
}

std::wstring TrimmedText(const std::wstring &value) {
  const wchar_t *kSpace = L" \t\r\n";
  const size_t begin = value.find_first_not_of(kSpace);
  if (begin == std::wstring::npos) {
    return L"";
  }
  const size_t end = value.find_last_not_of(kSpace);
  return value.substr(begin, end - begin + 1);
}

int MeasureTextWidth(HDC hdc, const std::wstring &text, HFONT font) {
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  SIZE size{};
  GetTextExtentPoint32(hdc, text.c_str(), static_cast<int>(text.size()),
                       &size);
  SelectObject(hdc, old_font);
  return static_cast<int>(size.cx);
}

// `12 · BBC One`, or just the name when the provider gave no number. Falls
// back to the route's own title when the cursor has no name yet, exactly as
// Kotlin `channelIdentityLabel()` and the Lua OSD's
// `channel_identity_label()` do.
std::wstring ChannelIdentityLabel() {
  const NativeZapState &z = g_native_zap_state;
  std::wstring name = TrimmedText(z.channel_name);
  if (name.empty()) {
    name = TrimmedText(g_native_control_state.title);
  }
  if (name.empty()) {
    return L"";
  }
  if (!z.has_channel_number) {
    return name;
  }
  return std::to_wstring(z.channel_number) + L" \x00B7 " + name;
}

// [aa] picks between the antialiased compositor and GDI's own aliased fill.
// The split is not cosmetic: FillRoundRectAA blends against the destination's
// alpha, which is only correct over pixels this overlay wrote itself (the
// bars' gradient backdrop). Inside a floating panel the background came from
// GDI with its alpha still at 0 — NormalizeNativeControlBitmapAlpha fixes that
// at the very end of the paint — so blending there would read the panel as
// transparent. Same split PaintListMenu and PaintInfoPanel already make.
void FillRoundRectMaybeAA(HDC hdc, const RECT &rect, int radius,
                          COLORREF color, bool aa) {
  if (aa) {
    FillRoundRectAA(hdc, rect, radius, color);
  } else {
    FillRoundRect(hdc, rect, radius, color);
  }
}

// The three-row live EPG strip — programme title with its HH:mm – HH:mm
// right-aligned opposite it, a thin elapsed-progress bar, then
// "Next · HH:mm – HH:mm · title" — drawn between [x1] and [x2] with its top
// edge at [top_y]. Returns the height it consumed.
//
// Shared by the bottom bar and the zap banner for exactly the reason Kotlin
// shares one composable between `BottomBar` and `ZapBanner`, and the Lua OSD
// one `draw_live_epg_strip`: a channel seen through the banner and the same
// channel seen with the chrome up must read identically. This is the fifth
// surface that has to agree about this strip (docs/player.md), and a second
// copy inside one file would be the easiest of all of them to let drift.
int DrawLiveEpgStrip(HDC hdc, int x1, int x2, int top_y,
                     const std::wstring &now_title, double now_start_ms,
                     double now_stop_ms, const std::wstring &next_title,
                     double next_start_ms, double next_stop_ms, bool aa) {
  const int time_w = 110;
  const int title_right = MaxInt(x1 + 4, x2 - time_w - 10);
  HFONT title_font = UiFont(17, FW_SEMIBOLD);
  DrawTextWithFont(hdc, now_title,
                   RectFrom(x1, top_y, title_right, top_y + 20),
                   DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                   title_font, kNativeTextHiColor);
  DeleteObject(title_font);

  HFONT meta_font = UiFont(16, FW_SEMIBOLD);
  const std::wstring range = FormatClockHm(now_start_ms) + L" \x2013 " +
                             FormatClockHm(now_stop_ms);
  DrawTextWithFont(hdc, range,
                   RectFrom(MaxInt(x1, x2 - time_w), top_y, x2, top_y + 20),
                   DT_RIGHT | DT_VCENTER | DT_SINGLELINE, meta_font,
                   RGB(184, 190, 204));

  // Programme progress: a thin track + elapsed fill (no thumb).
  const double span = std::max(1.0, now_stop_ms - now_start_ms);
  const double progress = std::clamp(
      (static_cast<double>(NowMs()) - now_start_ms) / span, 0.0, 1.0);
  const int track_cy = top_y + 33;
  FillRoundRectMaybeAA(hdc, RectFrom(x1, track_cy - 3, x2, track_cy + 3), 6,
                       RGB(39, 43, 58), aa);
  const int fill_x = x1 + static_cast<int>((x2 - x1) * progress);
  if (fill_x > x1) {
    FillRoundRectMaybeAA(hdc, RectFrom(x1, track_cy - 3, fill_x, track_cy + 3),
                         6, kNativeAccentColor, aa);
  }

  if (!next_title.empty()) {
    // "Next · HH:mm – HH:mm · title" — the one next-programme format the app
    // uses (Kotlin `LiveEpgStrip`, Swift `playerEpgNextLabel`, Dart
    // `_liveEpgStrip`, the Lua OSD).
    const std::wstring next_range = FormatClockHm(next_start_ms) +
                                    L" \x2013 " + FormatClockHm(next_stop_ms);
    DrawTextWithFont(hdc, L"Next \x00B7 " + next_range + L" \x00B7 " + next_title,
                     RectFrom(x1, top_y + 46, x2, top_y + 64),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                     meta_font, RGB(184, 190, 204));
  }
  DeleteObject(meta_font);
  return kNativeEpgStripHeight;
}

// `12 · BBC One`, with the half-typed channel number leading it (accent, and
// the headline while it exists — mid-entry the number being built is the thing
// the user is looking at) and either a transient note or the `position/total`
// place in the launch range trailing it.
//
// Shared by the bottom bar and the banner, field for field with Kotlin
// `ChannelIdentityRow` and the Lua OSD's `draw_channel_identity_row`.
void DrawChannelIdentityRow(HDC hdc, const RECT &row) {
  const NativeZapState &z = g_native_zap_state;
  const std::wstring identity = ChannelIdentityLabel();
  if (identity.empty() && z.digits.empty() && z.message.empty()) {
    return;
  }
  int x = static_cast<int>(row.left);
  const int right = static_cast<int>(row.right);

  if (!z.digits.empty()) {
    HFONT digit_font = UiFont(24, FW_BOLD);
    const int width = MeasureTextWidth(hdc, z.digits, digit_font);
    DrawTextWithFont(hdc, z.digits,
                     RectFrom(x, row.top, x + width, row.bottom),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE, digit_font,
                     kNativeAccentColor);
    DeleteObject(digit_font);
    x += width + 12;
  }

  // The trailing run is measured first: it is right-anchored, and the identity
  // between them takes whatever is left (Compose's `weight(1f)`).
  std::wstring trailing;
  COLORREF trailing_color = kNativeTextLoColor;
  if (!z.message.empty()) {
    trailing = z.message;
    trailing_color = kNativeLiveColor;
  } else if (z.position > 0 && z.total > 0) {
    trailing = std::to_wstring(z.position) + L"/" + std::to_wstring(z.total);
  }
  int trailing_w = 0;
  HFONT trailing_font = UiFont(12, FW_NORMAL);
  if (!trailing.empty()) {
    trailing_w = MeasureTextWidth(hdc, trailing, trailing_font) + 8;
    DrawTextWithFont(hdc, trailing,
                     RectFrom(MaxInt(x, right - trailing_w), row.top, right,
                              row.bottom),
                     DT_RIGHT | DT_VCENTER | DT_SINGLELINE, trailing_font,
                     trailing_color);
  }
  DeleteObject(trailing_font);

  if (!identity.empty()) {
    HFONT font = UiFont(16, FW_SEMIBOLD);
    DrawTextWithFont(hdc, identity,
                     RectFrom(x, row.top, MaxInt(x + 40, right - trailing_w),
                              row.bottom),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                     font, kNativeTextHiColor);
    DeleteObject(font);
  }
}

// The cursor channel's own guide, which is what the banner shows — not the
// playing channel's (NativeControlState's `epg_now_*`).
bool ZapBannerHasEpg() {
  const NativeZapState &z = g_native_zap_state;
  return !z.epg_now_title.empty() &&
         z.epg_now_stop_ms > z.epg_now_start_ms;
}

// Where the banner sits: the bottom-bar slot, so a channel change lands where
// the chrome would have said the same thing. Empty when the window is too
// small to hold it — every caller checks, and nothing paints or clips to an
// empty rect (NormalizeNativeControlBitmapAlpha does not bounds-check, so the
// rect this returns must always be inside the client area).
RECT ZapBannerRect(const RECT &rect) {
  int content = kNativeIdentityRowHeight;
  if (ZapBannerHasEpg()) {
    content += kNativeIdentityRowGap + kNativeEpgStripHeight;
  }
  const int panel_height = content + kNativeZapBannerPadY * 2;
  const int left = kNativeZapBannerMarginX;
  const int right = static_cast<int>(rect.right) - kNativeZapBannerMarginX;
  const int bottom =
      static_cast<int>(rect.bottom) - kNativeZapBannerMarginBottom;
  const int top = bottom - panel_height;
  if (right <= left || top < 0) {
    return RectFrom(0, 0, 0, 0);
  }
  return RectFrom(left, top, right, bottom);
}

// The banner: what a channel change says while the chrome is hidden. It
// carries the same two pieces the bar's live block does — the identity run and
// the EPG strip — rather than a layout of its own, so a channel seen through
// the banner and the same channel seen with the controls up read identically
// (Kotlin `ZapBanner`, the Lua OSD's `draw_zap_banner`).
//
// A floating panel, so it follows the FillRoundRect + normalize +
// ApplyRoundRectAlphaMask path the info panel and the list menu use, not the
// bars' antialiased compositor (see FillRoundRectMaybeAA).
void PaintZapBanner(HDC hdc, uint32_t *pixels, int width, int height,
                    const RECT &panel) {
  if (RectWidth(panel) <= 0 || RectHeight(panel) <= 0) {
    return;
  }
  FillRoundRect(hdc, panel, kNativeZapBannerRadius, kNativeZapBannerBg);
  const int x1 = static_cast<int>(panel.left) + kNativeZapBannerPadX;
  const int x2 = static_cast<int>(panel.right) - kNativeZapBannerPadX;
  if (x2 <= x1) {
    return;
  }
  int y = static_cast<int>(panel.top) + kNativeZapBannerPadY;
  DrawChannelIdentityRow(hdc,
                         RectFrom(x1, y, x2, y + kNativeIdentityRowHeight));
  y += kNativeIdentityRowHeight;
  if (ZapBannerHasEpg()) {
    const NativeZapState &z = g_native_zap_state;
    DrawLiveEpgStrip(hdc, x1, x2, y + kNativeIdentityRowGap, z.epg_now_title,
                     z.epg_now_start_ms, z.epg_now_stop_ms, z.epg_next_title,
                     z.epg_next_start_ms, z.epg_next_stop_ms, /*aa=*/false);
  }
  // Everything above was GDI; the two passes below read and write the DIB's
  // bits directly. FillRoundRectAA flushes for itself, but this path never
  // calls it (`aa=false` throughout), so the flush has to be explicit.
  GdiFlush();
  NormalizeNativeControlBitmapAlpha(pixels, width, height, panel,
                                    kNativeZapBannerBg, 0xFF);
  ApplyRoundRectAlphaMask(pixels, width, height, panel,
                          kNativeZapBannerRadius);
}

// Composites the dirty bands of the cached back-buffer onto the layered
// window, each as a prcDirty sub-update, instead of re-uploading the whole
// (mostly transparent) surface every paint. Falls back to a plain blit onto
// [window_hdc] if UpdateLayeredWindowIndirect refuses.
//
// Extracted so the chrome paint and the banner-only paint cannot end up with
// two different compositing paths.
void CompositeOverlayBands(HWND hwnd, HDC window_hdc, HDC paint_hdc, int width,
                           int height,
                           const std::vector<RECT> &dirty_rects) {
  HDC screen_dc = GetDC(nullptr);
  SIZE size = {width, height};
  POINT pt_src = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  const std::vector<RECT> bands = MergeDirtyRects(dirty_rects);
  bool composited = true;
  for (RECT band : bands) {
    band.left = std::max<LONG>(0, band.left);
    band.top = std::max<LONG>(0, band.top);
    band.right = std::min<LONG>(width, band.right);
    band.bottom = std::min<LONG>(height, band.bottom);
    if (band.right <= band.left || band.bottom <= band.top) {
      continue;
    }
    UPDATELAYEREDWINDOWINFO info = {};
    info.cbSize = sizeof(info);
    info.hdcDst = screen_dc;
    info.pptDst = nullptr; // don't move the window
    info.psize = &size;
    info.hdcSrc = paint_hdc;
    info.pptSrc = &pt_src;
    info.pblend = &blend;
    info.dwFlags = ULW_ALPHA;
    info.prcDirty = &band;
    if (!UpdateLayeredWindowIndirect(hwnd, &info)) {
      composited = false;
      break;
    }
  }
  if (!composited) {
    BitBlt(window_hdc, 0, 0, width, height, paint_hdc, 0, 0, SRCCOPY);
  }
  ReleaseDC(nullptr, screen_dc);
}

void PaintInfoPanel(HDC hdc, const RECT &rect) {
  const auto rows = InfoRows();
  if (rows.empty()) {
    return;
  }
  const RECT panel = InfoPanelRect(rect);
  // A plain filled surface, no outline — the Android Compose `InfoPanel` and
  // the shared Flutter `_infoPanel` are both a rounded fill with no border, and
  // the accent stroke this used to draw was the only thing of its kind on any
  // of the three. Its corners are rounded for real by
  // [ApplyRoundRectAlphaMask], run after the alpha normalizer.
  FillRoundRect(hdc, panel, kNativeInfoPanelRadius, RGB(10, 11, 16));
  HFONT header_font = UiFont(11, FW_SEMIBOLD);
  DrawTextWithFont(
      hdc, L"STREAM INFO",
      RectFrom(panel.left + 14, panel.top + 10, panel.right - 14,
               panel.top + 28),
      DT_LEFT | DT_VCENTER | DT_SINGLELINE, header_font, RGB(154, 161, 178));
  DeleteObject(header_font);
  HFONT label_font = UiFont(12, FW_SEMIBOLD);
  HFONT value_font = UiFont(12, FW_BOLD);
  int y = panel.top + 34;
  for (const auto &row : rows) {
    const bool hdr = row.first == L"Dynamic range" &&
                     (row.second.find(L"HDR") != std::wstring::npos ||
                      row.second.find(L"HLG") != std::wstring::npos ||
                      row.second.find(L"PQ") != std::wstring::npos ||
                      row.second.find(L"Dolby") != std::wstring::npos);
    DrawTextWithFont(hdc, row.first,
                     RectFrom(panel.left + 14, y, panel.left + 110, y + 20),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE, label_font,
                     RGB(154, 161, 178));
    DrawTextWithFont(hdc, row.second,
                     RectFrom(panel.left + 110, y, panel.right - 14, y + 20),
                     DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                     value_font,
                     hdr ? RGB(154, 141, 255) : RGB(238, 240, 247));
    y += 22;
  }
  DeleteObject(label_font);
  DeleteObject(value_font);
}

void PaintListMenu(HDC hdc, const RECT &rect) {
  const NativeMenuKind kind = g_native_control_state.open_menu;
  if (kind == NativeMenuKind::kNone) {
    return;
  }
  const auto &options = MenuOptions(kind);
  const std::string &selected_id = MenuSelectedId(kind);
  const RECT menu = CurrentMenuRect(rect);
  const RECT menu_local = OffsetRectToLocal(menu, menu.left, menu.top);
  FillRoundRect(hdc, menu, kNativeMenuRadius, RGB(8, 9, 14));
  HFONT label_font = UiFont(13, FW_SEMIBOLD);
  DrawTextWithFont(
      hdc, MenuHeader(kind),
      RectFrom(menu.left + 16, menu.top + 4, menu.right - 16, menu.top + 32),
      DT_LEFT | DT_VCENTER | DT_SINGLELINE, label_font, RGB(154, 161, 178));
  const auto option_rects = MenuOptionRects(menu_local);
  if (options.empty()) {
    DrawTextWithFont(
        hdc, L"Nothing available",
        option_rects.empty() ? RectFrom(menu.left + 16, menu.top + 36,
                                        menu.right - 16, menu.bottom - 10)
                             : RectFrom(menu.left + option_rects[0].left,
                                        menu.top + option_rects[0].top,
                                        menu.left + option_rects[0].right,
                                        menu.top + option_rects[0].bottom),
        DT_LEFT | DT_VCENTER | DT_SINGLELINE, label_font, RGB(184, 190, 204));
  } else {
    for (size_t i = 0; i < option_rects.size(); i++) {
      const int option_index =
          g_native_menu_scroll_offset + static_cast<int>(i);
      if (option_index >= static_cast<int>(options.size())) {
        break;
      }
      const auto &option = options[option_index];
      const bool active = option.id == selected_id;
      const RECT option_rect = RectFrom(menu.left + option_rects[i].left,
                                        menu.top + option_rects[i].top,
                                        menu.left + option_rects[i].right,
                                        menu.top + option_rects[i].bottom);
      FillRoundRect(hdc, option_rect, 12,
                    active ? RGB(123, 108, 246) : RGB(26, 29, 40));
      DrawTextWithFont(hdc, option.label,
                       RectFrom(option_rect.left + 12, option_rect.top,
                                option_rect.right - 12, option_rect.bottom),
                       DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                       label_font,
                       active ? RGB(255, 255, 255) : RGB(218, 222, 233));
    }
    if (MenuMaxScrollOffset() > 0) {
      const int track_top = menu.top + kNativeMenuHeaderHeight;
      const int track_bottom = menu.bottom - kNativeMenuPadding;
      FillRoundRect(
          hdc, RectFrom(menu.right - 6, track_top, menu.right - 3, track_bottom),
          4, RGB(39, 43, 58));
      const double visible_ratio = static_cast<double>(MenuVisibleRowCount()) /
                                   static_cast<double>(options.size());
      const int thumb_height = MaxInt(
          24, static_cast<int>((track_bottom - track_top) * visible_ratio));
      const double scroll_ratio =
          static_cast<double>(g_native_menu_scroll_offset) /
          static_cast<double>(MenuMaxScrollOffset());
      const int thumb_top =
          track_top + static_cast<int>(
                          (track_bottom - track_top - thumb_height) *
                          scroll_ratio);
      FillRoundRect(hdc,
                    RectFrom(menu.right - 7, thumb_top, menu.right - 2,
                             thumb_top + thumb_height),
                    5, RGB(123, 108, 246));
    }
  }
  DeleteObject(label_font);
}

// How many quick-list rows the panel can draw in [client], before the window
// it was sent is taken into account.
int QuickListVisibleRows(const RECT &client) {
  const int content = RectHeight(client) - kNativeQuickListMarginTop -
                      kNativeQuickListMarginBottom - kNativeMenuHeaderHeight -
                      kNativeMenuPadding;
  return iptvs::QuickListVisibleRowCount(content, kNativeQuickListRowHeight,
                                         kNativeQuickListMaxRows);
}

// The rows actually drawn, as [start, start + count) into the pushed window.
//
// Two levels of windowing, both deliberate: Dart cuts ~40 rows out of a range
// that is routinely the whole catalog, and this cuts what fits on screen out
// of those. `QuickListVisibleStart` is the same centre-and-clamp arithmetic
// Dart's `zapWindowStart` uses, so the cursor is always inside the slice — a
// slice that missed it would draw a list with no visible selection, which on
// a remote is indistinguishable from a frozen screen.
void QuickListSlice(const RECT &client, int *start, int *count) {
  const int rows = static_cast<int>(g_native_quick_list.rows.size());
  const int visible = std::min(QuickListVisibleRows(client), rows);
  const int selected = MaxInt(0, g_native_quick_list.SelectedInWindow());
  *count = visible;
  *start = iptvs::QuickListVisibleStart(rows, selected, visible);
}

// Where the panel sits. Empty when the window is too small to hold it — every
// caller checks, and nothing may paint or clip to an empty rect (the alpha
// normalizer does not bounds-check, so what this returns must always be
// inside the client area).
RECT QuickListRect(const RECT &client) {
  const int width =
      std::min(kNativeQuickListWidth,
               RectWidth(client) - kNativeQuickListMarginX * 2);
  if (width < kNativeQuickListMinWidth) {
    return RectFrom(0, 0, 0, 0);
  }
  int rows = QuickListVisibleRows(client);
  const int pushed = static_cast<int>(g_native_quick_list.rows.size());
  if (pushed > 0) {
    rows = std::min(rows, pushed);
  } else {
    // Loading, or an empty list: one row's worth of space for the label that
    // stands in for the rows.
    rows = 1;
  }
  const int height = kNativeMenuHeaderHeight +
                     rows * kNativeQuickListRowHeight + kNativeMenuPadding;
  const int top = kNativeQuickListMarginTop;
  if (top + height > static_cast<int>(client.bottom)) {
    return RectFrom(0, 0, 0, 0);
  }
  return RectFrom(kNativeQuickListMarginX, top,
                  kNativeQuickListMarginX + width, top + height);
}

// One quick-list row. [row_rect] is the full-width slot; the row draws its own
// highlight inside it.
//
// Everything here is plain GDI (`FillRoundRect`, `DrawText`) rather than the
// antialiased compositor, because this is a floating panel: its background
// was written by GDI with the alpha byte still at 0, and blending against
// that reads the destination as transparent (see FillRoundRectMaybeAA). The
// panel's alpha is fixed up once, at the end of PaintQuickList.
void DrawQuickListRow(HDC hdc, const RECT &row_rect,
                      const iptvs::QuickListRow &row) {
  const bool selected = row.selected;
  if (selected) {
    // The same accent fill the list menu gives its active row — this panel is
    // a mode of that one, and a second selection idiom on the same surface is
    // how two lists start looking like two different apps.
    FillRoundRect(hdc, row_rect, 12, kNativeAccentColor);
  }
  const int row_top = static_cast<int>(row_rect.top);
  const int row_bottom = static_cast<int>(row_rect.bottom);
  const int center_y = (row_top + row_bottom) / 2;
  int left = static_cast<int>(row_rect.left) + 12;
  int right = static_cast<int>(row_rect.right) - 12;

  if (row.playing) {
    // The channel actually playing, which is not necessarily the selected one
    // — the whole reason the cursor and the playing channel are two different
    // things in `LiveZapController`.
    const RECT marker = RectFrom(left, center_y - 9, left + 16, center_y + 9);
    HFONT icon_font = UiFont(13, FW_NORMAL, L"Segoe MDL2 Assets");
    DrawTextWithFont(hdc, L"\xE768", marker,
                     DT_CENTER | DT_VCENTER | DT_SINGLELINE, icon_font,
                     selected ? RGB(255, 255, 255) : kNativeAccentColor);
    DeleteObject(icon_font);
    left += 20;
  }

  if (!row.badge.empty()) {
    // Final copy from Dart (`ON NOW`, `CATCH-UP`) — never re-derived here, and
    // never re-worded. Neutral colours, matching the shared Flutter overlay's
    // `_badge`, so the two surfaces read alike.
    right -= DrawBadge(hdc, right, center_y, row.badge, RGB(26, 29, 40),
                       RGB(206, 210, 224), /*aa=*/false);
  }
  // **`archive` needs no mark of its own**: `LiveZapController` sets the
  // badge to `CATCH-UP` for exactly the rows it sets `archive` on, so a
  // second affordance beside that chip would say the same thing twice — and
  // this renderer's job is to print Dart's copy, not to add to it.
  if (right <= left) {
    return;
  }

  // A past programme is dimmed, not hidden: it is still playable (catch-up),
  // and the schedule reads as a day rather than as a list that starts at
  // "now". `past` is a flag on the wire precisely so this side never has to
  // compare a timestamp to decide it.
  const COLORREF label_color =
      selected ? RGB(255, 255, 255)
               : (row.past ? kNativeTextLoColor : kNativeTextHiColor);
  const COLORREF secondary_color =
      selected ? RGB(226, 224, 255)
               : (row.past ? RGB(120, 126, 142) : kNativeTextLoColor);

  if (row.secondary.empty()) {
    HFONT font = UiFont(14, FW_SEMIBOLD);
    DrawTextWithFont(hdc, row.label, RectFrom(left, row_top, right, row_bottom),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                     font, label_color);
    DeleteObject(font);
    return;
  }
  HFONT font = UiFont(14, FW_SEMIBOLD);
  DrawTextWithFont(hdc, row.label,
                   RectFrom(left, center_y - 17, right, center_y + 1),
                   DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                   font, label_color);
  DeleteObject(font);
  HFONT secondary_font = UiFont(12, FW_NORMAL);
  DrawTextWithFont(hdc, row.secondary,
                   RectFrom(left, center_y + 1, right, center_y + 17),
                   DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                   secondary_font, secondary_color);
  DeleteObject(secondary_font);
}

// The quick list itself: a heading, a position readout, and the visible slice
// of the pushed window. A **readout and a selection model**, never a pointer
// target (docs/tv-navigation.md) — the keys belong to this surface's own key
// ring, and the overlay window carries WS_EX_TRANSPARENT while the chrome is
// down exactly as it does for the banner.
//
// Floating panel, so the same FillRoundRect + normalize + mask path the info
// panel, the list menu and the banner use.
void PaintQuickList(HDC hdc, uint32_t *pixels, int width, int height,
                    const RECT &panel) {
  if (RectWidth(panel) <= 0 || RectHeight(panel) <= 0) {
    return;
  }
  const iptvs::QuickListState &list = g_native_quick_list;
  FillRoundRect(hdc, panel, kNativeMenuRadius, RGB(8, 9, 14));
  const int panel_left = static_cast<int>(panel.left);
  const int panel_top = static_cast<int>(panel.top);
  const int panel_right = static_cast<int>(panel.right);
  const int panel_bottom = static_cast<int>(panel.bottom);

  HFONT header_font = UiFont(13, FW_SEMIBOLD);
  int position_w = 0;
  if (list.total > 0) {
    // `selectedIndex` is absolute, so this is the cursor's place in the whole
    // list, not in the window — the readout the Flutter panel draws too.
    const std::wstring position = std::to_wstring(list.selected_index + 1) +
                                  L"/" + std::to_wstring(list.total);
    position_w = MeasureTextWidth(hdc, position, header_font) + 10;
    DrawTextWithFont(hdc, position,
                     RectFrom(panel_right - 16 - position_w, panel_top + 4,
                              panel_right - 16, panel_top + 32),
                     DT_RIGHT | DT_VCENTER | DT_SINGLELINE, header_font,
                     kNativeTextLoColor);
  }
  // The heading names the rung above the one on screen (the source, the
  // category, the channel). No mode glyph beside it: the list menu's own
  // header on this surface is text, and a third icon font in a panel that has
  // to stay legible over video buys nothing the words don't already say.
  DrawTextWithFont(
      hdc, list.heading,
      RectFrom(panel_left + 16, panel_top + 4,
               MaxInt(panel_left + 56, panel_right - 16 - position_w),
               panel_top + 32),
      DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS, header_font,
      kNativeTextHiColor);

  const int rows_left = panel_left + 10;
  const int rows_right = panel_right - 10;
  int y = panel_top + kNativeMenuHeaderHeight;

  if (list.rows.empty()) {
    // Loading and empty are different answers, and Dart sends the copy for
    // the second one ("No guide for today", "No channels here") — a renderer
    // that invented its own would be the fifth wording of the same thing.
    const std::wstring label =
        list.loading ? std::wstring(L"Loading\x2026")
                     : (list.empty_label.empty() ? std::wstring(L"Nothing here")
                                                 : list.empty_label);
    DrawTextWithFont(hdc, label,
                     RectFrom(rows_left + 6, y, rows_right - 6,
                              y + kNativeQuickListRowHeight),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                     header_font, RGB(184, 190, 204));
    DeleteObject(header_font);
  } else {
    DeleteObject(header_font);
    RECT client = RectFrom(0, 0, width, height);
    int start = 0;
    int count = 0;
    QuickListSlice(client, &start, &count);
    for (int i = 0; i < count; i++) {
      const int index = start + i;
      if (index >= static_cast<int>(list.rows.size())) {
        break;
      }
      DrawQuickListRow(hdc,
                       RectFrom(rows_left, y, rows_right,
                                y + kNativeQuickListRowHeight - 4),
                       list.rows[index]);
      y += kNativeQuickListRowHeight;
    }
    // The scrollbar is drawn against the **full** list, not the pushed
    // window: `index` is absolute for exactly this reason, so a 250k-row
    // range shows a thumb that means something.
    if (list.total > count && count > 0) {
      const int track_top = panel_top + kNativeMenuHeaderHeight;
      const int track_bottom = panel_bottom - kNativeMenuPadding;
      FillRoundRect(hdc,
                    RectFrom(panel_right - 6, track_top, panel_right - 3,
                             track_bottom),
                    4, RGB(39, 43, 58));
      const double visible_ratio =
          static_cast<double>(count) / static_cast<double>(list.total);
      const int thumb_height = MaxInt(
          24, static_cast<int>((track_bottom - track_top) * visible_ratio));
      const double scroll_ratio =
          list.total > 1
              ? std::clamp(static_cast<double>(list.selected_index) /
                               static_cast<double>(list.total - 1),
                           0.0, 1.0)
              : 0.0;
      const int thumb_top =
          track_top + static_cast<int>(
                          (track_bottom - track_top - thumb_height) *
                          scroll_ratio);
      FillRoundRect(hdc,
                    RectFrom(panel_right - 7, thumb_top, panel_right - 2,
                             thumb_top + thumb_height),
                    5, kNativeAccentColor);
    }
  }

  // Everything above was GDI, which leaves the alpha byte at 0; the two
  // passes below read and write the DIB directly, so the batch has to be
  // flushed first (nothing here calls FillRoundRectAA, which would flush for
  // itself).
  GdiFlush();
  NormalizeNativeControlBitmapAlpha(pixels, width, height, panel,
                                    RGB(8, 9, 14), 0xFF);
  ApplyRoundRectAlphaMask(pixels, width, height, panel, kNativeMenuRadius);
}

void PaintNativeControlBar(HWND hwnd, int control_kind) {
  PAINTSTRUCT paint;
  HDC hdc = BeginPaint(hwnd, &paint);
  RECT rect;
  GetClientRect(hwnd, &rect);
  const int width = RectWidth(rect);
  const int height = RectHeight(rect);
  if (width <= 0 || height <= 0) {
    EndPaint(hwnd, &paint);
    return;
  }

  OverlayBackBuffer &buffer = EnsureOverlayBackBuffer(hdc, width, height);
  HDC paint_hdc = buffer.dc;
  uint32_t *pixels = static_cast<uint32_t *>(buffer.bits);
  // Lets the shape helpers rasterize with coverage instead of calling GDI's
  // aliased `RoundRect`. Scoped, so an early return below cannot leave a
  // dangling buffer pointer behind for the next paint.
  const ScopedOverlayPaintTarget paint_target(pixels, width, height);

  // Chrome hidden: the overlay window is up only to carry the zap banner (see
  // FlutterWindow::NativeOverlayTargetVisible), so it draws that and nothing
  // else — no bars, no scrims. Anything the previous paint left behind is
  // still cleared, which is what takes the bars away on the transition.
  if (!g_native_controls_chrome_visible) {
    // The banner and the quick list are mutually exclusive (ZapBannerShown
    // yields to the list), but both are handled here rather than as an
    // either/or: the two rects are different shapes, and the clear-plus-
    // composite below is driven by the union either way.
    const RECT banner =
        ZapBannerShown() ? ZapBannerRect(rect) : RectFrom(0, 0, 0, 0);
    const RECT quick_list =
        QuickListShown() ? QuickListRect(rect) : RectFrom(0, 0, 0, 0);
    std::vector<RECT> current_rects;
    if (RectWidth(banner) > 0 && RectHeight(banner) > 0) {
      current_rects.push_back(banner);
    }
    if (RectWidth(quick_list) > 0 && RectHeight(quick_list) > 0) {
      current_rects.push_back(quick_list);
    }
    std::vector<RECT> dirty_rects = current_rects;
    dirty_rects.insert(dirty_rects.end(), buffer.prev_rects.begin(),
                       buffer.prev_rects.end());
    for (const RECT &r : dirty_rects) {
      ZeroDibRect(pixels, width, height, r);
    }
    SetBkMode(paint_hdc, TRANSPARENT);
    if (RectWidth(banner) > 0 && RectHeight(banner) > 0) {
      PaintZapBanner(paint_hdc, pixels, width, height, banner);
    }
    if (RectWidth(quick_list) > 0 && RectHeight(quick_list) > 0) {
      PaintQuickList(paint_hdc, pixels, width, height, quick_list);
    }
    CompositeOverlayBands(hwnd, hdc, paint_hdc, width, height, dirty_rects);
    buffer.prev_rects = std::move(current_rects);
    EndPaint(hwnd, &paint);
    return;
  }

  const RECT top = TopControlsRect(rect);
  const RECT bottom = BottomControlsRect(rect);
  // The union of the control rects drawn/visible this paint. Everything outside
  // them (the transparent middle) is never touched and stays clipped by the
  // window region, so it needs neither clearing nor compositing.
  std::vector<RECT> current_rects = {top, bottom};
  if (g_native_control_state.open_menu != NativeMenuKind::kNone) {
    current_rects.push_back(CurrentMenuRect(rect));
  }
  if (HasInfoPanel()) {
    current_rects.push_back(InfoPanelRect(rect));
  }
  // The quick list stays up when the chrome is revealed over it (a mouse move
  // does that) — it is Dart's to close, not the auto-hide's.
  const RECT quick_list_rect =
      QuickListShown() ? QuickListRect(rect) : RectFrom(0, 0, 0, 0);
  const bool draws_quick_list =
      RectWidth(quick_list_rect) > 0 && RectHeight(quick_list_rect) > 0;
  if (draws_quick_list) {
    current_rects.push_back(quick_list_rect);
  }
  // Clear the current rects plus anything the previous paint touched, so a
  // closed menu / shrunk bar is erased from the reused buffer rather than left
  // stale. Only these bands are cleared; the middle is skipped.
  std::vector<RECT> dirty_rects = current_rects;
  dirty_rects.insert(dirty_rects.end(), buffer.prev_rects.begin(),
                     buffer.prev_rects.end());
  for (const RECT &r : dirty_rects) {
    ZeroDibRect(pixels, width, height, r);
  }

  // Bar backdrops: a gradient that fades toward the middle of the view rather
  // than a flat fill, matching the shared Flutter overlay's bars (see
  // FillVerticalScrim). Both ramps live entirely inside the existing bar rects,
  // so the window region (UpdateNativeControlsRegion) needs no extra room — the
  // fade reaches ~0 exactly where the region already stops clipping, which is
  // what removes the old hard 20%-to-nothing step at the bar edge.
  static constexpr ScrimStop kTopScrim[] = {{0.0, 0xB3}, {1.0, 0x00}};
  static constexpr ScrimStop kBottomScrim[] = {
      {0.0, 0x00}, {0.45, 0x99}, {1.0, 0xCC}};
  FillVerticalScrim(pixels, width, height, top, kTopScrim,
                    std::size(kTopScrim));
  FillVerticalScrim(pixels, width, height, bottom, kBottomScrim,
                    std::size(kBottomScrim));

  SetBkMode(paint_hdc, TRANSPARENT);

  const BottomLayout l = ComputeBottomLayout(rect);
  const auto focusables = FocusableItems(l);
  if (!focusables.empty()) {
    g_native_focus_index =
        std::clamp(g_native_focus_index, 0,
                   static_cast<int>(focusables.size()) - 1);
  } else {
    g_native_focus_index = 0;
  }
  const auto is_focused = [&](NativeFocusItem item) {
    return g_native_keyboard_focus_visible && !focusables.empty() &&
           focusables[g_native_focus_index] == item;
  };

  const int top_cy = (top.top + top.bottom) / 2;
  DrawIconButton(paint_hdc, RectFrom(16, top_cy - 19, 54, top_cy + 19),
                 L"\xE72B", is_focused(NativeFocusItem::kBack));

  // Top-right badges, stacked leftward: clock, fps, dynamic range, resolution,
  // LIVE, then source name — i.e. left-to-right they read source, LIVE,
  // resolution, HDR, fps, clock, the order Kotlin `TopBadges`, iOS
  // `badgesStack` and Dart `_badges()` all use. This cluster used to sit at
  // fps/resolution/LIVE in a different order, which made the Windows SDR
  // (embedded Flutter) overlay and this one disagree on a channel's chrome
  // depending only on whether the stream was HDR.
  const COLORREF kNeutralBg = RGB(30, 33, 45);
  const COLORREF kNeutralFg = RGB(206, 210, 224);
  int badge_right = rect.right - 16;
  if (g_native_control_state.reconnecting) {
    badge_right -= DrawBadge(paint_hdc, badge_right, top_cy, L"\x21BB Reconnecting\x2026",
                             RGB(150, 102, 24), RGB(255, 236, 196));
  }
  const std::wstring clock = FormatClock();
  if (!clock.empty()) {
    badge_right -=
        DrawBadge(paint_hdc, badge_right, top_cy, clock, kNeutralBg, kNeutralFg);
  }
  const std::wstring fps_badge = FpsBadge(g_native_control_state.fps);
  if (!fps_badge.empty()) {
    badge_right -= DrawBadge(paint_hdc, badge_right, top_cy, fps_badge,
                             kNeutralBg, kNeutralFg);
  }
  const std::wstring hdr_badge = HdrBadge();
  if (!hdr_badge.empty()) {
    badge_right -= DrawBadge(paint_hdc, badge_right, top_cy, hdr_badge,
                             RGB(60, 52, 137), RGB(206, 203, 246));
  }
  const std::wstring res_badge = ResolutionBadge();
  if (!res_badge.empty()) {
    badge_right -= DrawBadge(paint_hdc, badge_right, top_cy, res_badge,
                             RGB(60, 52, 137), RGB(206, 203, 246));
  }
  if (g_native_control_state.is_live) {
    // Red at the live edge; grey once behind (paired with the go-to-live button).
    const bool synced = g_native_control_state.live_synced;
    badge_right -= DrawBadge(
        paint_hdc, badge_right, top_cy, L"\x25CF LIVE",
        synced ? RGB(255, 64, 112) : RGB(74, 80, 94),
        synced ? RGB(255, 255, 255) : RGB(200, 205, 216));
  }
  if (!g_native_control_state.source_name.empty()) {
    badge_right -=
        DrawBadge(paint_hdc, badge_right, top_cy,
                  // 20, the same ceiling Kotlin `sourceBadge`, Swift
                  // `BadgeFormatting.sourceBadge` and Dart `sourceBadgeLabel`
                  // apply.
                  TruncateBadge(g_native_control_state.source_name, 20),
                  kNeutralBg, kNeutralFg);
  }

  HFONT title_font = UiFont(22, FW_BOLD);
  DrawTextWithFont(paint_hdc, g_native_control_state.title,
                   RectFrom(66, top.top, MaxInt(80, badge_right - 12),
                            top.bottom),
                   DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                   title_font, RGB(246, 247, 251));
  DeleteObject(title_font);

  DrawIconButton(
      paint_hdc, l.play,
      g_native_control_state.playing ? L"\xE769" : L"\xE768",
      is_focused(NativeFocusItem::kPlay));
  if (l.has_seek) {
    DrawTextButton(paint_hdc, l.seek_back, L"-10",
                   is_focused(NativeFocusItem::kSeekBack));
    DrawTextButton(paint_hdc, l.seek_forward, L"+10",
                   is_focused(NativeFocusItem::kSeekForward));
  }
  DrawIconButton(paint_hdc, l.mute,
                 g_native_control_state.volume <= 0 ? L"\xE74F" : L"\xE767",
                 is_focused(NativeFocusItem::kMute));
  DrawSlider(paint_hdc, l.volume,
             std::clamp(g_native_control_state.volume / 100.0, 0.0, 1.0), 5);

  if (l.has_scrubber) {
    HFONT time_font = UiFont(13, FW_SEMIBOLD);
    DrawTextWithFont(paint_hdc, FormatTime(g_native_control_state.position_ms),
                     l.position_text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE, time_font,
                     RGB(184, 190, 204));
    const double duration = std::max(1.0, g_native_control_state.duration_ms);
    // While the scrubber is being dragged the thumb follows the pointer; the
    // seek itself is committed on release.
    DrawSlider(paint_hdc, l.progress,
               g_native_seek_preview >= 0.0
                   ? g_native_seek_preview
                   : g_native_control_state.position_ms / duration,
               6);
    DrawTextWithFont(paint_hdc, FormatTime(g_native_control_state.duration_ms),
                     l.duration_text,
                     DT_RIGHT | DT_VCENTER | DT_SINGLELINE, time_font,
                     RGB(184, 190, 204));
    DeleteObject(time_font);
  }

  // The identity run and the strip are the same two pieces the zap banner
  // draws, through the same two functions — see DrawChannelIdentityRow and
  // DrawLiveEpgStrip.
  if (l.has_identity) {
    DrawChannelIdentityRow(paint_hdc, l.identity);
  }
  if (l.has_epg) {
    const auto &s = g_native_control_state;
    DrawLiveEpgStrip(paint_hdc, static_cast<int>(l.epg.left),
                     static_cast<int>(l.epg.right),
                     static_cast<int>(l.epg.top), s.epg_now_title,
                     s.epg_now_start_ms, s.epg_now_stop_ms, s.epg_next_title,
                     s.epg_next_start_ms, s.epg_next_stop_ms, /*aa=*/true);
  }

  if (l.has_speed) {
    DrawTextButton(paint_hdc, l.speed,
                   ShortSpeed(g_native_control_state.selected_speed_id),
                   is_focused(NativeFocusItem::kSpeed));
  }
  if (l.has_audio) {
    DrawIconButton(paint_hdc, l.audio, L"\xE8D6",
                   is_focused(NativeFocusItem::kAudio) ||
                       g_native_control_state.open_menu == NativeMenuKind::kAudio);
  }
  if (l.has_subtitles) {
    DrawIconButton(
        paint_hdc, l.subtitles, L"\xE190",
        is_focused(NativeFocusItem::kSubtitles) ||
            g_native_control_state.open_menu == NativeMenuKind::kSubtitles);
  }
  DrawTextButton(paint_hdc, l.aspect,
                 g_native_control_state.aspect_label.empty()
                     ? L"Fit"
                     : g_native_control_state.aspect_label,
                 is_focused(NativeFocusItem::kAspect));
  DrawIconButton(paint_hdc, l.info, L"\xE946",
                 is_focused(NativeFocusItem::kInfo) ||
                     g_native_control_state.info_open);
  DrawIconButton(paint_hdc, l.fullscreen,
                 g_native_control_state.fullscreen ? L"\xE73F" : L"\xE740",
                 is_focused(NativeFocusItem::kFullscreen));
  if (l.has_favorite) {
    // Dart owns the store: a click sends "favorite" back and Dart pushes the
    // new state via setControlState. The accent tints the **glyph**, not the
    // button — the filled background means keyboard focus, which is what
    // `active` is for, and the Flutter overlay draws the same split.
    const bool favorited = g_native_control_state.is_favorite;
    DrawIconButton(paint_hdc, l.favorite, favorited ? L"\xE735" : L"\xE734",
                   is_focused(NativeFocusItem::kFavorite),
                   favorited ? std::optional<COLORREF>(RGB(123, 108, 246))
                             : std::nullopt);
  }
  if (l.has_go_live) {
    // The label is the action, not the state: this button used to read "LIVE",
    // duplicating the LIVE *status* badge in the top bar (which greys at the
    // very moment this appears) with a word that says nothing about what
    // clicking it does. Same wording now on Android, iOS, Linux and the shared
    // Flutter overlay.
    DrawTextButton(paint_hdc, l.go_live, L"Go to live",
                   is_focused(NativeFocusItem::kGoLive));
  }

  PaintListMenu(paint_hdc, rect);
  RECT info_panel_rect = {0};
  if (HasInfoPanel()) {
    PaintInfoPanel(paint_hdc, rect);
    info_panel_rect = InfoPanelRect(rect);
  }

  const RECT top_bar = TopControlsRect(rect);
  const RECT bottom_bar = BottomControlsRect(rect);
  // Force everything GDI drew into the bars fully opaque (GDI leaves the alpha
  // byte at 0), while leaving the gradient backdrop FillVerticalScrim laid down
  // untouched — that is exactly what the `alpha == 0` test distinguishes, and
  // why the scrim's alpha never reaches 0. The RGB(3,4,7)/0x33 pair is a legacy
  // sentinel for a flat backdrop colour nothing paints any more; it is kept
  // only because a drawn pixel that happened to land on it should stay a
  // backdrop pixel rather than turn opaque.
  NormalizeNativeControlBitmapAlpha(pixels, width, height, top_bar,
                                     RGB(3, 4, 7), 0x33);
  NormalizeNativeControlBitmapAlpha(pixels, width, height, bottom_bar,
                                     RGB(3, 4, 7), 0x33);
  // If a menu is open (audio/subtitles/speed), make its background
  // semi-opaque (~40%) so the menu is easier to read.
  RECT menu_rect = CurrentMenuRect(rect);
  if (menu_rect.right > menu_rect.left && menu_rect.bottom > menu_rect.top) {
    const BYTE menu_alpha =
        g_native_control_state.open_menu == NativeMenuKind::kSubtitles
            ? 0x66
            : 0xFF;
    NormalizeNativeControlBitmapAlpha(pixels, width, height, menu_rect,
                                       RGB(8, 9, 14), menu_alpha);
    ApplyRoundRectAlphaMask(pixels, width, height, menu_rect,
                            kNativeMenuRadius);
  }
  if (info_panel_rect.right > info_panel_rect.left &&
      info_panel_rect.bottom > info_panel_rect.top) {
    NormalizeNativeControlBitmapAlpha(pixels, width, height, info_panel_rect,
                                       RGB(10, 11, 16), 0xFF);
    ApplyRoundRectAlphaMask(pixels, width, height, info_panel_rect,
                            kNativeInfoPanelRadius);
  }
  // Painted *after* the bars' and panels' alpha passes, because it runs its
  // own normalize + corner mask over its rect (PaintQuickList) and a pixel
  // normalized twice comes back double-darkened. Its band is banded clear of
  // both bars by construction (kNativeQuickListMarginTop/Bottom), so the two
  // passes can never meet.
  if (draws_quick_list) {
    PaintQuickList(paint_hdc, pixels, width, height, quick_list_rect);
  }

  // Composite only the dirty bands (current + previously-touched control rects,
  // merged), each as a prcDirty sub-update of the layered surface, instead of
  // re-uploading the whole (mostly transparent) window every paint.
  CompositeOverlayBands(hwnd, hdc, paint_hdc, width, height, dirty_rects);

  // Keep the cached DIB/DC; remember this paint's rects for the next clear.
  buffer.prev_rects = std::move(current_rects);
  EndPaint(hwnd, &paint);
}

std::string NativeControlCommandFromPoint(HWND hwnd, int control_kind, int x,
                                          int y) {
  RECT rect;
  GetClientRect(hwnd, &rect);
  const RECT top = TopControlsRect(rect);
  if (PointInRect(x, y, top)) {
    if (PointInRect(x, y, RectFrom(12, 8, 60, 56))) {
      return "back";
    }
    // Favorite star, drawn rightmost in the top bar (see PaintNativeControlBar).
    return "show";
  }

  if (g_native_control_state.open_menu != NativeMenuKind::kNone) {
    const RECT menu = CurrentMenuRect(rect);
    if (PointInRect(x, y, menu)) {
      const auto &options = MenuOptions(g_native_control_state.open_menu);
      const RECT menu_local = OffsetRectToLocal(menu, menu.left, menu.top);
      const auto option_rects = MenuOptionRects(menu_local);
      for (size_t i = 0; i < option_rects.size(); i++) {
        const RECT option_rect = RectFrom(menu.left + option_rects[i].left,
                                          menu.top + option_rects[i].top,
                                          menu.left + option_rects[i].right,
                                          menu.top + option_rects[i].bottom);
        if (PointInRect(x, y, option_rect)) {
          const int option_index =
              g_native_menu_scroll_offset + static_cast<int>(i);
          if (option_index >= 0 &&
              option_index < static_cast<int>(options.size())) {
            return MenuSelectCommandPrefix(g_native_control_state.open_menu) +
                   options[option_index].id;
          }
        }
      }
      return "show";
    }
  }

  // Clicking inside the info panel keeps it (and the controls) up.
  if (HasInfoPanel() && PointInRect(x, y, InfoPanelRect(rect))) {
    return "show";
  }

  const BottomLayout l = ComputeBottomLayout(rect);
  if (!PointInRect(x, y, l.bottom)) {
    return "show";
  }
  if (PointInRect(x, y, l.play)) {
    return "playPause";
  }
  if (l.has_seek) {
    if (PointInRect(x, y, l.seek_back)) {
      return "seekBack";
    }
    if (PointInRect(x, y, l.seek_forward)) {
      return "seekForward";
    }
  }
  if (l.has_scrubber &&
      PointInRect(x, y,
                  RectFrom(l.progress.left, l.progress.top - 14,
                           l.progress.right, l.progress.bottom + 14))) {
    return "seekPercent:" + std::to_string(RatioFromX(x, l.progress));
  }
  if (PointInRect(x, y, l.mute)) {
    return "muteToggle";
  }
  if (PointInRect(x, y,
                  RectFrom(l.volume.left, l.volume.top - 14, l.volume.right,
                           l.volume.bottom + 14))) {
    return "volumePercent:" + std::to_string(RatioFromX(x, l.volume));
  }
  if (l.has_speed && PointInRect(x, y, l.speed)) {
    return "menu:speed";
  }
  if (l.has_audio && PointInRect(x, y, l.audio)) {
    return "menu:audio";
  }
  if (l.has_subtitles && PointInRect(x, y, l.subtitles)) {
    return "menu:subtitles";
  }
  if (PointInRect(x, y, l.aspect)) {
    return "aspect";
  }
  if (PointInRect(x, y, l.info)) {
    return "info";
  }
  if (PointInRect(x, y, l.fullscreen)) {
    return "fullscreen";
  }
  if (l.has_go_live && PointInRect(x, y, l.go_live)) {
    return "goLive";
  }
  if (l.has_favorite && PointInRect(x, y, l.favorite)) {
    return "favorite";
  }
  return "show";
}

// Where along its track the pointer is, for the slider currently being dragged.
//
// Deliberately recomputed from the *track* rather than hit-tested from the
// point: a drag is expected to keep working when the pointer wanders off the
// 6px-tall groove, or past either end of it. [RatioFromX] clamps, so dragging
// beyond the track pins to 0 or 1.
double SliderRatioFromX(HWND hwnd, NativeSliderDrag drag, int x) {
  RECT rect;
  GetClientRect(hwnd, &rect);
  const BottomLayout l = ComputeBottomLayout(rect);
  return RatioFromX(x, drag == NativeSliderDrag::kVolume ? l.volume
                                                         : l.progress);
}

// Finishes a slider drag, optionally committing the value under [x].
//
// The state is cleared *before* `ReleaseCapture`, because that call sends
// `WM_CAPTURECHANGED` straight back into this window — and that handler's job
// is to abandon a drag it finds still live, which would otherwise wipe the very
// values this function is about to use.
void EndNativeSliderDrag(HWND hwnd, bool commit, int x) {
  const NativeSliderDrag drag = g_native_slider_drag;
  if (drag == NativeSliderDrag::kNone) {
    return;
  }
  g_native_slider_drag = NativeSliderDrag::kNone;
  g_native_slider_last_sent = -1.0;
  const bool had_preview = g_native_seek_preview >= 0.0;
  g_native_seek_preview = -1.0;
  if (GetCapture() == hwnd) {
    ReleaseCapture();
  }
  if (had_preview) {
    InvalidateRect(hwnd, nullptr, FALSE);
  }
  if (!commit) {
    return;
  }
  HWND parent = NativeControlsOwner(hwnd);
  if (parent == nullptr) {
    return;
  }
  const std::string command =
      (drag == NativeSliderDrag::kSeek ? std::string("seekPercent:")
                                       : std::string("volumePercent:")) +
      std::to_string(SliderRatioFromX(hwnd, drag, x));
  PostMessage(parent, kNativeControlCommandMessage,
              reinterpret_cast<WPARAM>(new std::string(command)), 0);
}

bool IsKeyRepeat(LPARAM lparam) { return ((lparam >> 30) & 1) != 0; }

// Whether this press belongs to zapping, and so must **not** be treated as the
// "user activity" that reveals the chrome.
//
// Load-bearing, not an optimisation: both child window procedures *post*
// kNativeVideoSurfaceInputMessage ahead of the key itself, and that message
// calls ShowNativeControls(true). Posted messages are processed in order, so
// without this check the chrome would already be up by the time
// MessageHandler decided the key was an arrow — and the arrows only zap while
// it is hidden, which means zapping could never start from a remote at all.
// The key-up is suppressed on the same terms, or the release would reveal what
// the press deliberately did not.
bool IsZapKeyPress(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != WM_KEYDOWN && message != WM_KEYUP) {
    return false;
  }
  const bool is_repeat = message == WM_KEYDOWN && IsKeyRepeat(lparam);
  return iptvs::DecideZapKey(static_cast<int>(wparam), ZapActive(),
                             g_native_controls_chrome_visible,
                             ZapDigitsPending(), is_repeat, QuickListShown())
      .consumed();
}

LRESULT CALLBACK NativeControlsWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) noexcept {
  switch (message) {
  case WM_ERASEBKGND:
    return 1;
  case WM_PAINT: {
    const int control_kind =
        static_cast<int>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    PaintNativeControlBar(hwnd, control_kind);
    return 0;
  }
  case WM_SETCURSOR:
    if (!g_native_video_cursor_visible) {
      SetCursor(nullptr);
      return TRUE;
    }
    break;
  case WM_MOUSEACTIVATE:
    return MA_NOACTIVATE;
  case WM_KEYDOWN:
  case WM_KEYUP:
  case WM_SYSKEYDOWN:
  case WM_SYSKEYUP:
    if (HWND parent = NativeControlsOwner(hwnd)) {
      if (!IsZapKeyPress(message, wparam, lparam)) {
        PostMessage(parent, kNativeVideoSurfaceInputMessage, 0, 0);
      }
      PostMessage(parent, message, wparam, lparam);
      return 0;
    }
    break;
  case WM_MOUSEMOVE: {
    // Mouse interaction takes over from keyboard navigation, so hide the
    // keyboard focus ring until arrows/OK are used again.
    g_native_keyboard_focus_visible = false;
    if (g_native_slider_drag != NativeSliderDrag::kNone) {
      // A capture can outlive the button (an Alt-Tab away and back, a system
      // dialog stealing input); the button state in `wparam` is the reliable
      // signal that the gesture is over.
      if ((wparam & MK_LBUTTON) == 0) {
        EndNativeSliderDrag(hwnd, false, GET_X_LPARAM(lparam));
        return 0;
      }
      const int x = GET_X_LPARAM(lparam);
      const double ratio = SliderRatioFromX(hwnd, g_native_slider_drag, x);
      if (g_native_slider_drag == NativeSliderDrag::kSeek) {
        if (ratio != g_native_seek_preview) {
          g_native_seek_preview = ratio;
          InvalidateRect(hwnd, nullptr, FALSE);
        }
      } else if (ratio != g_native_slider_last_sent) {
        g_native_slider_last_sent = ratio;
        if (HWND parent = NativeControlsOwner(hwnd)) {
          PostMessage(
              parent, kNativeControlCommandMessage,
              reinterpret_cast<WPARAM>(
                  new std::string("volumePercent:" + std::to_string(ratio))),
              0);
        }
      }
      // The bar must not auto-hide out from under the thumb mid-gesture.
      if (HWND parent = NativeControlsOwner(hwnd)) {
        KillTimer(parent, kNativeControlsHideTimer);
        SetTimer(parent, kNativeControlsHideTimer, 3500, nullptr);
      }
      return 0;
    }
    if (!HasPointerMoved(lparam, &g_last_controls_mouse)) {
      return 0;
    }
    if (g_native_control_state.playing) {
      if (HWND parent = NativeControlsOwner(hwnd)) {
        KillTimer(parent, kNativeControlsHideTimer);
        SetTimer(parent, kNativeControlsHideTimer, 3500, nullptr);
      }
    }
    break;
  }
  case WM_LBUTTONUP:
    if (g_native_slider_drag != NativeSliderDrag::kNone) {
      EndNativeSliderDrag(hwnd, true, GET_X_LPARAM(lparam));
      return 0;
    }
    break;
  case WM_CAPTURECHANGED:
    // Something else took the mouse — abandon rather than commit a value the
    // user never released on.
    EndNativeSliderDrag(hwnd, false, 0);
    return 0;
  case WM_LBUTTONDOWN: {
    g_native_keyboard_focus_visible = false;
    const int control_kind =
        static_cast<int>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    const std::string command = NativeControlCommandFromPoint(
        hwnd, control_kind, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
    // Both sliders become drags from here. Capture is what makes the gesture
    // survive the pointer leaving the track — without it the window stops
    // seeing moves, and never sees the button-up either.
    if (command.rfind("volumePercent:", 0) == 0) {
      g_native_slider_drag = NativeSliderDrag::kVolume;
      g_native_slider_last_sent =
          SliderRatioFromX(hwnd, NativeSliderDrag::kVolume,
                           GET_X_LPARAM(lparam));
      SetCapture(hwnd);
      // Falls through: volume applies immediately, on press and on every move.
    } else if (command.rfind("seekPercent:", 0) == 0) {
      g_native_slider_drag = NativeSliderDrag::kSeek;
      g_native_seek_preview = SliderRatioFromX(
          hwnd, NativeSliderDrag::kSeek, GET_X_LPARAM(lparam));
      SetCapture(hwnd);
      InvalidateRect(hwnd, nullptr, FALSE);
      // Committed on release instead — a drag across a full-width scrubber
      // would otherwise ask the player for a seek per pixel. A plain click
      // still seeks: it is a press and a release with nothing in between.
      return 0;
    }
    // Menu open/close and the info panel are owned entirely by the overlay; they
    // don't round-trip to Dart (the option lists arrive via setControlState).
    ApplyOverlayOwnedCommand(hwnd, NativeControlsOwner(hwnd), command);
    if (command.rfind("menu:", 0) == 0 || command == "info") {
      return 0;
    }
    if (command.rfind("audioTrack:", 0) == 0 ||
        command.rfind("subtitleTrack:", 0) == 0 ||
        command.rfind("speed:", 0) == 0) {
      g_native_control_state.open_menu = NativeMenuKind::kNone;
      if (HWND parent = NativeControlsOwner(hwnd)) {
        PostMessage(parent, kNativeControlsLayoutMessage, 0, 0);
      }
    }
    if (HWND parent = NativeControlsOwner(hwnd)) {
      PostMessage(parent, kNativeControlCommandMessage,
                  reinterpret_cast<WPARAM>(new std::string(command)), 0);
    }
    return 0;
  }
  case WM_MOUSEWHEEL: {
    RECT rect;
    GetClientRect(hwnd, &rect);
    POINT point;
    if (!GetCursorPos(&point)) {
      break;
    }
    ScreenToClient(hwnd, &point);
    if (g_native_control_state.open_menu == NativeMenuKind::kNone ||
        !PointInRect(point.x, point.y, CurrentMenuRect(rect)) ||
        MenuMaxScrollOffset() <= 0) {
      break;
    }
    const int delta = GET_WHEEL_DELTA_WPARAM(wparam);
    g_native_menu_scroll_offset += delta > 0 ? -1 : 1;
    ClampMenuScrollOffset();
    SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    InvalidateRect(hwnd, nullptr, FALSE);
    return 0;
  }
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK NativeVideoSurfaceWndProc(HWND hwnd, UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam) noexcept {
  switch (message) {
  case WM_ERASEBKGND:
    return 1;
  case WM_SETCURSOR:
    if (!g_native_video_cursor_visible) {
      SetCursor(nullptr);
      return TRUE;
    }
    break;
  case WM_KEYDOWN:
  case WM_KEYUP:
  case WM_SYSKEYDOWN:
  case WM_SYSKEYUP:
    if (HWND parent = GetParent(hwnd)) {
      if (!IsZapKeyPress(message, wparam, lparam)) {
        PostMessage(parent, kNativeVideoSurfaceInputMessage, 0, 0);
      }
      PostMessage(parent, message, wparam, lparam);
      return 0;
    }
    break;
  case WM_MOUSEMOVE:
    if (!HasPointerMoved(lparam, &g_last_video_mouse)) {
      return 0;
    }
    if (HWND parent = GetParent(hwnd)) {
      PostMessage(parent, kNativeVideoSurfaceInputMessage, 0, 0);
    }
    break;
  case WM_LBUTTONDOWN:
    if (HWND parent = GetParent(hwnd)) {
      PostMessage(parent, kNativeVideoSurfaceInputMessage, 0, 0);
    }
    // Mini-player: dragging anywhere on the video moves the window (the
    // classic manual-caption-drag trick; the frameless window has no title
    // bar to grab). Controls live on a separate layered window and keep
    // their own clicks.
    if (g_native_window_mini) {
      if (HWND root = GetAncestor(hwnd, GA_ROOT)) {
        ReleaseCapture();
        SendMessage(root, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        return 0;
      }
    }
    break;
  case WM_RBUTTONDOWN:
  case WM_MBUTTONDOWN:
  case WM_MOUSEWHEEL:
    if (HWND parent = GetParent(hwnd)) {
      PostMessage(parent, kNativeVideoSurfaceInputMessage, 0, 0);
    }
    break;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

void EnsureNativeVideoSurfaceClass() {
  static bool registered = false;
  if (registered) {
    return;
  }
  WNDCLASS window_class{};
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.lpszClassName = kNativeVideoSurfaceClassName;
  window_class.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
  window_class.cbClsExtra = 0;
  window_class.cbWndExtra = 0;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hIcon = nullptr;
  window_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  window_class.lpszMenuName = nullptr;
  window_class.lpfnWndProc = NativeVideoSurfaceWndProc;
  RegisterClass(&window_class);
  registered = true;
}

void EnsureNativeControlsClass() {
  static bool registered = false;
  if (registered) {
    return;
  }
  WNDCLASS window_class{};
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.lpszClassName = kNativeControlsClassName;
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.hbrBackground = nullptr;
  window_class.lpfnWndProc = NativeControlsWndProc;
  RegisterClass(&window_class);
  registered = true;
}

} // namespace

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  LoadBundledFonts();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterNativeHdrPlayerChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  ResetZapBanner();
  SetNativeWindowFullscreen(false);
  DestroyNativeControls();
  DestroyNativeVideoSurface();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_KEYDOWN && native_video_surface_ != nullptr) {
    // In-player live zapping claims its keys before every other branch on
    // this surface — including the Escape/Back one below, because a
    // half-typed channel number is the first rung of this screen's Back
    // ladder (docs/tv-navigation.md "In-player navigation"). One physical
    // press must not be read once here and again by the overlay's focus ring,
    // which is the same Activity-boundary placement Android gives
    // `ZapKeyPolicy`.
    const iptvs::ZapKeyDecision zap = iptvs::DecideZapKey(
        static_cast<int>(wparam), ZapActive(), native_controls_visible_,
        ZapDigitsPending(), IsKeyRepeat(lparam), QuickListShown());
    if (zap.consumed()) {
      const std::string command = zap.command();
      if (!command.empty()) {
        if (zap.action == iptvs::ZapKeyAction::kDigit) {
          g_native_zap_digits_optimistic = true;
        }
        NotifyNativeControlCommand(command);
      }
      // Deliberately no ShowNativeControls(true): revealing the chrome on the
      // first Up would hand the second Up to the control row instead of the
      // next channel, which is the opposite of what the key was pressed for.
      // The banner is what acknowledges the press.
      return 0;
    }

    if (wparam == VK_ESCAPE) {
      ShowNativeControls(true);
      NotifyNativeControlCommand("back");
      return 0;
    }

    const bool is_activate =
        wparam == VK_RETURN || wparam == VK_SPACE || wparam == VK_SELECT;
    const bool is_nav = wparam == VK_LEFT || wparam == VK_RIGHT ||
                        wparam == VK_UP || wparam == VK_DOWN;
    if (is_activate || is_nav) {
      g_native_keyboard_focus_visible = true;
      const bool was_controls_visible = native_controls_visible_;
      ShowNativeControls(true);
      ScheduleNativeControlsHide();

      // First OK/Enter press only reveals HUD; activation happens on the next
      // press after the user has moved focus.
      if (is_activate && !was_controls_visible) {
        InvalidateNativeControls();
        return 0;
      }

      RECT rect;
      GetClientRect(hwnd, &rect);
      const BottomLayout l = ComputeBottomLayout(rect);
      const auto focusables = FocusableItems(l);
      if (!focusables.empty()) {
        g_native_focus_index = std::clamp(g_native_focus_index, 0,
                                          static_cast<int>(focusables.size()) -
                                              1);
        const auto focus_index_of = [&](NativeFocusItem item) {
          auto it = std::find(focusables.begin(), focusables.end(), item);
          if (it == focusables.end()) return -1;
          return static_cast<int>(it - focusables.begin());
        };

        if (is_nav) {
          if (wparam == VK_UP) {
            const int back_index = focus_index_of(NativeFocusItem::kBack);
            if (back_index >= 0) g_native_focus_index = back_index;
          } else if (wparam == VK_DOWN) {
            if (IsTopBarFocusItem(focusables[g_native_focus_index])) {
              const int play_index = focus_index_of(NativeFocusItem::kPlay);
              if (play_index >= 0) g_native_focus_index = play_index;
            }
          } else {
            // The top bar is Back; everything else is the bottom bar.
            // Left/Right walks the row you are on and steps off its end into
            // the other row — so from Back, Right lands on the first bottom
            // item and Left on the last. The general two-row form is kept
            // rather than special-cased back to a single control, since the
            // top row has held more than one before and may again.
            std::vector<int> top_indices;
            std::vector<int> bottom_indices;
            for (int i = 0; i < static_cast<int>(focusables.size()); ++i) {
              if (IsTopBarFocusItem(focusables[i])) {
                top_indices.push_back(i);
              } else {
                bottom_indices.push_back(i);
              }
            }
            const bool go_left = (wparam == VK_LEFT);
            if (IsTopBarFocusItem(focusables[g_native_focus_index])) {
              int pos = 0;
              for (int i = 0; i < static_cast<int>(top_indices.size()); ++i) {
                if (top_indices[i] == g_native_focus_index) {
                  pos = i;
                  break;
                }
              }
              const int next = pos + (go_left ? -1 : 1);
              if (next < 0) {
                if (!bottom_indices.empty()) {
                  g_native_focus_index = bottom_indices.back();
                }
              } else if (next >= static_cast<int>(top_indices.size())) {
                if (!bottom_indices.empty()) {
                  g_native_focus_index = bottom_indices.front();
                }
              } else {
                g_native_focus_index = top_indices[next];
              }
            } else if (!bottom_indices.empty()) {
              int current_bottom_pos = 0;
              for (int i = 0; i < static_cast<int>(bottom_indices.size()); ++i) {
                if (bottom_indices[i] == g_native_focus_index) {
                  current_bottom_pos = i;
                  break;
                }
              }
              const int dir = go_left ? -1 : 1;
              const int count = static_cast<int>(bottom_indices.size());
              current_bottom_pos = (current_bottom_pos + dir + count) % count;
              g_native_focus_index = bottom_indices[current_bottom_pos];
            }
          }
          InvalidateNativeControls();
          return 0;
        }

        if (!native_controls_visible_) {
          InvalidateNativeControls();
          return 0;
        }

        const std::string command =
            CommandForFocusedItem(focusables[g_native_focus_index]);
        // "Go to live" removes itself once the reload reaches the live edge, and
        // the ring is rebuilt from scratch on the next paint — so the index left
        // behind silently points at whatever control slid into that slot (or is
        // clamped to the end). Park focus on play/pause instead, the same
        // landing spot Compose uses for the same disappearing control. Done
        // before the command is sent, so the rebuild can only find it here.
        if (command == "goLive") {
          const auto play = std::find(focusables.begin(), focusables.end(),
                                      NativeFocusItem::kPlay);
          if (play != focusables.end()) {
            g_native_focus_index =
                static_cast<int>(std::distance(focusables.begin(), play));
          }
        }
        ApplyOverlayOwnedCommand(native_controls_overlay_, hwnd, command);
        if (command.rfind("menu:", 0) == 0 || command == "info") {
          InvalidateNativeControls();
          return 0;
        }
        const bool pauses_playback =
            command == "playPause" && g_native_control_state.playing;
        const bool fullscreen_toggle = command == "fullscreen";
        if (fullscreen_toggle) {
          native_controls_pinned_ = true;
        }
        NotifyNativeControlCommand(command);
        if (pauses_playback || fullscreen_toggle) {
          KillTimer(hwnd, kNativeControlsHideTimer);
        }
        InvalidateNativeControls();
        return 0;
      }
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
  case WM_FONTCHANGE:
    flutter_controller_->engine()->ReloadSystemFonts();
    break;
  case WM_MOVE:
    ResizeNativeControls();
    break;
  case WM_SIZE: {
    const LRESULT result =
        Win32Window::MessageHandler(hwnd, message, wparam, lparam);
    ResizeNativeVideoSurface();
    ResizeNativeControls();
    BringNativeControlsToFront();
    return result;
  }
  case WM_TIMER:
    if (wparam == kNativeVideoResyncTimer) {
      // force_event: these passes follow a discrete transition, so they also
      // retry a swapchain resize that mpv abandoned mid-frame. Cheap here (a
      // few per fullscreen toggle) and never reached while dragging a window.
      ResyncNativeVideoRenderer(true);
      if (--native_video_resync_passes_ <= 0) {
        KillTimer(hwnd, kNativeVideoResyncTimer);
      }
      return 0;
    }
    if (wparam == kNativeZapBannerTimer) {
      KillTimer(hwnd, kNativeZapBannerTimer);
      HideZapBanner();
      return 0;
    }
    if (wparam == kNativeControlsHideTimer) {
      KillTimer(hwnd, kNativeControlsHideTimer);
      if (native_controls_pinned_) {
        ShowNativeControls(true);
        return 0;
      }
      if (!g_native_control_state.playing) {
        ShowNativeControls(true);
        return 0;
      }
      if (ControlsPinnedByOverlay()) {
        ShowNativeControls(true);
        return 0;
      }
      if (IsCursorOverNativeControls()) {
        ScheduleNativeControlsHide();
        return 0;
      }
      ShowNativeControls(false);
      return 0;
    }
    break;
  case kNativeVideoSurfaceInputMessage:
    if (GetTickCount64() < native_ignore_input_until_) {
      return 0;
    }
    ShowNativeControls(true);
    ScheduleNativeControlsHide();
    return 0;
  case kNativeControlCommandMessage: {
    std::unique_ptr<std::string> command(
        reinterpret_cast<std::string *>(wparam));
    const bool pauses_playback =
        *command == "playPause" && g_native_control_state.playing;
    const bool fullscreen_toggle = *command == "fullscreen";
    if (fullscreen_toggle) {
      native_controls_pinned_ = true;
    }
    ShowNativeControls(true);
    NotifyNativeControlCommand(*command);
    if (pauses_playback) {
      KillTimer(hwnd, kNativeControlsHideTimer);
    } else if (fullscreen_toggle) {
      KillTimer(hwnd, kNativeControlsHideTimer);
    } else {
      ScheduleNativeControlsHide();
    }
    return 0;
  }
  case kNativeControlsLayoutMessage:
    ShowNativeControls(true);
    if (!ControlsPinnedByOverlay()) {
      ScheduleNativeControlsHide();
    } else {
      KillTimer(hwnd, kNativeControlsHideTimer);
    }
    ResizeNativeControls();
    ApplyNativeControlsVisibility();
    InvalidateNativeControls();
    return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

HWND FlutterWindow::CreateNativeVideoSurface() {
  if (native_video_surface_) {
    ResizeNativeVideoSurface();
    ShowWindow(native_video_surface_, SW_SHOW);
    SetWindowPos(native_video_surface_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetFocus(native_video_surface_);
    CreateNativeControls();
    return native_video_surface_;
  }

  EnsureNativeVideoSurfaceClass();
  RECT frame = GetClientArea();
  native_video_surface_ = CreateWindowEx(
      0, kNativeVideoSurfaceClassName, L"",
      WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, frame.left, frame.top,
      frame.right - frame.left, frame.bottom - frame.top, GetHandle(), nullptr,
      GetModuleHandle(nullptr), nullptr);
  ResizeNativeVideoSurface();
  if (native_video_surface_) {
    SetWindowPos(native_video_surface_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetFocus(native_video_surface_);
#ifndef NDEBUG
    ++g_debug_surface_count;
#endif
  }
  CreateNativeControls();
  return native_video_surface_;
}

void FlutterWindow::DestroyNativeVideoSurface() {
  KillTimer(GetHandle(), kNativeVideoResyncTimer);
  native_video_resync_passes_ = 0;
  if (native_video_surface_) {
    DestroyWindow(native_video_surface_);
    native_video_surface_ = nullptr;
#ifndef NDEBUG
    --g_debug_surface_count;
#endif
  }
}

void FlutterWindow::ResizeNativeVideoSurface() {
  if (!native_video_surface_) {
    return;
  }
  RECT frame = GetClientArea();
  const int width = frame.right - frame.left;
  const int full_height = frame.bottom - frame.top;
  const int top = native_controls_overlay_
                      ? 0
                      : std::max(0, native_video_surface_top_inset_);
  const int bottom = native_controls_overlay_
                         ? 0
                         : std::max(0, native_video_surface_bottom_inset_);
  const int height = std::max(1, full_height - top - bottom);
  MoveWindow(native_video_surface_, frame.left, frame.top + top, width, height,
             TRUE);
  SetWindowPos(native_video_surface_, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  ResyncNativeVideoRenderer();
  BringNativeControlsToFront();
}

// Size mpv's own VO window to the surface instead of trusting mpv to notice.
//
// In `--wid` embedding mpv tracks the parent through a hook of its own
// (`resize_child_win` in w32_common.c) and reaches its D3D11 `ResizeBuffers`
// *only* when that hook produces a real `WM_SIZE` on its child window — the VO
// re-checks the swapchain on `VO_EVENT_RESIZE` and nothing else, and its own
// `EqualRect` early-out means a size it never learned about is never revisited.
// That hook edge goes missing in practice: captured live on a fullscreen
// transition, the surface was 1920x1080 while mpv's child sat at the
// pre-fullscreen 1264x681, painting the old size into the top-left with black
// filling the rest — permanently, since mpv only re-checks on a size *change*.
// Re-asserting the size here is exactly the stimulus mpv uses on itself, at the
// one moment it may not fire. When the hook did fire this is a no-op: matching
// sizes produce no `WM_SIZE` at all.
//
// |force_event| additionally covers the *sibling* failure, where the window
// sizes already agree but the swapchain is still stale: mpv's `resize()` gives
// up when a frame is in flight ("Attempt at resizing while a frame was in
// progress!") and, exactly as above, never retries. That looks identical on
// screen but is invisible to a size comparison — and to `osd-dimensions`, which
// reports `vo->dwidth/dheight` and is already correct in that case. So when the
// sizes match, step through a 1px-shorter height to manufacture the
// `VO_EVENT_RESIZE` that re-runs `ResizeBuffers`. Used only on the discrete
// post-transition passes, never on live window dragging.
void FlutterWindow::ResyncNativeVideoRenderer(bool force_event) {
  if (!native_video_surface_) {
    return;
  }
  RECT client;
  if (!GetClientRect(native_video_surface_, &client)) {
    return;
  }
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) {
    return;
  }
  // Direct children only: the surface hosts nothing but mpv's VO window (the
  // controls overlay is an owned WS_POPUP of the top-level, not a child here).
  for (HWND child = GetWindow(native_video_surface_, GW_CHILD); child;
       child = GetWindow(child, GW_HWNDNEXT)) {
    RECT r;
    if (!GetClientRect(child, &r)) {
      continue;
    }
    const bool matches =
        r.right - r.left == width && r.bottom - r.top == height;
    if (matches && !force_event) {
      continue;
    }
    // SWP_ASYNCWINDOWPOS because the window belongs to mpv's VO thread, not
    // this one — a synchronous SetWindowPos would block the UI thread until
    // mpv serviced it. mpv passes the same flags in resize_child_win, for the
    // same reason.
    constexpr UINT kFlags = SWP_ASYNCWINDOWPOS | SWP_NOACTIVATE | SWP_NOMOVE |
                            SWP_NOZORDER | SWP_NOOWNERZORDER |
                            SWP_NOSENDCHANGING;
    if (matches) {
      // Sizes already agree, so the call below would generate no `WM_SIZE` on
      // its own. Land on a genuinely different size first (see |force_event|).
      SetWindowPos(child, nullptr, 0, 0, width, std::max(1, height - 1),
                   kFlags);
    }
    SetWindowPos(child, nullptr, 0, 0, width, height, kFlags);
  }
}

// Re-check for a short while after a discrete window transition, so an mpv VO
// window created just *after* the transition is caught too.
void FlutterWindow::ScheduleNativeVideoRendererResync() {
  if (!native_video_surface_) {
    return;
  }
  native_video_resync_passes_ = kNativeVideoResyncPasses;
  SetTimer(GetHandle(), kNativeVideoResyncTimer, kNativeVideoResyncIntervalMs,
           nullptr);
}

void FlutterWindow::SetNativeVideoSurfaceInsets(int top, int bottom) {
  native_video_surface_top_inset_ = std::max(0, top);
  native_video_surface_bottom_inset_ = std::max(0, bottom);
  ResizeNativeVideoSurface();
}

void FlutterWindow::CreateNativeControls() {
  EnsureNativeControlsClass();
  HWND parent = GetHandle();
  if (!parent) {
    return;
  }
  if (!native_controls_overlay_) {
    native_controls_overlay_ =
        CreateWindowEx(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                       kNativeControlsClassName, L"", WS_POPUP, 0, 0, 1, 1,
                       parent, nullptr, GetModuleHandle(nullptr), nullptr);
    SetWindowLongPtr(native_controls_overlay_, GWLP_USERDATA,
                     kNativeControlsKindOverlay);
#ifndef NDEBUG
    if (native_controls_overlay_) {
      ++g_debug_overlay_count;
    }
#endif
  }
  ResizeNativeControls();
  native_controls_visible_ = false;
  ShowNativeControls(true);
  ScheduleNativeControlsHide();
}

void FlutterWindow::DestroyNativeControls() {
  KillTimer(GetHandle(), kNativeControlsHideTimer);
  // The drag globals outlive the window they belong to. A seek preview left
  // set would pin the *next* player's scrubber to a ratio the user chose for a
  // stream that has since closed.
  g_native_slider_drag = NativeSliderDrag::kNone;
  g_native_slider_last_sent = -1.0;
  g_native_seek_preview = -1.0;
  if (native_controls_overlay_) {
    SetWindowRgn(native_controls_overlay_, nullptr, TRUE);
    DestroyWindow(native_controls_overlay_);
    native_controls_overlay_ = nullptr;
#ifndef NDEBUG
    --g_debug_overlay_count;
#endif
  }
  ReleaseOverlayBackBuffer();
  native_controls_region_dirty_ = true;
}

void FlutterWindow::RecreateNativeControls() {
  DestroyNativeControls();
  native_controls_visible_ = false;
  CreateNativeControls();
  ShowNativeControls(true);
  InvalidateNativeControls();
}

void FlutterWindow::ResizeNativeControls() {
  if (!native_controls_overlay_) {
    return;
  }
  RECT frame = GetClientArea();
  const int width = frame.right - frame.left;
  const int height = frame.bottom - frame.top;
  POINT origin{frame.left, frame.top};
  ClientToScreen(GetHandle(), &origin);
  MoveWindow(native_controls_overlay_, origin.x, origin.y, width, height, TRUE);
  native_controls_region_dirty_ = true;
  ApplyNativeControlsVisibility();
  BringNativeControlsToFront();
}

// Whether the overlay *window* should be on screen. Wider than
// native_controls_visible_, which is the chrome: with the chrome hidden the
// window is still up while the zap banner has something to say, or while the
// quick list is open.
bool FlutterWindow::NativeOverlayTargetVisible() const {
  return native_controls_visible_ || ZapBannerShown() || QuickListShown();
}

void FlutterWindow::BringNativeControlsToFront() {
  if (!NativeOverlayTargetVisible()) {
    return;
  }
  if (native_controls_overlay_) {
    SetWindowPos(native_controls_overlay_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }
}

void FlutterWindow::UpdateNativeControlsRegion() {
  if (!native_controls_overlay_) {
    return;
  }
  RECT rect;
  GetClientRect(native_controls_overlay_, &rect);
  if (RectWidth(rect) <= 0 || RectHeight(rect) <= 0) {
    return;
  }
  if (!native_controls_visible_) {
    // Chrome hidden: the overlay exists only to carry the zap banner or the
    // quick list, so the clip region is theirs. Without this they would be
    // clipped away by the bars' region and never appear at all — and anything
    // outside it must stay unpainted, because the region is also what keeps
    // the rest of the window out of the way.
    const RECT banner =
        ZapBannerShown() ? ZapBannerRect(rect) : RectFrom(0, 0, 0, 0);
    // CreateRoundRectRgn's last two arguments are the corner *ellipse* size,
    // i.e. twice the radius — the same conversion FillRoundRect makes, so the
    // clip follows the painted curve instead of cutting inside it.
    HRGN banner_region =
        (RectWidth(banner) > 0 && RectHeight(banner) > 0)
            ? CreateRoundRectRgn(banner.left, banner.top, banner.right,
                                 banner.bottom, kNativeZapBannerRadius * 2,
                                 kNativeZapBannerRadius * 2)
            : CreateRectRgn(0, 0, 0, 0);
    const RECT quick_list =
        QuickListShown() ? QuickListRect(rect) : RectFrom(0, 0, 0, 0);
    if (RectWidth(quick_list) > 0 && RectHeight(quick_list) > 0) {
      HRGN list_region = CreateRoundRectRgn(
          quick_list.left, quick_list.top, quick_list.right, quick_list.bottom,
          kNativeMenuRadius * 2, kNativeMenuRadius * 2);
      CombineRgn(banner_region, banner_region, list_region, RGN_OR);
      DeleteObject(list_region);
    }
    SetWindowRgn(native_controls_overlay_, banner_region, FALSE);
    native_controls_region_dirty_ = false;
    return;
  }

  const RECT top = TopControlsRect(rect);
  const RECT bottom = BottomControlsRect(rect);
  HRGN region = CreateRectRgn(top.left, top.top, top.right, top.bottom);
  HRGN bottom_region =
      CreateRectRgn(bottom.left, bottom.top, bottom.right, bottom.bottom);
  CombineRgn(region, region, bottom_region, RGN_OR);
  DeleteObject(bottom_region);
  if (g_native_control_state.open_menu != NativeMenuKind::kNone) {
    ClampMenuScrollOffset();
    const RECT menu = CurrentMenuRect(rect);
    HRGN menu_region = CreateRoundRectRgn(menu.left, menu.top, menu.right,
                                          menu.bottom, 16, 16);
    CombineRgn(region, region, menu_region, RGN_OR);
    DeleteObject(menu_region);
  }
  if (HasInfoPanel()) {
    const RECT panel = InfoPanelRect(rect);
    HRGN panel_region = CreateRoundRectRgn(panel.left, panel.top, panel.right,
                                           panel.bottom, 12, 12);
    CombineRgn(region, region, panel_region, RGN_OR);
    DeleteObject(panel_region);
  }
  if (QuickListShown()) {
    // The chrome can come up over an open list, so the bars' region has to
    // make room for it too.
    const RECT quick_list = QuickListRect(rect);
    if (RectWidth(quick_list) > 0 && RectHeight(quick_list) > 0) {
      HRGN list_region = CreateRoundRectRgn(
          quick_list.left, quick_list.top, quick_list.right, quick_list.bottom,
          kNativeMenuRadius * 2, kNativeMenuRadius * 2);
      CombineRgn(region, region, list_region, RGN_OR);
      DeleteObject(list_region);
    }
  }
  SetWindowRgn(native_controls_overlay_, region, FALSE);
  native_controls_region_dirty_ = false;
}

bool FlutterWindow::IsCursorOverNativeControls() const {
  POINT point;
  if (!GetCursorPos(&point)) {
    return false;
  }
  if (!native_controls_overlay_ || !IsWindowVisible(native_controls_overlay_)) {
    return false;
  }
  RECT rect;
  if (!GetWindowRect(native_controls_overlay_, &rect) ||
      !PtInRect(&rect, point)) {
    return false;
  }
  ScreenToClient(native_controls_overlay_, &point);
  RECT client;
  GetClientRect(native_controls_overlay_, &client);
  return PointInRect(point.x, point.y, TopControlsRect(client)) ||
         PointInRect(point.x, point.y, BottomControlsRect(client)) ||
         (g_native_control_state.open_menu != NativeMenuKind::kNone &&
          PointInRect(point.x, point.y, CurrentMenuRect(client))) ||
         (HasInfoPanel() && PointInRect(point.x, point.y, InfoPanelRect(client)));
}

void FlutterWindow::ShowNativeControls(bool visible) {
  const bool visibility_changed = native_controls_visible_ != visible;
  native_controls_visible_ = visible;
  // The free functions in this file's anonymous namespace (the paint, the key
  // policy) need the chrome's state, and the overlay window's own visibility
  // no longer answers that question — the zap banner keeps it up with the
  // chrome down.
  g_native_controls_chrome_visible = visible;
  if (visibility_changed) {
    // The chrome and the banner clip to different regions, so every crossing
    // has to rebuild it.
    native_controls_region_dirty_ = true;
  }
  if (!visible) {
    native_ignore_input_until_ = GetTickCount64() + 650;
    if (g_native_control_state.open_menu != NativeMenuKind::kNone ||
        g_native_control_state.info_open) {
      g_native_control_state.open_menu = NativeMenuKind::kNone;
      g_native_control_state.info_open = false;
      native_controls_region_dirty_ = true;
    }
  } else {
    native_ignore_input_until_ = 0;
  }
  if (g_native_video_cursor_visible != visible) {
    g_native_video_cursor_visible = visible;
    SetCursor(visible ? LoadCursor(nullptr, IDC_ARROW) : nullptr);
  }
  const bool currently_visible =
      native_controls_overlay_ &&
      IsWindowVisible(native_controls_overlay_) != FALSE;
  if (visibility_changed ||
      currently_visible != NativeOverlayTargetVisible() ||
      native_controls_region_dirty_) {
    ApplyNativeControlsVisibility();
  }
  if (visibility_changed && NativeOverlayTargetVisible()) {
    // The overlay window stays up across this crossing — the zap banner keeps
    // it there with the chrome down — so what is composited on it is now the
    // wrong half, and the region has just been rebuilt to match the other
    // one. An auto-hide has nothing else that would repaint it.
    InvalidateNativeControls();
  }
  if (!visible && visibility_changed) {
    if (native_video_surface_) {
      POINT point;
      if (GetCursorPos(&point)) {
        ScreenToClient(native_video_surface_, &point);
        g_last_video_mouse = point;
      }
    }
    g_last_controls_mouse = {-1, -1};
  }

  // Keep keyboard focus on the native video surface while native playback is
  // active, so D-pad / keyboard input always routes through the native handler.
  if (native_video_surface_ && GetFocus() != native_video_surface_) {
    SetFocus(native_video_surface_);
  }
}

void FlutterWindow::ApplyNativeControlsVisibility() {
  if (!native_controls_overlay_) {
    return;
  }
  if (native_controls_region_dirty_) {
    UpdateNativeControlsRegion();
  }
  const bool target_visible = NativeOverlayTargetVisible();
  // While only the banner or the quick list is drawn the overlay is
  // decoration, not chrome: neither has a hit target — the list is a
  // selection model driven by the key ring, exactly as the shared Flutter
  // overlay's panel is `IgnorePointer` — and swallowing the pointer over
  // their band would stop a mouse move there from reaching the video
  // surface, whose WM_MOUSEMOVE is the only thing that reveals the controls.
  const LONG_PTR ex_style =
      GetWindowLongPtr(native_controls_overlay_, GWL_EXSTYLE);
  const LONG_PTR wanted_ex_style =
      (target_visible && !native_controls_visible_)
          ? (ex_style | WS_EX_TRANSPARENT)
          : (ex_style & ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT));
  if (wanted_ex_style != ex_style) {
    SetWindowLongPtr(native_controls_overlay_, GWL_EXSTYLE, wanted_ex_style);
  }
  const bool currently_visible =
      IsWindowVisible(native_controls_overlay_) != FALSE;
  if (currently_visible != target_visible) {
    ShowWindow(native_controls_overlay_,
               target_visible ? SW_SHOWNOACTIVATE : SW_HIDE);
    if (target_visible) {
      BringNativeControlsToFront();
    }
  }
}

void FlutterWindow::InvalidateNativeControls(bool include_subtitles) {
  if (NativeOverlayTargetVisible() && native_controls_overlay_) {
    InvalidateRect(native_controls_overlay_, nullptr, FALSE);
    UpdateWindow(native_controls_overlay_);
  }
}

void FlutterWindow::ScheduleNativeControlsHide() {
  HWND hwnd = GetHandle();
  if (!hwnd) {
    return;
  }
  KillTimer(hwnd, kNativeControlsHideTimer);
  if (native_controls_pinned_) {
    return;
  }
  if (g_native_control_state.playing && !ControlsPinnedByOverlay()) {
    SetTimer(hwnd, kNativeControlsHideTimer, 3500, nullptr);
  }
}

void FlutterWindow::NotifyNativeControlCommand(const std::string &command) {
  if (!native_hdr_channel_) {
    return;
  }
  native_hdr_channel_->InvokeMethod("nativeControl",
                                    std::make_unique<flutter::EncodableValue>(
                                        flutter::EncodableValue(command)));
}

void FlutterWindow::UpdateNativeControlState(
    const flutter::EncodableValue *args) {
  const bool was_playing = g_native_control_state.playing;
  const bool was_pinned = native_controls_pinned_;
  // The bottom bar grows for live-with-EPG; if its height changes (e.g. the EPG
  // snapshot arrives after the first frame), the clip region must be rebuilt or
  // the taller bar is clipped until the next resize.
  const int prev_bottom_height = BottomControlsHeight();
  g_native_control_state.title =
      EncodableStringArg(args, "title", g_native_control_state.title);
  g_native_control_state.is_live =
      EncodableBoolArg(args, "isLive", g_native_control_state.is_live);
  g_native_control_state.live_synced =
      EncodableBoolArg(args, "liveSynced", g_native_control_state.live_synced);
  g_native_control_state.can_favorite =
      EncodableBoolArg(args, "canFavorite", g_native_control_state.can_favorite);
  g_native_control_state.is_favorite =
      EncodableBoolArg(args, "isFavorite", g_native_control_state.is_favorite);
  g_native_control_state.reconnecting =
      EncodableBoolArg(args, "reconnecting", g_native_control_state.reconnecting);
  g_native_control_state.playing =
      EncodableBoolArg(args, "playing", g_native_control_state.playing);
  g_native_control_state.fullscreen =
      EncodableBoolArg(args, "fullscreen", native_window_fullscreen_);
  g_native_control_state.position_ms = EncodableDoubleArg(
      args, "positionMs", g_native_control_state.position_ms);
  g_native_control_state.duration_ms = EncodableDoubleArg(
      args, "durationMs", g_native_control_state.duration_ms);
  g_native_control_state.volume =
      EncodableDoubleArg(args, "volume", g_native_control_state.volume);
  g_native_control_state.selected_subtitle_id = EncodableStdStringArg(
      args, "selectedSubtitleId", g_native_control_state.selected_subtitle_id);
  g_native_control_state.selected_audio_id = EncodableStdStringArg(
      args, "selectedAudioId", g_native_control_state.selected_audio_id);
  g_native_control_state.selected_speed_id = EncodableStdStringArg(
      args, "selectedSpeedId", g_native_control_state.selected_speed_id);
  if (args && std::holds_alternative<flutter::EncodableMap>(*args)) {
    g_native_control_state.subtitle_tracks =
        ParseMenuOptions(args, "subtitleTracks");
    g_native_control_state.audio_tracks = ParseMenuOptions(args, "audioTracks");
    g_native_control_state.speed_options =
        ParseMenuOptions(args, "speedOptions");
  }
  g_native_control_state.aspect_label =
      EncodableStringArg(args, "aspectLabel", g_native_control_state.aspect_label);
  g_native_control_state.video_width =
      EncodableIntArg(args, "videoWidth", g_native_control_state.video_width);
  g_native_control_state.video_height =
      EncodableIntArg(args, "videoHeight", g_native_control_state.video_height);
  g_native_control_state.fps =
      EncodableDoubleArg(args, "fps", g_native_control_state.fps);
  g_native_control_state.dynamic_range = EncodableStringArg(
      args, "dynamicRange", g_native_control_state.dynamic_range);
  g_native_control_state.video_codec =
      EncodableStringArg(args, "videoCodec", g_native_control_state.video_codec);
  g_native_control_state.audio_codec =
      EncodableStringArg(args, "audioCodec", g_native_control_state.audio_codec);
  g_native_control_state.audio_channels = EncodableStringArg(
      args, "audioChannels", g_native_control_state.audio_channels);
  g_native_control_state.source_name =
      EncodableStringArg(args, "sourceName", g_native_control_state.source_name);
  g_native_control_state.zap_enabled =
      EncodableBoolArg(args, "zapEnabled", g_native_control_state.zap_enabled);
  // EPG now/next ride along on every setControlState, so default to empty: that
  // clears them for VOD and keeps live in sync.
  g_native_control_state.epg_now_title =
      EncodableStringArg(args, "epgNowTitle", L"");
  g_native_control_state.epg_now_start_ms =
      EncodableDoubleArg(args, "epgNowStartMs", 0.0);
  g_native_control_state.epg_now_stop_ms =
      EncodableDoubleArg(args, "epgNowStopMs", 0.0);
  g_native_control_state.epg_now_desc =
      EncodableStringArg(args, "epgNowDesc", L"");
  g_native_control_state.epg_next_title =
      EncodableStringArg(args, "epgNextTitle", L"");
  g_native_control_state.epg_next_start_ms =
      EncodableDoubleArg(args, "epgNextStartMs", 0.0);
  g_native_control_state.epg_next_stop_ms =
      EncodableDoubleArg(args, "epgNextStopMs", 0.0);

  if (BottomControlsHeight() != prev_bottom_height) {
    native_controls_region_dirty_ = true;
  }

  // If the open menu lost all its options (e.g. tracks changed), close it. Same
  // for the info panel if there is nothing left to show.
  if (g_native_control_state.open_menu != NativeMenuKind::kNone) {
    native_controls_region_dirty_ = true;
    if (MenuOptions(g_native_control_state.open_menu).empty()) {
      g_native_control_state.open_menu = NativeMenuKind::kNone;
    } else {
      ClampMenuScrollOffset();
    }
  }
  if (g_native_control_state.info_open && InfoRows().empty()) {
    g_native_control_state.info_open = false;
    native_controls_region_dirty_ = true;
  }

  // A zap deliberately stops the stream between channels (`_zapStopCurrent`),
  // so `playing` goes false for the length of the settle. Without this the
  // paused-media reveal below would throw the chrome up on every channel
  // change — taking the banner down with it (the two are mutually exclusive)
  // and handing the arrows back to the control row mid-zap, which is the one
  // moment the user is certainly still holding one.
  const bool zap_settling = g_native_zap_state.settling && ZapActive();
  const bool paused = !g_native_control_state.playing && !zap_settling;

  native_controls_pinned_ = paused || ControlsPinnedByOverlay();
  if (native_video_surface_) {
    if (paused) {
      KillTimer(GetHandle(), kNativeControlsHideTimer);
      ShowNativeControls(true);
    } else if (ControlsPinnedByOverlay()) {
      KillTimer(GetHandle(), kNativeControlsHideTimer);
    } else if (!was_playing || was_pinned) {
      ScheduleNativeControlsHide();
    }
  }
  ApplyNativeControlsVisibility();
  InvalidateNativeControls();
}

// The inbound half of `setZapBanner` (docs/player.md "Live zapping"). Its own
// method, never folded into setControlState: that path is coalesced at 2 Hz
// and a banner has to track every press.
void FlutterWindow::UpdateZapBanner(const flutter::EncodableValue *args) {
  NativeZapState &z = g_native_zap_state;
  z.has_banner = true;
  // Absent and zero are different answers here: `bannerPayload` omits
  // `channelNumber` entirely for a channel the provider gave no number for,
  // and the identity run reads "BBC One" rather than "0 · BBC One" for it.
  z.has_channel_number = EncodableHasKey(args, "channelNumber");
  z.channel_number = EncodableIntArg(args, "channelNumber", 0);
  z.channel_name = EncodableStringArg(args, "channelName", L"");
  z.digits = EncodableStringArg(args, "digits", L"");
  z.message = EncodableStringArg(args, "message", L"");
  z.settling = EncodableBoolArg(args, "settling", false);
  z.position = EncodableIntArg(args, "position", 0);
  z.total = EncodableIntArg(args, "total", 0);
  // Every field defaults to empty rather than to what was there before: the
  // payload describes the cursor's channel in full, so a channel with no
  // guide must clear the last one's rather than inherit it.
  z.epg_now_title = EncodableStringArg(args, "epgNowTitle", L"");
  z.epg_now_start_ms = EncodableDoubleArg(args, "epgNowStartMs", 0.0);
  z.epg_now_stop_ms = EncodableDoubleArg(args, "epgNowStopMs", 0.0);
  z.epg_next_title = EncodableStringArg(args, "epgNextTitle", L"");
  z.epg_next_start_ms = EncodableDoubleArg(args, "epgNextStartMs", 0.0);
  z.epg_next_stop_ms = EncodableDoubleArg(args, "epgNextStopMs", 0.0);
  z.visible = true;
  // The authoritative buffer has arrived; drop the optimistic mirror the key
  // ring set when it dispatched the digit.
  g_native_zap_digits_optimistic = false;

  if (HWND hwnd = GetHandle()) {
    // Restart rather than stack: each press gets the full window.
    KillTimer(hwnd, kNativeZapBannerTimer);
    SetTimer(hwnd, kNativeZapBannerTimer, kNativeZapBannerVisibleMs, nullptr);
  }
  // Two reasons at once, both region-invalidating: the banner's own rect grows
  // and shrinks with whether the cursor channel has a guide, and the bottom
  // bar's height moves with the identity run (BottomControlsHeight).
  native_controls_region_dirty_ = true;
  ApplyNativeControlsVisibility();
  InvalidateNativeControls();
}

// The inbound half of `setQuickList` (docs/player.md "The quick list"), and
// the one place a wire payload becomes a [iptvs::QuickListState].
//
// Everything below the `EncodableValue` unwrapping is Win32-free by design
// (`zap_quick_list_state.h`): the interesting part of this feature on this
// surface is the windowing arithmetic, and it is testable without a
// toolchain, while this adapter is not.
void FlutterWindow::UpdateQuickList(const flutter::EncodableValue *args) {
  const bool was_shown = QuickListShown();
  iptvs::QuickListState next;
  next.open = EncodableBoolArg(args, "open", false);
  next.mode = iptvs::QuickListModeFromName(
      EncodableStdStringArg(args, "mode", "channels"));
  next.heading = EncodableStringArg(args, "heading", L"");
  next.selected_index = EncodableIntArg(args, "selectedIndex", 0);
  next.window_start = EncodableIntArg(args, "windowStart", 0);
  next.total = EncodableIntArg(args, "total", 0);
  next.loading = EncodableBoolArg(args, "loading", false);
  // Optional on the wire: absent while loading or non-empty.
  next.empty_label = EncodableStringArg(args, "emptyLabel", L"");
  next.revision = EncodableIntArg(args, "revision", 0);
  if (args && std::holds_alternative<flutter::EncodableMap>(*args)) {
    const auto &map = std::get<flutter::EncodableMap>(*args);
    const auto rows = map.find(flutter::EncodableValue("rows"));
    if (rows != map.end() &&
        std::holds_alternative<flutter::EncodableList>(rows->second)) {
      for (const auto &item : std::get<flutter::EncodableList>(rows->second)) {
        if (!std::holds_alternative<flutter::EncodableMap>(item)) {
          continue;
        }
        // The existing Encodable*Arg helpers take any value that *holds* a
        // map, so a row element parses with no second set of helpers.
        iptvs::QuickListRow row;
        row.index = EncodableIntArg(&item, "index", 0);
        row.id = EncodableStdStringArg(&item, "id", "");
        row.label = EncodableStringArg(&item, "label", L"");
        row.secondary = EncodableStringArg(&item, "secondary", L"");
        row.badge = EncodableStringArg(&item, "badge", L"");
        row.kind = iptvs::QuickListRowKindFromName(
            EncodableStdStringArg(&item, "kind", "channel"));
        row.selected = EncodableBoolArg(&item, "selected", false);
        row.playing = EncodableBoolArg(&item, "playing", false);
        row.archive = EncodableBoolArg(&item, "archive", false);
        row.past = EncodableBoolArg(&item, "past", false);
        row.live = EncodableBoolArg(&item, "live", false);
        next.rows.push_back(std::move(row));
      }
    }
  }
  g_native_quick_list = std::move(next);

  const bool is_shown = QuickListShown();
  if (!was_shown && !is_shown) {
    // A closed list is pushed on **every** controller notification, i.e. on
    // every keypress of a held zap. Rebuilding the clip region and asking for
    // a repaint for each of those would be churn with a known answer.
    return;
  }
  // The panel's height moves with the row count, and the banner it suppresses
  // has a different rect entirely, so any crossing needs a new region.
  native_controls_region_dirty_ = true;
  if (was_shown && !is_shown && !native_controls_visible_) {
    // Same trap HideZapBanner documents: a layered window keeps whatever was
    // last composited into it, so taking the overlay down with the list still
    // on its surface would flash the list for a frame the next time anything
    // brought the window back. Repaint directly — InvalidateNativeControls
    // would decline, the overlay's target visibility having just gone false —
    // and only then let ApplyNativeControlsVisibility hide it.
    if (native_controls_overlay_) {
      InvalidateRect(native_controls_overlay_, nullptr, FALSE);
      UpdateWindow(native_controls_overlay_);
    }
  }
  ApplyNativeControlsVisibility();
  InvalidateNativeControls();
}

// The 3 s timer expiring. A half-typed number or a transient note outlives it
// (ZapBannerShown), so this is a repaint request, not an unconditional hide.
void FlutterWindow::HideZapBanner() {
  if (!g_native_zap_state.visible) {
    return;
  }
  g_native_zap_state.visible = false;
  native_controls_region_dirty_ = true;
  // Repaint *before* hiding, and directly rather than through
  // InvalidateNativeControls (which would now decline, the overlay's target
  // visibility having just gone false). A layered window keeps whatever was
  // last composited into it, so one hidden with the banner still on its
  // surface would flash that banner for a frame the next time the chrome came
  // up. The paint sees ZapBannerShown() already false, so it clears the band
  // and composites transparency over it.
  if (native_controls_overlay_) {
    InvalidateRect(native_controls_overlay_, nullptr, FALSE);
    UpdateWindow(native_controls_overlay_);
  }
  ApplyNativeControlsVisibility();
}

// Session teardown for the banner **and the quick list** (ResetNativeZapState
// clears both — they are one feature's state, and a list left standing after
// `destroySurface` would hold the overlay window up with nothing behind it).
// Deliberately *not* called from DestroyNativeControls, which also runs on a
// fullscreen / mini-player transition (via RecreateNativeControls) — dropping
// them there would leave a held key unacknowledged, and killing the timer
// without clearing `visible` would leave the banner up forever.
void FlutterWindow::ResetZapBanner() {
  KillTimer(GetHandle(), kNativeZapBannerTimer);
  ResetNativeZapState();
  native_controls_region_dirty_ = true;
}

void FlutterWindow::SetNativeWindowFullscreen(bool fullscreen) {
  HWND hwnd = GetHandle();
  if (!hwnd || native_window_fullscreen_ == fullscreen) {
    return;
  }
  // Fullscreen and mini-player are mutually exclusive; leave mini first so
  // the saved windowed placement isn't overwritten with the mini geometry.
  if (fullscreen && native_window_mini_) {
    SetNativeWindowMiniPlayer(false);
  }

  if (fullscreen) {
    native_windowed_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    native_windowed_ex_style_ = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    native_windowed_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &native_windowed_placement_);

    HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO monitor_info{};
    monitor_info.cbSize = sizeof(MONITORINFO);
    GetMonitorInfo(monitor, &monitor_info);

    SetWindowLongPtr(hwnd, GWL_STYLE,
                     native_windowed_style_ & ~WS_OVERLAPPEDWINDOW);
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, native_windowed_ex_style_);
    SetWindowPos(hwnd, HWND_TOP, monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.top,
                 monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                 monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    native_window_fullscreen_ = true;
  } else {
    SetWindowLongPtr(hwnd, GWL_STYLE, native_windowed_style_);
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, native_windowed_ex_style_);
    SetWindowPlacement(hwnd, &native_windowed_placement_);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                     SWP_FRAMECHANGED);
    native_window_fullscreen_ = false;
  }
  ResizeNativeVideoSurface();
  ScheduleNativeVideoRendererResync();
  RecreateNativeControls();
  ShowNativeControls(true);
  if (native_controls_pinned_ || !g_native_control_state.playing) {
    KillTimer(hwnd, kNativeControlsHideTimer);
  } else {
    ScheduleNativeControlsHide();
  }
}

// Always-on-top mini-player: shrink the top level window to a compact,
// frameless (but resizable), topmost video window docked at the bottom-right
// of the work area. WM_NCHITTEST (see MessageHandler) makes the client area
// drag the window. Restoring puts the saved windowed style/placement back.
void FlutterWindow::SetNativeWindowMiniPlayer(bool mini) {
  HWND hwnd = GetHandle();
  if (!hwnd || native_window_mini_ == mini) {
    return;
  }
  if (mini && native_window_fullscreen_) {
    SetNativeWindowFullscreen(false);
  }

  if (mini) {
    native_windowed_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    native_windowed_ex_style_ = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    native_windowed_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(hwnd, &native_windowed_placement_);

    HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO monitor_info{};
    monitor_info.cbSize = sizeof(MONITORINFO);
    GetMonitorInfo(monitor, &monitor_info);
    const RECT &work = monitor_info.rcWork;

    // 16:9 video sized to a quarter of the work-area width, clamped sane.
    int width = (work.right - work.left) / 4;
    if (width < 384) width = 384;
    if (width > 640) width = 640;
    const int height = width * 9 / 16;
    const int margin = 16;

    // Frameless but resizable (WS_THICKFRAME keeps the sizing borders).
    SetWindowLongPtr(hwnd, GWL_STYLE,
                     (native_windowed_style_ & ~WS_OVERLAPPEDWINDOW) |
                         WS_POPUP | WS_THICKFRAME);
    SetWindowPos(hwnd, HWND_TOPMOST, work.right - width - margin,
                 work.bottom - height - margin, width, height,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    native_window_mini_ = true;
    g_native_window_mini = true;
  } else {
    SetWindowLongPtr(hwnd, GWL_STYLE, native_windowed_style_);
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, native_windowed_ex_style_);
    SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER |
                     SWP_FRAMECHANGED);
    SetWindowPlacement(hwnd, &native_windowed_placement_);
    native_window_mini_ = false;
    g_native_window_mini = false;
  }
  ResizeNativeVideoSurface();
  ScheduleNativeVideoRendererResync();
  RecreateNativeControls();
  ShowNativeControls(true);
  if (native_controls_pinned_ || !g_native_control_state.playing) {
    KillTimer(hwnd, kNativeControlsHideTimer);
  } else {
    ScheduleNativeControlsHide();
  }
}

void FlutterWindow::RegisterNativeHdrPlayerChannel() {
  native_hdr_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kNativeHdrPlayerChannel,
          &flutter::StandardMethodCodec::GetInstance());

  native_hdr_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue> &call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "createSurface") {
          SetNativeVideoSurfaceInsets(
              EncodableIntArg(call.arguments(), "topInset", 0),
              EncodableIntArg(call.arguments(), "bottomInset", 0));
          HWND surface = CreateNativeVideoSurface();
          if (!surface) {
            result->Error("surface_unavailable",
                          "Could not create native video surface");
            return;
          }
          result->Success(flutter::EncodableValue(
              static_cast<int64_t>(reinterpret_cast<intptr_t>(surface))));
          return;
        }

        if (call.method_name() == "destroySurface") {
          ResetZapBanner();
          DestroyNativeControls();
          if (native_video_surface_) {
            ShowWindow(native_video_surface_, SW_HIDE);
          }
          DestroyNativeVideoSurface();
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "hideSurface") {
          ShowNativeControls(false);
          if (native_video_surface_) {
            ShowWindow(native_video_surface_, SW_HIDE);
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "prepareExit") {
          ResetZapBanner();
          SetNativeWindowFullscreen(false);
          SetNativeWindowMiniPlayer(false);
          DestroyNativeControls();
          if (native_video_surface_) {
            ShowWindow(native_video_surface_, SW_HIDE);
          }
          g_native_control_state.open_menu = NativeMenuKind::kNone;
          g_native_control_state.info_open = false;
          g_native_menu_scroll_offset = 0;
          g_native_video_cursor_visible = true;
          SetCursor(LoadCursor(nullptr, IDC_ARROW));
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "setCursorVisible") {
          bool visible = true;
          const auto *args = call.arguments();
          if (args && std::holds_alternative<bool>(*args)) {
            visible = std::get<bool>(*args);
          }
          g_native_video_cursor_visible = visible;
          SetCursor(visible ? LoadCursor(nullptr, IDC_ARROW) : nullptr);
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "setControlState") {
          UpdateNativeControlState(call.arguments());
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "setZapBanner") {
          UpdateZapBanner(call.arguments());
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "setQuickList") {
          UpdateQuickList(call.arguments());
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "showControls") {
          bool visible = true;
          bool schedule_hide = true;
          const auto *args = call.arguments();
          if (args && std::holds_alternative<bool>(*args)) {
            visible = std::get<bool>(*args);
          } else if (args &&
                     std::holds_alternative<flutter::EncodableMap>(*args)) {
            visible = EncodableBoolArg(args, "visible", visible);
            schedule_hide =
                EncodableBoolArg(args, "scheduleHide", schedule_hide);
          }
          ShowNativeControls(visible);
          if (visible && schedule_hide) {
            ScheduleNativeControlsHide();
          } else {
            KillTimer(GetHandle(), kNativeControlsHideTimer);
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "setFullscreen") {
          bool fullscreen = false;
          bool pin_controls = !g_native_control_state.playing;
          const auto *args = call.arguments();
          if (args && std::holds_alternative<bool>(*args)) {
            fullscreen = std::get<bool>(*args);
          } else if (args &&
                     std::holds_alternative<flutter::EncodableMap>(*args)) {
            fullscreen = EncodableBoolArg(args, "fullscreen", fullscreen);
            pin_controls = EncodableBoolArg(args, "pinControls", pin_controls);
          }
          native_controls_pinned_ = pin_controls;
          SetNativeWindowFullscreen(fullscreen);
          ShowNativeControls(true);
          if (native_controls_pinned_) {
            KillTimer(GetHandle(), kNativeControlsHideTimer);
          }
          result->Success(flutter::EncodableValue(native_window_fullscreen_));
          return;
        }

        if (call.method_name() == "setInsets") {
          SetNativeVideoSurfaceInsets(
              EncodableIntArg(call.arguments(), "topInset", 0),
              EncodableIntArg(call.arguments(), "bottomInset", 0));
          result->Success(flutter::EncodableValue(true));
          return;
        }

        if (call.method_name() == "isFullscreen") {
          result->Success(flutter::EncodableValue(native_window_fullscreen_));
          return;
        }

        if (call.method_name() == "setMiniPlayer") {
          bool mini = false;
          const auto *args = call.arguments();
          if (args && std::holds_alternative<bool>(*args)) {
            mini = std::get<bool>(*args);
          } else if (args &&
                     std::holds_alternative<flutter::EncodableMap>(*args)) {
            mini = EncodableBoolArg(args, "mini", mini);
          }
          SetNativeWindowMiniPlayer(mini);
          result->Success(flutter::EncodableValue(native_window_mini_));
          return;
        }

        if (call.method_name() == "debugCounters") {
          flutter::EncodableMap counters;
#ifndef NDEBUG
          counters[flutter::EncodableValue("windowsSurfaces")] =
              flutter::EncodableValue(g_debug_surface_count);
          counters[flutter::EncodableValue("windowsOverlays")] =
              flutter::EncodableValue(g_debug_overlay_count);
          counters[flutter::EncodableValue("windowsOverlayDibs")] =
              flutter::EncodableValue(g_debug_overlay_dib_count);
#endif
          result->Success(flutter::EncodableValue(counters));
          return;
        }

        result->NotImplemented();
      });
}
