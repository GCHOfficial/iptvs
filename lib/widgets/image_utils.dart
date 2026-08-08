import 'package:flutter/widgets.dart';

import '../data/diagnostics_log.dart';
import '../data/net.dart';

/// How long one logged image failure suppresses the next. Settable so tests can
/// reach the throttle's release path without sleeping through the real window.
@visibleForTesting
Duration debugImageFailureLogWindow = const Duration(seconds: 10);
DateTime? _lastImageFailureLog;
int _suppressedImageFailures = 0;

/// Records a failed network-image fetch in the diagnostics log.
///
/// Image failures are otherwise **completely invisible**: every call site
/// deliberately renders the same widget for `placeholder` and `errorWidget`
/// (an artwork grid that flickers between two different fallbacks looks
/// broken), so a screen full of fallback tiles is indistinguishable from one
/// still loading. That ambiguity is what left a real "no artwork at all until
/// the app is restarted" report undiagnosable from an exported log — the
/// library, EPG and titles all came from SQLite and looked healthy, and
/// nothing anywhere recorded that every image fetch had failed.
///
/// Deliberately bounded. Failures arrive per tile, so a systemic outage would
/// otherwise flood the 800-entry ring buffer and evict the very context that
/// explains it. The first failure in a window is logged in full and the rest
/// are counted and reported with the next one.
void logImageFailure(Object error, String url) {
  final now = DateTime.now();
  final last = _lastImageFailureLog;
  if (last != null && now.difference(last) < debugImageFailureLogWindow) {
    _suppressedImageFailures++;
    return;
  }
  _lastImageFailureLog = now;
  final suppressed = _suppressedImageFailures;
  _suppressedImageFailures = 0;
  // Channel logos and catch-up artwork can come straight off the provider, so
  // these URLs are not all public CDN links — redact like any other.
  DiagnosticsLog.instance.add(
    'image',
    'fetch failed url=${redactUrl(url)} error=$error'
    '${suppressed > 0 ? ' (+$suppressed suppressed)' : ''}',
  );
}

/// Resets the failure-log throttle and its window. Tests only — the counters
/// are top-level, so they leak between cases otherwise.
@visibleForTesting
void debugResetImageFailureLog() {
  _lastImageFailureLog = null;
  _suppressedImageFailures = 0;
  debugImageFailureLogWindow = const Duration(seconds: 10);
}

/// Decode-size for a network image displayed at [logicalSize] logical pixels:
/// physical pixels for the current display, with the DPR clamped so ultra-high
/// density screens don't inflate the decode again. Pass to **`memCacheWidth`
/// alone** so posters/logos are decoded at display size instead of their
/// native resolution.
///
/// **Pass one dimension, never both.** `cached_network_image` hands both
/// through to `ResizeImage.resizeIfNeeded`, whose default
/// `ResizeImagePolicy.exact` sizes the bitmap to *both* targets "regardless of
/// whether it matches the source image's intrinsic aspect ratio … similar to
/// [BoxFit.fill]". The image is then decoded pre-distorted and the
/// [BoxFit.cover] that was meant to crop it has nothing left to crop. Passing
/// width alone scales the height to preserve aspect, which is what every call
/// site here wants. If a ceiling on the other axis is ever genuinely needed,
/// construct `ResizeImage(..., policy: ResizeImagePolicy.fit)` explicitly
/// rather than adding a second `memCache*` argument.
int imageCacheSize(BuildContext context, double logicalSize) {
  return scaledImageCacheSize(
    logicalSize,
    MediaQuery.devicePixelRatioOf(context),
  );
}

/// Pure sizing boundary used by tests and as a last line of defence for
/// widgets built with `double.infinity` inside a bounded LayoutBuilder.
@visibleForTesting
int scaledImageCacheSize(double logicalSize, double devicePixelRatio) {
  final safeLogical = logicalSize.isFinite && logicalSize > 0
      ? logicalSize
      : 1.0;
  final safeDpr = devicePixelRatio.isFinite && devicePixelRatio > 0
      ? devicePixelRatio.clamp(1.0, 3.0)
      : 1.0;
  final physical = safeLogical * safeDpr;
  if (!physical.isFinite || physical <= 0) return 1;
  return physical.round().clamp(1, 8192);
}
