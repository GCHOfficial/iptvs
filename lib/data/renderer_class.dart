import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'diagnostics_log.dart';

/// Which Flutter renderer the Android engine was started with, and why.
///
/// The decision itself is taken in Kotlin, before the engine exists
/// (`player/RendererPolicy.kt`, applied by `MainActivity.getFlutterShellArgs`):
/// Impeller everywhere except a one-entry SoC denylist. This is only the read
/// back, so the exportable diagnostics log and the Sentry scope can say which
/// renderer a report came from — on a device where the renderer is the
/// suspect, an export that does not name it is an export that cannot answer
/// the question.
class RendererInfo {
  /// `impeller` or `skia-gl`.
  final String renderer;

  /// `default`, `manifest`, `forced-debug`, or `soc:<MODEL>`.
  final String reason;

  const RendererInfo({required this.renderer, required this.reason});

  @override
  String toString() => 'renderer=$renderer reason=$reason';
}

/// The same channel `isTelevision` and the proguard UUID are read over.
const MethodChannel _channel = MethodChannel('iptvs/device');

/// Bounded for the same reason `detectDeviceClass`'s timeout is: the native
/// side answers from a field set before the engine started, so this should be
/// unreachable — it exists so that being wrong about that costs a missing log
/// line rather than a hung boot step.
const Duration _detectTimeout = Duration(seconds: 2);

Future<RendererInfo?>? _pending;
RendererInfo? _resolved;

/// Overrides the resolved value for tests. Process-global by design; restore
/// it in a `tearDown`.
@visibleForTesting
void debugSetRenderer(RendererInfo? value) {
  _resolved = value;
  _pending = null;
}

/// The renderer this process is running, or null off Android / on any failure.
///
/// Memoized: both the diagnostics line and the crash reporter's scope tag want
/// it, and neither should pay a second platform round trip for it. Never
/// throws — an older build with no `renderer` method answers `notImplemented`,
/// which is an absent fact, not an error worth surfacing.
Future<RendererInfo?> detectRenderer() {
  if (_resolved != null) return Future.value(_resolved);
  return _pending ??= _detect();
}

Future<RendererInfo?> _detect() async {
  if (!Platform.isAndroid) return null;
  try {
    final reply = await _channel
        .invokeMapMethod<String, dynamic>('renderer')
        .timeout(_detectTimeout);
    final renderer = reply?['renderer'] as String?;
    final reason = reply?['reason'] as String?;
    if (renderer == null || renderer.isEmpty) return null;
    final info = RendererInfo(renderer: renderer, reason: reason ?? 'unknown');
    _resolved = info;
    return info;
  } catch (_) {
    return null;
  }
}

/// Writes the one startup line the exportable log carries about the renderer.
///
/// Called **un-awaited** from `main`: nothing on the first-frame path depends
/// on it, and the decision it reports was already applied before the Dart
/// isolate existed. Android only — no other platform has a renderer choice to
/// report.
Future<void> reportRenderer() async {
  final info = await detectRenderer();
  if (info == null) return;
  DiagnosticsLog.instance.addAndPrint('library', info.toString());
}
