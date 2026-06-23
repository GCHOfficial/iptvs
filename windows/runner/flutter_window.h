#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject &project);
  virtual ~FlutterWindow();

protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

private:
  HWND CreateNativeVideoSurface();
  void DestroyNativeVideoSurface();
  void ResizeNativeVideoSurface();
  void SetNativeVideoSurfaceInsets(int top, int bottom);
  void CreateNativeControls();
  void DestroyNativeControls();
  void RecreateNativeControls();
  void ResizeNativeControls();
  void UpdateNativeControlsRegion();
  void BringNativeControlsToFront();
  void ShowNativeControls(bool visible);
  void ApplyNativeControlsVisibility();
  void InvalidateNativeControls(bool include_subtitles = true);
  void ScheduleNativeControlsHide();
  bool IsCursorOverNativeControls() const;
  void NotifyNativeControlCommand(const std::string &command);
  void UpdateNativeControlState(const flutter::EncodableValue *args);
  void SetNativeWindowFullscreen(bool fullscreen);
  void RegisterNativeHdrPlayerChannel();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      native_hdr_channel_;

  // Native child HWND used by mpv for Windows HDR playback.
  HWND native_video_surface_ = nullptr;
  HWND native_controls_overlay_ = nullptr;
  int native_video_surface_top_inset_ = 0;
  int native_video_surface_bottom_inset_ = 0;
  bool native_controls_visible_ = true;
  bool native_controls_region_dirty_ = true;
  bool native_controls_pinned_ = false;
  ULONGLONG native_ignore_input_until_ = 0;
  bool native_window_fullscreen_ = false;
  WINDOWPLACEMENT native_windowed_placement_ = {};
  LONG_PTR native_windowed_style_ = 0;
  LONG_PTR native_windowed_ex_style_ = 0;
};

#endif // RUNNER_FLUTTER_WINDOW_H_
