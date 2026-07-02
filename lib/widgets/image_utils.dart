import 'package:flutter/widgets.dart';

/// Decode-size for a network image displayed at [logicalSize] logical pixels:
/// physical pixels for the current display, with the DPR clamped so ultra-high
/// density screens don't inflate the decode again. Pass to `memCacheWidth`/
/// `memCacheHeight` (or `ResizeImage`) so posters/logos are decoded at display
/// size instead of their native resolution.
int imageCacheSize(BuildContext context, double logicalSize) {
  final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 3.0);
  return (logicalSize * dpr).round();
}
