package com.gchofficial.iptvs.player

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration

/**
 * Whether this device is a **television**.
 *
 * One implementation for the whole app, because the two callers must not
 * disagree: `MainActivity` answers the `iptvs/device` channel (which decides
 * the browsing layout — a TV is the wide two-pane UI whatever logical width its
 * density reports, see Dart `isWideLayout`) and `HdrPlayerActivity` picks its
 * ten-foot player chrome from it. They were separate copies, and widening only
 * one produced exactly the split it looks like: a set-top box that got the
 * two-pane channel list and handset-sized player controls.
 *
 * Asked two ways, because one is not enough. [UiModeManager] is the official
 * answer and what a well-behaved Android TV device reports, but set-top boxes
 * routinely ship a build that answers `UI_MODE_TYPE_NORMAL` while being a
 * television in every way that matters. Those are caught by the leanback /
 * television system features, which a device cannot claim without shipping the
 * TV stack — so neither signal fires on a handset.
 */
fun isTelevisionDevice(context: Context): Boolean {
    val uiModeManager =
        context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
    if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
        return true
    }
    val packages = context.packageManager
    return packages.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
        packages.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
}
