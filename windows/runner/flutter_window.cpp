#include "flutter_window.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <ctime>
#include <cstdint>
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
constexpr int kNativeTopControlsHeight = 64;
// The bottom bar is a single row for live (no scrubber) and two rows for VOD
// (scrubber row + control row).
constexpr int kNativeBottomControlsHeightLive = 80;
constexpr int kNativeBottomControlsHeightVod = 116;
// Live with an EPG snapshot gets a taller bar: a programme row (title + progress
// + next) sits where the VOD scrubber would be.
constexpr int kNativeBottomControlsHeightLiveEpg = 150;
constexpr int kNativeMenuWidth = 300;
constexpr int kNativeMenuHeaderHeight = 36;
constexpr int kNativeMenuRowHeight = 40;
constexpr int kNativeMenuMaxRows = 5;
constexpr int kNativeMenuPadding = 10;
constexpr int kNativeControlsKindOverlay = 0;
bool g_native_video_cursor_visible = true;
POINT g_last_video_mouse{-1, -1};
POINT g_last_controls_mouse{-1, -1};
int g_native_menu_scroll_offset = 0;
int g_native_focus_index = 0;
bool g_native_keyboard_focus_visible = false;

enum class NativeFocusItem {
  kBack,
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

bool ControlsPinnedByOverlay() {
  return g_native_control_state.open_menu != NativeMenuKind::kNone ||
         g_native_control_state.info_open;
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
  return CreateFont(size, 0, 0, 0, lf_weight, FALSE, FALSE, FALSE,
                    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                    CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, face);
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

void FillRoundRect(HDC hdc, const RECT &rect, int radius, COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  HBRUSH old_brush = static_cast<HBRUSH>(SelectObject(hdc, brush));
  HPEN pen = CreatePen(PS_SOLID, 1, color);
  HPEN old_pen = static_cast<HPEN>(SelectObject(hdc, pen));
  RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, radius, radius);
  SelectObject(hdc, old_pen);
  SelectObject(hdc, old_brush);
  DeleteObject(pen);
  DeleteObject(brush);
}

void DrawTextWithFont(HDC hdc, const std::wstring &text, RECT rect, UINT format,
                      HFONT font, COLORREF color) {
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  SetTextColor(hdc, color);
  DrawText(hdc, text.c_str(), -1, &rect, format);
  SelectObject(hdc, old_font);
}

void DrawIconButton(HDC hdc, const RECT &rect, const std::wstring &icon,
                    bool active = false) {
  const COLORREF bg = active ? RGB(38, 34, 78) : RGB(18, 20, 28);
  const COLORREF fg = active ? RGB(255, 255, 255) : RGB(232, 235, 244);
  FillRoundRect(hdc, rect, 12, bg);
  HFONT icon_font = UiFont(20, FW_NORMAL, L"Segoe MDL2 Assets");
  DrawTextWithFont(hdc, icon, rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                   icon_font, fg);
  DeleteObject(icon_font);
}

void DrawTextButton(HDC hdc, const RECT &rect, const std::wstring &label,
                    bool active = false) {
  const COLORREF bg = active ? RGB(38, 34, 78) : RGB(18, 20, 28);
  const COLORREF fg = active ? RGB(255, 255, 255) : RGB(232, 235, 244);
  FillRoundRect(hdc, rect, 12, bg);
  HFONT font = UiFont(13, FW_SEMIBOLD);
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
    return HasLiveEpg() ? kNativeBottomControlsHeightLiveEpg
                        : kNativeBottomControlsHeightLive;
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
  // Live EPG row (programme title + progress + next), where the scrubber sits.
  bool has_epg = false;
  RECT epg_title;
  RECT epg_time;
  RECT epg_progress;
  RECT epg_next;
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
  const int kBtn = 36;
  const int top = cy - kBtn / 2;
  const int bot = cy + kBtn / 2;

  int x = 16;
  l.play = RectFrom(x, cy - 21, x + 42, cy + 21);
  x += 42 + 12;
  l.has_seek = !live;
  if (l.has_seek) {
    l.seek_back = RectFrom(x, top, x + 44, bot);
    x += 44 + 6;
    l.seek_forward = RectFrom(x, top, x + 44, bot);
    x += 44 + 14;
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
  place(l.aspect, 52);
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
    place(l.speed, 54);
  }
  // "Go to live" button, shown only once behind the live edge; left end of the
  // right cluster.
  l.has_go_live = live && !g_native_control_state.live_synced;
  if (l.has_go_live) {
    place(l.go_live, 54);
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

  l.has_epg = HasLiveEpg();
  if (l.has_epg) {
    // Programme row sits in the upper part of the (taller) live bar, well clear
    // of the control row below: title + time, then progress, then next.
    const int ey = by + 18;
    const int time_w = 110;
    l.epg_title = RectFrom(16, ey, MaxInt(20, right - 16 - time_w - 10), ey + 20);
    l.epg_time = RectFrom(right - 16 - time_w, ey, right - 16, ey + 20);
    l.epg_progress = RectFrom(16, ey + 30, right - 16, ey + 30 + 6);
    l.epg_next = RectFrom(16, ey + 46, right - 16, ey + 46 + 18);
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

std::wstring ResolutionBadge() {
  const int w = g_native_control_state.video_width;
  const int h = g_native_control_state.video_height;
  if (w >= 3840 || h >= 2160) {
    return L"4K";
  }
  if (h >= 1080) {
    return L"1080p";
  }
  if (h >= 720) {
    return L"720p";
  }
  if (h > 0) {
    return L"SD";
  }
  return L"";
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
  if (wcsftime(buffer, 64, L"%a %d %b · %H:%M", &local) == 0) {
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
  FillRoundRect(hdc, RectFrom(track.left, cy - 3, track.right, cy + 3), 6,
                RGB(39, 43, 58));
  const int fill_x =
      track.left + static_cast<int>(RectWidth(track) * std::clamp(ratio, 0.0,
                                                                  1.0));
  FillRoundRect(hdc, RectFrom(track.left, cy - 3, fill_x, cy + 3), 6,
                RGB(123, 108, 246));
  FillRoundRect(hdc,
                RectFrom(fill_x - thumb_radius, cy - thumb_radius,
                         fill_x + thumb_radius, cy + thumb_radius),
                thumb_radius * 2, RGB(154, 141, 255));
}

// Draws a pill badge ending at [right_edge]; returns the horizontal space it
// consumed (badge width + trailing gap) so callers can stack badges leftward.
int DrawBadge(HDC hdc, int right_edge, int center_y, const std::wstring &text,
              COLORREF bg, COLORREF fg) {
  HFONT font = UiFont(11, FW_BOLD);
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  SIZE size{};
  GetTextExtentPoint32(hdc, text.c_str(), static_cast<int>(text.size()),
                       &size);
  SelectObject(hdc, old_font);
  const int width = size.cx + 18;
  const RECT badge =
      RectFrom(right_edge - width, center_y - 11, right_edge, center_y + 11);
  FillRoundRect(hdc, badge, 7, bg);
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

void PaintInfoPanel(HDC hdc, const RECT &rect) {
  const auto rows = InfoRows();
  if (rows.empty()) {
    return;
  }
  const RECT panel = InfoPanelRect(rect);
  FillRoundRect(hdc, panel, 12, RGB(10, 11, 16));
  HPEN border_pen = CreatePen(PS_SOLID, 1, RGB(123, 108, 246));
  HPEN old_pen = static_cast<HPEN>(SelectObject(hdc, border_pen));
  HBRUSH old_brush = static_cast<HBRUSH>(SelectObject(hdc, GetStockObject(NULL_BRUSH)));
  RoundRect(hdc, panel.left, panel.top, panel.right, panel.bottom, 12, 12);
  SelectObject(hdc, old_brush);
  SelectObject(hdc, old_pen);
  DeleteObject(border_pen);
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
  FillRoundRect(hdc, menu, 16, RGB(8, 9, 14));
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

  HDC paint_hdc = CreateCompatibleDC(hdc);
  void *bits = nullptr;
  HBITMAP bitmap = Create32BitDIBSection(hdc, width, height, &bits);
  HBITMAP old_bitmap = static_cast<HBITMAP>(SelectObject(paint_hdc, bitmap));

  ZeroMemory(bits, width * height * 4);
  const RECT top = TopControlsRect(rect);
  const RECT bottom = BottomControlsRect(rect);
  const uint32_t bg_pixel = 0x33000000; // 20% opaque black
  uint32_t *pixels = static_cast<uint32_t *>(bits);
  for (int y = top.top; y < top.bottom; ++y) {
    uint32_t *row = pixels + y * width;
    for (int x = 0; x < width; ++x) {
      row[x] = bg_pixel;
    }
  }
  for (int y = bottom.top; y < bottom.bottom; ++y) {
    uint32_t *row = pixels + y * width;
    for (int x = 0; x < width; ++x) {
      row[x] = bg_pixel;
    }
  }

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

  // Top-right badges, stacked leftward: clock, LIVE, dynamic range, resolution,
  // fps, then source name.
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
  if (g_native_control_state.is_live) {
    // Red at the live edge; grey once behind (paired with the go-to-live button).
    const bool synced = g_native_control_state.live_synced;
    badge_right -= DrawBadge(
        paint_hdc, badge_right, top_cy, L"\x25CF LIVE",
        synced ? RGB(255, 64, 112) : RGB(74, 80, 94),
        synced ? RGB(255, 255, 255) : RGB(200, 205, 216));
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
  const std::wstring fps_badge = FormatFps(g_native_control_state.fps);
  if (!fps_badge.empty()) {
    badge_right -= DrawBadge(paint_hdc, badge_right, top_cy, fps_badge,
                             kNeutralBg, kNeutralFg);
  }
  if (!g_native_control_state.source_name.empty()) {
    badge_right -=
        DrawBadge(paint_hdc, badge_right, top_cy,
                  TruncateBadge(g_native_control_state.source_name, 22),
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
    DrawSlider(paint_hdc, l.progress,
               g_native_control_state.position_ms / duration, 6);
    DrawTextWithFont(paint_hdc, FormatTime(g_native_control_state.duration_ms),
                     l.duration_text,
                     DT_RIGHT | DT_VCENTER | DT_SINGLELINE, time_font,
                     RGB(184, 190, 204));
    DeleteObject(time_font);
  }

  if (l.has_epg) {
    const auto &s = g_native_control_state;
    HFONT epg_title_font = UiFont(17, FW_SEMIBOLD);
    DrawTextWithFont(paint_hdc, s.epg_now_title, l.epg_title,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                     epg_title_font, RGB(238, 240, 247));
    HFONT epg_meta_font = UiFont(16, FW_SEMIBOLD);
    const std::wstring range = FormatClockHm(s.epg_now_start_ms) + L" – " +
                               FormatClockHm(s.epg_now_stop_ms);
    DrawTextWithFont(paint_hdc, range, l.epg_time,
                     DT_RIGHT | DT_VCENTER | DT_SINGLELINE, epg_meta_font,
                     RGB(184, 190, 204));
    // Programme progress: a thin track + elapsed fill (no thumb).
    const double span = std::max(1.0, s.epg_now_stop_ms - s.epg_now_start_ms);
    const double prog = std::clamp(
        (static_cast<double>(NowMs()) - s.epg_now_start_ms) / span, 0.0, 1.0);
    const int ecy = (l.epg_progress.top + l.epg_progress.bottom) / 2;
    FillRoundRect(paint_hdc,
                  RectFrom(l.epg_progress.left, ecy - 3, l.epg_progress.right,
                           ecy + 3),
                  6, RGB(39, 43, 58));
    const int fill_x =
        l.epg_progress.left + static_cast<int>(RectWidth(l.epg_progress) * prog);
    FillRoundRect(paint_hdc,
                  RectFrom(l.epg_progress.left, ecy - 3, fill_x, ecy + 3), 6,
                  RGB(123, 108, 246));
    if (!s.epg_next_title.empty()) {
      const std::wstring next_range = FormatClockHm(s.epg_next_start_ms) + L" - " +
                                      FormatClockHm(s.epg_next_stop_ms);
      DrawTextWithFont(paint_hdc,
                       L"Next: " + s.epg_next_title + L" (" + next_range + L")",
                       l.epg_next,
                       DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                       epg_meta_font, RGB(184, 190, 204));
    }
    DeleteObject(epg_title_font);
    DeleteObject(epg_meta_font);
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
  if (l.has_go_live) {
    DrawTextButton(paint_hdc, l.go_live, L"LIVE",
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
  // Normalize top/bottom bar alpha to match the 20% backdrop used in Dart.
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
  }
  if (info_panel_rect.right > info_panel_rect.left &&
      info_panel_rect.bottom > info_panel_rect.top) {
    NormalizeNativeControlBitmapAlpha(pixels, width, height, info_panel_rect,
                                       RGB(10, 11, 16), 0xFF);
  }

  HDC screen_dc = GetDC(nullptr);
  SIZE size = {width, height};
  POINT pt_src = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  if (!UpdateLayeredWindow(hwnd, screen_dc, nullptr, &size, paint_hdc,
                           &pt_src, 0, &blend, ULW_ALPHA)) {
    BitBlt(hdc, 0, 0, width, height, paint_hdc, 0, 0, SRCCOPY);
  }
  ReleaseDC(nullptr, screen_dc);

  SelectObject(paint_hdc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(paint_hdc);
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
  return "show";
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
      PostMessage(parent, kNativeVideoSurfaceInputMessage, 0, 0);
      PostMessage(parent, message, wparam, lparam);
      return 0;
    }
    break;
  case WM_MOUSEMOVE:
    // Mouse interaction takes over from keyboard navigation, so hide the
    // keyboard focus ring until arrows/OK are used again.
    g_native_keyboard_focus_visible = false;
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
  case WM_LBUTTONDOWN: {
    g_native_keyboard_focus_visible = false;
    const int control_kind =
        static_cast<int>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    const std::string command = NativeControlCommandFromPoint(
        hwnd, control_kind, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
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
      PostMessage(parent, kNativeVideoSurfaceInputMessage, 0, 0);
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
            if (focusables[g_native_focus_index] == NativeFocusItem::kBack) {
              const int play_index = focus_index_of(NativeFocusItem::kPlay);
              if (play_index >= 0) g_native_focus_index = play_index;
            }
          } else {
            std::vector<int> bottom_indices;
            for (int i = 0; i < static_cast<int>(focusables.size()); ++i) {
              if (focusables[i] != NativeFocusItem::kBack) {
                bottom_indices.push_back(i);
              }
            }
            if (!bottom_indices.empty()) {
              if (focusables[g_native_focus_index] == NativeFocusItem::kBack) {
                g_native_focus_index = (wparam == VK_LEFT)
                    ? bottom_indices.back()
                    : bottom_indices.front();
              } else {
                int current_bottom_pos = 0;
                for (int i = 0; i < static_cast<int>(bottom_indices.size()); ++i) {
                  if (bottom_indices[i] == g_native_focus_index) {
                    current_bottom_pos = i;
                    break;
                  }
                }
                const int dir = (wparam == VK_LEFT) ? -1 : 1;
                const int count = static_cast<int>(bottom_indices.size());
                current_bottom_pos = (current_bottom_pos + dir + count) % count;
                g_native_focus_index = bottom_indices[current_bottom_pos];
              }
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
  }
  CreateNativeControls();
  return native_video_surface_;
}

void FlutterWindow::DestroyNativeVideoSurface() {
  if (native_video_surface_) {
    DestroyWindow(native_video_surface_);
    native_video_surface_ = nullptr;
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
  BringNativeControlsToFront();
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
  }
  ResizeNativeControls();
  native_controls_visible_ = false;
  ShowNativeControls(true);
  ScheduleNativeControlsHide();
}

void FlutterWindow::DestroyNativeControls() {
  KillTimer(GetHandle(), kNativeControlsHideTimer);
  if (native_controls_overlay_) {
    SetWindowRgn(native_controls_overlay_, nullptr, TRUE);
    DestroyWindow(native_controls_overlay_);
    native_controls_overlay_ = nullptr;
  }
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

void FlutterWindow::BringNativeControlsToFront() {
  if (!native_controls_visible_) {
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
  if (visibility_changed || currently_visible != visible ||
      native_controls_region_dirty_) {
    ApplyNativeControlsVisibility();
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
  const bool currently_visible =
      IsWindowVisible(native_controls_overlay_) != FALSE;
  if (currently_visible != native_controls_visible_) {
    ShowWindow(native_controls_overlay_,
               native_controls_visible_ ? SW_SHOWNOACTIVATE : SW_HIDE);
    if (native_controls_visible_) {
      BringNativeControlsToFront();
    }
  }
}

void FlutterWindow::InvalidateNativeControls(bool include_subtitles) {
  if (native_controls_visible_ && native_controls_overlay_) {
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

  native_controls_pinned_ =
      !g_native_control_state.playing || ControlsPinnedByOverlay();
  if (native_video_surface_) {
    if (!g_native_control_state.playing) {
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

void FlutterWindow::SetNativeWindowFullscreen(bool fullscreen) {
  HWND hwnd = GetHandle();
  if (!hwnd || native_window_fullscreen_ == fullscreen) {
    return;
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
          SetNativeWindowFullscreen(false);
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

        result->NotImplemented();
      });
}
