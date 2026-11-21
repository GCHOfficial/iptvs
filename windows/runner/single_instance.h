#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// One running iptvs per Windows session.
//
// Two processes opened the same SQLite file and the same image-cache index
// (Sentry IPTVS-F/P/Q/R: "database is locked" while setting WAL and on
// BEGIN IMMEDIATE at boot, then the cache index rename failing because
// "another process" held it, one second apart). Nothing stopped a second
// launch, so the guard lives here, before the Flutter engine starts.
//
// Two constraints shape it:
//
//  * **The in-app updater relaunches the app**, and must win. Its helper
//    `Wait-Process`es the old PID (up to 60 s) before swapping folders and
//    starting the new exe, so normally the old process is long gone — but a
//    slow exit can outlast that, and the old window can linger while the
//    process tears down. So a second process that finds no *responsive*
//    window keeps waiting for the mutex instead of giving up, and takes over
//    as soon as the old process releases it (an exit, clean or not, releases
//    a mutex — `WAIT_ABANDONED` counts as acquired).
//  * **A second launch must bring the existing window to the front**, then
//    exit. It exits with code 0: the updater treats a relaunched process that
//    exits non-zero within 5 s as a failed update and rolls back.
namespace single_instance {

enum class Outcome {
  // This process owns the instance; start the app.
  kPrimary,
  // Another instance is running and was brought to the front; exit(0).
  kHandedOff,
};

// Claims the instance, waiting for a departing one. Never fails closed: if the
// mutex cannot be created at all, the app starts (an unguarded launch is the
// pre-guard behaviour, not a worse one).
Outcome Claim();

// Tags [window] as the primary instance's main window, so a later launch can
// find it among every other Flutter app's identically-classed windows.
void MarkMainWindow(HWND window);

// Removes the tag; called while the window is being destroyed.
void UnmarkMainWindow(HWND window);

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
