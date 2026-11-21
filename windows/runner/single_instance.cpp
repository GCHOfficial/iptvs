#include "single_instance.h"

namespace single_instance {
namespace {

// Session-local (`Local\`): one instance per signed-in user, which is the
// scope of the files the guard protects (`%APPDATA%\GCHOfficial\iptvs`).
constexpr wchar_t kMutexName[] = L"Local\\GCHOfficial.iptvs.SingleInstance";

// The tag on the primary's main window. The window class is Flutter's stock
// `FLUTTER_RUNNER_WIN32_WINDOW`, shared with every other Flutter desktop app,
// so the class alone would find the wrong window.
constexpr wchar_t kMainWindowProp[] = L"GCHOfficial.iptvs.MainWindow";

// How often a waiting launch re-checks for a window to hand off to.
constexpr DWORD kPollMs = 250;

// A window that does not answer a no-op message in this long is treated as
// absent: it belongs to a process that is exiting or hung, and handing off to
// it would leave the user with no app at all — which, on an updater relaunch,
// is an update that "succeeded" with nothing running.
constexpr UINT kResponsiveTimeoutMs = 1000;

// The longest a launch waits with neither the mutex nor a window to hand off
// to. Above the updater helper's 60 s `Wait-Process`, so a relaunch outlasts
// a slow exit. Past it the launch starts anyway (fail open): the holder has
// no responsive window, so it is not an app the user can reach.
constexpr ULONGLONG kMaxWaitMs = 90 * 1000;

// Held for the process lifetime and released by the OS at exit — including a
// crash, which the next launch sees as WAIT_ABANDONED.
HANDLE g_mutex = nullptr;

BOOL CALLBACK FindMarkedWindow(HWND window, LPARAM out) {
  if (::GetPropW(window, kMainWindowProp) == nullptr) {
    return TRUE;
  }
  DWORD pid = 0;
  ::GetWindowThreadProcessId(window, &pid);
  if (pid == ::GetCurrentProcessId()) {
    return TRUE;
  }
  *reinterpret_cast<HWND*>(out) = window;
  return FALSE;
}

HWND FindResponsivePrimaryWindow() {
  HWND found = nullptr;
  ::EnumWindows(FindMarkedWindow, reinterpret_cast<LPARAM>(&found));
  if (found == nullptr) {
    return nullptr;
  }
  DWORD_PTR ignored = 0;
  if (::SendMessageTimeoutW(found, WM_NULL, 0, 0,
                            SMTO_ABORTIFHUNG | SMTO_BLOCK,
                            kResponsiveTimeoutMs, &ignored) == 0) {
    return nullptr;
  }
  return found;
}

void BringToFront(HWND window) {
  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
  // Allowed: this process was just launched by the user, so it holds the
  // foreground right it is passing on.
  ::SetForegroundWindow(window);
}

}  // namespace

Outcome Claim() {
  g_mutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (g_mutex == nullptr) {
    return Outcome::kPrimary;
  }
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    // Created it, and with it initial ownership.
    return Outcome::kPrimary;
  }

  const ULONGLONG deadline = ::GetTickCount64() + kMaxWaitMs;
  for (;;) {
    const DWORD wait = ::WaitForSingleObject(g_mutex, kPollMs);
    if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
      // The previous instance has exited (or died): take over. This is the
      // updater's path.
      return Outcome::kPrimary;
    }
    if (wait == WAIT_FAILED) {
      return Outcome::kPrimary;
    }
    if (HWND window = FindResponsivePrimaryWindow()) {
      BringToFront(window);
      return Outcome::kHandedOff;
    }
    // No window yet: the primary is still starting (it creates its window
    // after taking the mutex) or is on its way out. Keep waiting.
    if (::GetTickCount64() >= deadline) {
      return Outcome::kPrimary;
    }
  }
}

void MarkMainWindow(HWND window) {
  if (window != nullptr) {
    ::SetPropW(window, kMainWindowProp, reinterpret_cast<HANDLE>(1));
  }
}

void UnmarkMainWindow(HWND window) {
  if (window != nullptr) {
    ::RemovePropW(window, kMainWindowProp);
  }
}

}  // namespace single_instance
