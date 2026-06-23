#include "flutter_window.h"

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

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
constexpr int kNativeTopControlsHeight = 58;
constexpr int kNativeBottomControlsHeight = 96;
constexpr int kNativeSubtitleMenuWidth = 286;
constexpr int kNativeSubtitleMenuHeaderHeight = 36;
constexpr int kNativeSubtitleMenuRowHeight = 40;
constexpr int kNativeSubtitleMenuMaxRows = 5;
constexpr int kNativeSubtitleMenuPadding = 10;
constexpr int kNativeControlsKindOverlay = 0;
bool g_native_video_cursor_visible = true;
POINT g_last_video_mouse{-1, -1};
POINT g_last_controls_mouse{-1, -1};
int g_native_subtitle_scroll_offset = 0;

HWND NativeControlsOwner(HWND hwnd) {
  if (HWND owner = GetWindow(hwnd, GW_OWNER)) {
    return owner;
  }
  return GetParent(hwnd);
}

struct NativeSubtitleOption {
  std::string id;
  std::wstring label;
};

struct NativeControlState {
  std::wstring title;
  bool is_live = false;
  bool playing = false;
  bool fullscreen = false;
  bool subtitles_open = false;
  double position_ms = 0.0;
  double duration_ms = 0.0;
  double volume = 100.0;
  std::string selected_subtitle_id = "auto";
  std::vector<NativeSubtitleOption> subtitles;
};

NativeControlState g_native_control_state;

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

HFONT UiFont(int size, int weight = FW_NORMAL,
             const wchar_t *family = L"Segoe UI") {
  return CreateFont(size, 0, 0, 0, weight, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                    OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                    DEFAULT_PITCH | FF_SWISS, family);
}

