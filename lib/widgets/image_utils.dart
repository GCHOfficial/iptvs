import 'package:flutter/widgets.dart';

/// Decode-size for a network image displayed at [logicalSize] logical pixels:
/// physical pixels for the current display, with the DPR clamped so ultra-high
/// density screens don't inflate the decode again. Pass to `memCacheWidth`/
/// `memCacheHeight` (or `ResizeImage`) so posters/logos are decoded at display
/// size instead of their native resolution.
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
