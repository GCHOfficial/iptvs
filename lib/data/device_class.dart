import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'diagnostics_log.dart';

/// Whether this device is a **television** (Android leanback / `UI_MODE_TYPE_
/// TELEVISION`), as opposed to a phone, tablet or desktop.
///
/// Read synchronously by layout decisions, so it is resolved once during boot
/// ([detectDeviceClass]) rather than awaited per build. It cannot change for
/// the life of the process: a TV does not become a phone.
bool get isTelevision => _isTelevision;
bool _isTelevision = false;

/// Overrides the detected value for tests. Restore it in a `tearDown` — this is
/// process-global by design, so a leaked `true` makes every later widget test
/// silently render the ten-foot layout.
@visibleForTesting
set debugIsTelevision(bool value) => _isTelevision = value;

/// Resolves [isTelevision] from the platform. Call once, before the first
/// frame; safe to call again (idempotent).
///
/// Fails **closed to `false`**: an unanswered channel (a platform with no
/// handler, a test binding, an engine still starting) leaves the ordinary
/// width-based layout rules in charge, which is the behaviour every non-TV
/// device wants anyway.
///
/// Bounded, because this is awaited **before `runApp`** — a platform call that
/// never answers there is not a degraded layout, it is an app that never
/// starts. The native side is a synchronous property read, so the timeout
/// should be unreachable; it exists so that being wrong about that costs a
/// phone layout instead of a boot.
const Duration _detectTimeout = Duration(seconds: 2);

Future<void> detectDeviceClass() async {
  if (!Platform.isAndroid) return;
  try {
    // The same channel and method the pairing screen's device label uses
    // (`device_label.dart`). Kept as a separate call rather than shared state
    // because the two run at different times for different reasons — this one
    // must settle before the first frame, that one at pairing — and the native
    // answer is a cheap, constant property.
    final tv = await const MethodChannel(
      'iptvs/device',
    ).invokeMethod<bool>('isTelevision').timeout(_detectTimeout);
    _isTelevision = tv ?? false;
  } catch (error) {
    _isTelevision = false;
    DiagnosticsLog.instance.addAndPrint(
      'library',
      'device class unavailable: ${error.runtimeType}',
    );
    return;
  }
  DiagnosticsLog.instance.addAndPrint(
    'library',
    'device class television=$isTelevision',
  );
}
