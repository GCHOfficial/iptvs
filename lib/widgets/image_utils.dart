import 'package:flutter/widgets.dart';

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