void FillRectColor(HDC hdc, const RECT &rect, COLORREF color) {
  HBRUSH brush = CreateSolidBrush(color);
  FillRect(hdc, &rect, brush);
  DeleteObject(brush);
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

void DrawTextButton(HDC hdc, const RECT &rect, const std::wstring &label) {
  FillRoundRect(hdc, rect, 12, RGB(18, 20, 28));
  HFONT font = UiFont(13, FW_SEMIBOLD);
  DrawTextWithFont(hdc, label, rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE,
                   font, RGB(232, 235, 244));
  DeleteObject(font);
}

RECT PlaybackProgressRect(const RECT &rect) {
  return RectFrom(244, 43, MaxInt(260, static_cast<int>(rect.right) - 386), 51);
}

RECT VolumeProgressRect(const RECT &rect) {
  return RectFrom(MaxInt(0, static_cast<int>(rect.right) - 162), 43,
                  MaxInt(0, static_cast<int>(rect.right) - 88), 51);
}

double RatioFromX(int x, const RECT &rect) {
  return std::clamp(static_cast<double>(x - rect.left) /
                        static_cast<double>(std::max(1, RectWidth(rect))),
                    0.0, 1.0);
}

RECT TopControlsRect(const RECT &rect) {
  return RectFrom(0, 0, rect.right, kNativeTopControlsHeight);
}

RECT BottomControlsRect(const RECT &rect) {
  return RectFrom(0, MaxInt(0, rect.bottom - kNativeBottomControlsHeight),
                  rect.right, rect.bottom);
}

RECT SubtitleMenuRect(const RECT &rect) {
  const int width = RectWidth(rect);
  const int height = RectHeight(rect);
  const int menu_width =
      std::min(kNativeSubtitleMenuWidth, MaxInt(1, width - 24));
  const int menu_height =
      kNativeSubtitleMenuHeaderHeight +
      std::clamp(
          static_cast<int>(g_native_control_state.subtitles.empty()
                               ? 1
                               : g_native_control_state.subtitles.size()),
          1, kNativeSubtitleMenuMaxRows) *
          kNativeSubtitleMenuRowHeight +
      kNativeSubtitleMenuPadding;
  const int subtitle_button_center_x = width - 254;
  const int menu_left = std::clamp(subtitle_button_center_x - (menu_width / 2),
                                   12, MaxInt(12, width - menu_width - 12));
  const int menu_top =
      MaxInt(8, height - kNativeBottomControlsHeight - menu_height - 8);
  return RectFrom(menu_left, menu_top, menu_left + menu_width,
                  menu_top + menu_height);
}

RECT OffsetRectToLocal(RECT rect, int dx, int dy) {
  rect.left -= dx;
  rect.right -= dx;
  rect.top -= dy;
  rect.bottom -= dy;
  return rect;
}

int SubtitleVisibleRowCount() {
  if (g_native_control_state.subtitles.empty()) {
    return 1;
  }
  return std::clamp(static_cast<int>(g_native_control_state.subtitles.size()),
                    1, kNativeSubtitleMenuMaxRows);
}

int SubtitleMenuHeight() {
  return kNativeSubtitleMenuHeaderHeight +
         SubtitleVisibleRowCount() * kNativeSubtitleMenuRowHeight +
         kNativeSubtitleMenuPadding;
}

int MaxSubtitleScrollOffset() {
  return MaxInt(0, static_cast<int>(g_native_control_state.subtitles.size()) -
                       kNativeSubtitleMenuMaxRows);
}

void ClampSubtitleScrollOffset() {
  g_native_subtitle_scroll_offset =
      std::clamp(g_native_subtitle_scroll_offset, 0, MaxSubtitleScrollOffset());
}

void EnsureSelectedSubtitleVisible() {
  int selected = -1;
  for (size_t i = 0; i < g_native_control_state.subtitles.size(); i++) {
    if (g_native_control_state.subtitles[i].id ==
        g_native_control_state.selected_subtitle_id) {
      selected = static_cast<int>(i);
      break;
    }
  }
  if (selected < 0) {
    ClampSubtitleScrollOffset();
    return;
  }
  if (selected < g_native_subtitle_scroll_offset) {
    g_native_subtitle_scroll_offset = selected;
  } else if (selected >=
             g_native_subtitle_scroll_offset + kNativeSubtitleMenuMaxRows) {
    g_native_subtitle_scroll_offset = selected - kNativeSubtitleMenuMaxRows + 1;
  }
  ClampSubtitleScrollOffset();
}

std::vector<RECT> SubtitleOptionRects(const RECT &rect) {
  std::vector<RECT> out;
  const int visible_rows = SubtitleVisibleRowCount();
  const int left = 10;
  const int right = rect.right - 10;
  int top = kNativeSubtitleMenuHeaderHeight;
  for (int i = 0; i < visible_rows; i++) {
    out.push_back(
        RectFrom(left, top, right, top + kNativeSubtitleMenuRowHeight - 4));
    top += kNativeSubtitleMenuRowHeight;
  }
  return out;
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
  HBITMAP bitmap = CreateCompatibleBitmap(hdc, width, height);
  HBITMAP old_bitmap = static_cast<HBITMAP>(SelectObject(paint_hdc, bitmap));

  FillRectColor(paint_hdc, rect, RGB(3, 4, 7));
  SetBkMode(paint_hdc, TRANSPARENT);

  const RECT top = TopControlsRect(rect);
  DrawIconButton(paint_hdc, RectFrom(16, top.top + 10, 54, top.top + 48),
                 L"\xE72B");
  HFONT title_font = UiFont(18, FW_SEMIBOLD);
  DrawTextWithFont(paint_hdc, g_native_control_state.title,
                   RectFrom(66, top.top, rect.right - 112, top.bottom),
                   DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                   title_font, RGB(246, 247, 251));
  DeleteObject(title_font);
  if (g_native_control_state.is_live) {
    RECT live{rect.right - 82, top.top + 18, rect.right - 22, top.top + 40};
    FillRoundRect(paint_hdc, live, 7, RGB(255, 64, 112));
    HFONT badge_font = UiFont(11, FW_BOLD);
    DrawTextWithFont(paint_hdc, L"\x25CF LIVE", live,
                     DT_CENTER | DT_VCENTER | DT_SINGLELINE, badge_font,
                     RGB(255, 255, 255));
    DeleteObject(badge_font);
  }

  const RECT bottom = BottomControlsRect(rect);
  const int bottom_y = bottom.top;
  const int center_y = bottom_y + 47;
  DrawIconButton(paint_hdc, RectFrom(18, bottom_y + 24, 58, bottom_y + 64),
                 g_native_control_state.playing ? L"\xE769" : L"\xE768", true);
  int content_left = 72;
  if (!g_native_control_state.is_live) {
    DrawTextButton(paint_hdc, RectFrom(68, bottom_y + 27, 112, bottom_y + 61),
                   L"-10");
    DrawTextButton(paint_hdc, RectFrom(118, bottom_y + 27, 162, bottom_y + 61),
                   L"+10");
    content_left = 178;
  }

  if (g_native_control_state.is_live) {
    RECT live{content_left, center_y - 12, content_left + 64, center_y + 12};
    FillRoundRect(paint_hdc, live, 7, RGB(255, 64, 112));
    HFONT badge_font = UiFont(11, FW_BOLD);
    DrawTextWithFont(paint_hdc, L"\x25CF LIVE", live,
                     DT_CENTER | DT_VCENTER | DT_SINGLELINE, badge_font,
                     RGB(255, 255, 255));
    DeleteObject(badge_font);
  } else {
    HFONT time_font = UiFont(13, FW_SEMIBOLD);
    DrawTextWithFont(
        paint_hdc, FormatTime(g_native_control_state.position_ms),
        RectFrom(content_left, bottom_y + 32, content_left + 58, bottom_y + 62),
        DT_RIGHT | DT_VCENTER | DT_SINGLELINE, time_font, RGB(184, 190, 204));
    const RECT local_bar = PlaybackProgressRect(
        RectFrom(0, 0, rect.right, kNativeBottomControlsHeight));
    const RECT bar = RectFrom(local_bar.left, bottom_y + local_bar.top,
                              local_bar.right, bottom_y + local_bar.bottom);
    FillRoundRect(paint_hdc,
                  RectFrom(bar.left, center_y - 3, bar.right, center_y + 3), 6,
                  RGB(39, 43, 58));
    const double duration = std::max(1.0, g_native_control_state.duration_ms);
    const double ratio =
        std::clamp(g_native_control_state.position_ms / duration, 0.0, 1.0);
    const int thumb_x = bar.left + static_cast<int>(RectWidth(bar) * ratio);
    FillRoundRect(paint_hdc,
                  RectFrom(bar.left, center_y - 3, thumb_x, center_y + 3), 6,
                  RGB(123, 108, 246));
    FillRoundRect(
        paint_hdc,
        RectFrom(thumb_x - 6, center_y - 6, thumb_x + 6, center_y + 6), 12,
        RGB(154, 141, 255));
    DrawTextWithFont(
        paint_hdc, FormatTime(g_native_control_state.duration_ms),
        RectFrom(bar.right + 14, bottom_y + 32, bar.right + 72, bottom_y + 62),
        DT_LEFT | DT_VCENTER | DT_SINGLELINE, time_font, RGB(184, 190, 204));
    DeleteObject(time_font);
  }

  const RECT local_volume = VolumeProgressRect(
      RectFrom(0, 0, rect.right, kNativeBottomControlsHeight));
  const RECT volume_bar =
      RectFrom(local_volume.left, bottom_y + local_volume.top,
               local_volume.right, bottom_y + local_volume.bottom);
  DrawIconButton(paint_hdc,
                 RectFrom(rect.right - 220, bottom_y + 27, rect.right - 184,
                          bottom_y + 63),
                 g_native_control_state.volume <= 0 ? L"\xE74F" : L"\xE767");
  FillRoundRect(
      paint_hdc,
      RectFrom(volume_bar.left, center_y - 3, volume_bar.right, center_y + 3),
      6, RGB(39, 43, 58));
  const double volume_ratio =
      std::clamp(g_native_control_state.volume / 100.0, 0.0, 1.0);
  const int volume_x =
      volume_bar.left + static_cast<int>(RectWidth(volume_bar) * volume_ratio);
  FillRoundRect(paint_hdc,
                RectFrom(volume_bar.left, center_y - 3, volume_x, center_y + 3),
                6, RGB(123, 108, 246));
  FillRoundRect(
      paint_hdc,
      RectFrom(volume_x - 5, center_y - 5, volume_x + 5, center_y + 5), 10,
      RGB(154, 141, 255));

  DrawIconButton(paint_hdc,
                 RectFrom(rect.right - 272, bottom_y + 27, rect.right - 236,
                          bottom_y + 63),
                 L"\xE190", g_native_control_state.subtitles_open);
  DrawIconButton(
      paint_hdc,
      RectFrom(rect.right - 54, bottom_y + 27, rect.right - 18, bottom_y + 63),
      g_native_control_state.fullscreen ? L"\xE73F" : L"\xE740");

  if (g_native_control_state.subtitles_open) {
    const RECT menu = SubtitleMenuRect(rect);
    const RECT menu_local = OffsetRectToLocal(menu, menu.left, menu.top);
    FillRoundRect(paint_hdc, menu, 16, RGB(8, 9, 14));
    HFONT label_font = UiFont(13, FW_SEMIBOLD);
    DrawTextWithFont(
        paint_hdc, L"Subtitles",
        RectFrom(menu.left + 16, menu.top + 4, menu.right - 16, menu.top + 32),
        DT_LEFT | DT_VCENTER | DT_SINGLELINE, label_font, RGB(154, 161, 178));
    const auto option_rects = SubtitleOptionRects(menu_local);
    if (g_native_control_state.subtitles.empty()) {
      DrawTextWithFont(
          paint_hdc, L"No subtitles available",
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
            g_native_subtitle_scroll_offset + static_cast<int>(i);
        if (option_index >=
            static_cast<int>(g_native_control_state.subtitles.size())) {
          break;
        }
        const auto &option = g_native_control_state.subtitles[option_index];
        const bool active =
            option.id == g_native_control_state.selected_subtitle_id;
        const RECT option_rect = RectFrom(menu.left + option_rects[i].left,
                                          menu.top + option_rects[i].top,
                                          menu.left + option_rects[i].right,
                                          menu.top + option_rects[i].bottom);
        FillRoundRect(paint_hdc, option_rect, 12,
                      active ? RGB(123, 108, 246) : RGB(26, 29, 40));
        DrawTextWithFont(paint_hdc, option.label,
                         RectFrom(option_rect.left + 12, option_rect.top,
                                  option_rect.right - 12, option_rect.bottom),
                         DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS,
                         label_font,
                         active ? RGB(255, 255, 255) : RGB(218, 222, 233));
      }
      if (MaxSubtitleScrollOffset() > 0) {
        const int track_top = menu.top + kNativeSubtitleMenuHeaderHeight;
        const int track_bottom = menu.bottom - kNativeSubtitleMenuPadding;
        FillRoundRect(
            paint_hdc,
            RectFrom(menu.right - 6, track_top, menu.right - 3, track_bottom),
            4, RGB(39, 43, 58));
        const double visible_ratio =
            static_cast<double>(SubtitleVisibleRowCount()) /
            static_cast<double>(g_native_control_state.subtitles.size());
        const int thumb_height = MaxInt(
            24, static_cast<int>((track_bottom - track_top) * visible_ratio));
        const double scroll_ratio =
            static_cast<double>(g_native_subtitle_scroll_offset) /
            static_cast<double>(MaxSubtitleScrollOffset());
        const int thumb_top =
            track_top +
            static_cast<int>((track_bottom - track_top - thumb_height) *
                             scroll_ratio);
        FillRoundRect(paint_hdc,
                      RectFrom(menu.right - 7, thumb_top, menu.right - 2,
                               thumb_top + thumb_height),
                      5, RGB(123, 108, 246));
      }
    }
    DeleteObject(label_font);
  }

  BitBlt(hdc, 0, 0, width, height, paint_hdc, 0, 0, SRCCOPY);
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
  const RECT bottom = BottomControlsRect(rect);
  if (PointInRect(x, y, top)) {
    if (PointInRect(x, y, RectFrom(8, 4, 64, 56))) {
      return "back";
    }
    return "show";
  }

  if (g_native_control_state.subtitles_open) {
    const RECT menu = SubtitleMenuRect(rect);
    if (PointInRect(x, y, menu)) {
      const RECT menu_local = OffsetRectToLocal(menu, menu.left, menu.top);
      const auto option_rects = SubtitleOptionRects(menu_local);
      for (size_t i = 0; i < option_rects.size(); i++) {
        const RECT option_rect = RectFrom(menu.left + option_rects[i].left,
                                          menu.top + option_rects[i].top,
                                          menu.left + option_rects[i].right,
                                          menu.top + option_rects[i].bottom);
        if (PointInRect(x, y, option_rect)) {
          const int option_index =
              g_native_subtitle_scroll_offset + static_cast<int>(i);
          if (option_index >= 0 &&
              option_index <
                  static_cast<int>(g_native_control_state.subtitles.size())) {
            return "subtitleTrack:" +
                   g_native_control_state.subtitles[option_index].id;
          }
        }
      }
      return "show";
    }
  }

  if (!PointInRect(x, y, bottom)) {
    return "show";
  }
  const int bottom_y = bottom.top;
  if (PointInRect(x, y, RectFrom(10, bottom_y + 18, 66, bottom_y + 72))) {
    return "playPause";
  }
  if (!g_native_control_state.is_live) {
    if (PointInRect(x, y, RectFrom(64, bottom_y + 22, 116, bottom_y + 68))) {
      return "seekBack";
    }
    if (PointInRect(x, y, RectFrom(114, bottom_y + 22, 166, bottom_y + 68))) {
      return "seekForward";
    }
    const RECT local_progress = PlaybackProgressRect(
        RectFrom(0, 0, rect.right, kNativeBottomControlsHeight));
    const RECT progress =
        RectFrom(local_progress.left, bottom_y + local_progress.top,
                 local_progress.right, bottom_y + local_progress.bottom);
    if (PointInRect(x, y,
                    RectFrom(progress.left, progress.top - 14, progress.right,
                             progress.bottom + 14))) {
      return "seekPercent:" + std::to_string(RatioFromX(x, progress));
    }
  }
  if (PointInRect(x, y,
                  RectFrom(rect.right - 226, bottom_y + 22, rect.right - 178,
                           bottom_y + 68))) {
    return "muteToggle";
  }
  const RECT local_volume = VolumeProgressRect(
      RectFrom(0, 0, rect.right, kNativeBottomControlsHeight));
  const RECT volume =
      RectFrom(local_volume.left, bottom_y + local_volume.top,
               local_volume.right, bottom_y + local_volume.bottom);
  if (PointInRect(x, y,
                  RectFrom(volume.left, volume.top - 14, volume.right,
                           volume.bottom + 14))) {
    return "volumePercent:" + std::to_string(RatioFromX(x, volume));
  }
  if (PointInRect(x, y,
                  RectFrom(rect.right - 278, bottom_y + 22, rect.right - 230,
                           bottom_y + 68))) {
    return "subtitles";
  }
  if (PointInRect(x, y,
                  RectFrom(rect.right - 64, bottom_y + 22, rect.right - 8,
                           bottom_y + 68))) {
    return "fullscreen";
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
  case WM_MOUSEMOVE:
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
    const int control_kind =
        static_cast<int>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    const std::string command = NativeControlCommandFromPoint(
        hwnd, control_kind, GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam));
    if (command == "subtitles") {
      g_native_control_state.subtitles_open =
          !g_native_control_state.subtitles_open;
      if (g_native_control_state.subtitles_open) {
        EnsureSelectedSubtitleVisible();
      }
      if (HWND parent = NativeControlsOwner(hwnd)) {
        KillTimer(parent, kNativeControlsHideTimer);
        PostMessage(parent, kNativeControlsLayoutMessage, 0, 0);
      }
      InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    }
    if (command.rfind("subtitleTrack:", 0) == 0) {
      g_native_control_state.subtitles_open = false;
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
    if (!g_native_control_state.subtitles_open ||
        !PointInRect(point.x, point.y, SubtitleMenuRect(rect)) ||
        MaxSubtitleScrollOffset() <= 0) {
      break;
    }
    const int delta = GET_WHEEL_DELTA_WPARAM(wparam);
    g_native_subtitle_scroll_offset += delta > 0 ? -1 : 1;
    ClampSubtitleScrollOffset();
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
  window_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  window_class.lpfnWndProc = NativeControlsWndProc;
  RegisterClass(&window_class);
  registered = true;
}

} // namespace

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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
      if (g_native_control_state.subtitles_open) {
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
    if (!g_native_control_state.subtitles_open) {
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
    if (flutter_controller_ && flutter_controller_->view()) {
      SetFocus(flutter_controller_->view()->GetNativeWindow());
    }
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
        CreateWindowEx(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
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
  if (g_native_control_state.subtitles_open) {
    ClampSubtitleScrollOffset();
    const RECT menu = SubtitleMenuRect(rect);
    HRGN menu_region = CreateRoundRectRgn(menu.left, menu.top, menu.right,
                                          menu.bottom, 16, 16);
    CombineRgn(region, region, menu_region, RGN_OR);
    DeleteObject(menu_region);
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
         (g_native_control_state.subtitles_open &&
          PointInRect(point.x, point.y, SubtitleMenuRect(client)));
}

void FlutterWindow::ShowNativeControls(bool visible) {
  const bool visibility_changed = native_controls_visible_ != visible;
  native_controls_visible_ = visible;
  if (!visible) {
    native_ignore_input_until_ = GetTickCount64() + 650;
    if (g_native_control_state.subtitles_open) {
      g_native_control_state.subtitles_open = false;
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
  if (g_native_control_state.playing &&
      !g_native_control_state.subtitles_open) {
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
  g_native_control_state.title =
      EncodableStringArg(args, "title", g_native_control_state.title);
  g_native_control_state.is_live =
      EncodableBoolArg(args, "isLive", g_native_control_state.is_live);
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
  if (args && std::holds_alternative<flutter::EncodableMap>(*args)) {
    const auto &map = std::get<flutter::EncodableMap>(*args);
    const auto found = map.find(flutter::EncodableValue("subtitles"));
    if (found != map.end() &&
        std::holds_alternative<flutter::EncodableList>(found->second)) {
      g_native_control_state.subtitles.clear();
      const auto &list = std::get<flutter::EncodableList>(found->second);
      for (const auto &item : list) {
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
        g_native_control_state.subtitles.push_back(NativeSubtitleOption{
            std::get<std::string>(id->second),
            Utf8ToWide(std::get<std::string>(label->second)),
        });
      }
      if (g_native_control_state.subtitles_open) {
        native_controls_region_dirty_ = true;
      }
      if (g_native_control_state.subtitles.empty()) {
        if (g_native_control_state.subtitles_open) {
          g_native_control_state.subtitles_open = false;
          native_controls_region_dirty_ = true;
        }
        ApplyNativeControlsVisibility();
      }
    }
  }
  native_controls_pinned_ =
      !g_native_control_state.playing || g_native_control_state.subtitles_open;
  if (native_video_surface_) {
    if (!g_native_control_state.playing) {
      KillTimer(GetHandle(), kNativeControlsHideTimer);
      ShowNativeControls(true);
    } else if (g_native_control_state.subtitles_open) {
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
