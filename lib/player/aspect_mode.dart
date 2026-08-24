/// How the picture is framed inside the surface showing it.
///
/// One list, shared by every surface, because the label is text those surfaces
/// render and the *sequence* is what a user learns. Kotlin `AspectMode` and
/// Swift `PlayerAspectMode` mirror it; the Windows GDI overlay and the Linux Lua
/// OSD render whatever label Dart hands them.
library;

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show BoxFit;

import '../data/device_class.dart' show isTelevision;

/// A video framing mode.
///
/// [panscan] maps to mpv's `panscan` (0 = letterbox/fit, 1 = crop to fill),
/// [aspect] to `video-aspect-override` (`no` clears any forced display aspect),
/// and [keepaspect] to mpv's `keepaspect` (`no` is stretch — the picture is
/// scaled on both axes independently).
///
/// [fit] is the same framing expressed for the **embedded** surface, which is
/// composited by Flutter rather than by mpv: `media_kit`'s `Video` widget draws
/// the texture with a `BoxFit`, so that is the lever there. Both live on one
/// object so a mode cannot be defined for one surface and forgotten on the
/// other — the two swap on the same machine (HDR decides which), and a framing
/// that changed with a stream's dynamic range would be a bug.
class AspectMode {
  final String label;
  final String panscan;
  final String aspect;
  final String keepaspect;
  final BoxFit fit;
  const AspectMode(
    this.label,
    this.panscan,
    this.aspect, {
    this.keepaspect = 'yes',
    required this.fit,
  });
}

/// The framing cycle, in the order every surface renders it.
///
/// **`Fill` and `Stretch` are different and both are wanted.** `Fill` crops to
/// fill while keeping the picture's shape; `Stretch` distorts to fill and keeps
/// every pixel. On a 20:9 handset `Fill` costs 16:9 content about a fifth of its
/// width, and 4:3 content far more — so a viewer who wants the whole frame edge
/// to edge asks for stretch, and a zoom does not serve them.
const List<AspectMode> kAspectModes = <AspectMode>[
  AspectMode('Fit', '0.0', 'no', fit: BoxFit.contain),
  AspectMode('Fill', '1.0', 'no', fit: BoxFit.cover),
  AspectMode('Stretch', '0.0', 'no', keepaspect: 'no', fit: BoxFit.fill),
  // A forced display aspect reshapes the picture itself, so the embedded
  // surface still letterboxes whatever comes out of that.
  AspectMode('16:9', '0.0', '16:9', fit: BoxFit.contain),
  AspectMode('4:3', '0.0', '4:3', fit: BoxFit.contain),
];

/// Index of [label] in [kAspectModes], or -1.
int aspectModeIndexOf(String? label) {
  if (label == null || label.isEmpty) return -1;
  for (var i = 0; i < kAspectModes.length; i++) {
    if (kAspectModes[i].label.toLowerCase() == label.toLowerCase()) return i;
  }
  return -1;
}

/// The mode a player opens on when the user has never chosen one.
///
/// **Fill on a television or a handset, Fit on a desktop**, and the difference
/// is not inconsistency — it is the same intent ("use the screen well")
/// answered for two different kinds of container.
///
/// A TV or phone screen is a *fixed* shape that almost always matches the
/// content, so Fill and Fit are identical there: no crop happens at all. They
/// differ only on 4:3 material, where filling the screen is what a viewer of a
/// television expects and pillarboxing reads as a fault.
///
/// A desktop window is whatever shape the user dragged it to, so the mismatch
/// is permanent and Fill would crop *continuously* — by an amount that changes
/// as the window is resized, taking most of the frame from a tall narrow one.
/// That is why every desktop player defaults to letterboxing.
///
/// **Keyed off the platform, never off which rendering surface was chosen.** On
/// Windows the native and embedded surfaces are picked purely by whether the
/// stream is HDR, so keying off the surface would frame the same channel
/// differently depending on its dynamic range.
int defaultAspectModeIndex() {
  final fills = isTelevision || Platform.isAndroid || Platform.isIOS;
  final index = aspectModeIndexOf(fills ? 'Fill' : 'Fit');
  // The labels are const in this file, so this cannot miss — but a rename
  // should degrade to a valid mode rather than an out-of-range index.
  return index < 0 ? 0 : index;
}

/// The stored mode's index, falling back to [defaultAspectModeIndex] when the
/// user has never chosen one (or chose one a later build removed).
int resolveAspectModeIndex(String? storedLabel) {
  final stored = aspectModeIndexOf(storedLabel);
  return stored < 0 ? defaultAspectModeIndex() : stored;
}
