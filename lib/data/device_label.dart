import 'dart:io';

import 'package:flutter/services.dart';

/// The name a device suggests for itself when it asks for a pairing code.
///
/// A freshly paired device used to show up in the web panel as "Device" until
/// the owner renamed it. The device now sends a platform-derived suggestion
/// along with its pairing request, and the server adopts it as the device's
/// name unless the panel operator typed one (panel name wins; see
/// `supabase/migrations/20260804000000_pairing_suggested_label.sql` for the
/// precedence chain). Deliberately zero-typing: the primary device is a TV
/// driven by a D-pad remote, where entering text is genuinely painful.
///
/// The suggestion is a **display string with no authority** — nothing branches
/// on it, server-side or client-side. It is bounded and control-character
/// rejected by the server, and rendered through the panel's `esc()`.
const MethodChannel _channel = MethodChannel('iptvs/device');

/// Pure: platform + form factor to the suggested name. Split out from
/// [detectSuggestedDeviceLabel] so the mapping is unit-testable without a
/// platform channel.
String suggestedDeviceLabelFor({
  required String operatingSystem,
  required bool isTelevision,
}) => switch (operatingSystem) {
  'android' => isTelevision ? 'Android TV' : 'Android',
  'ios' => 'iPhone',
  'windows' => 'Windows PC',
  'linux' => 'Linux',
  'macos' => 'Mac',
  _ => '',
};

/// The suggestion for the device this code is running on.
///
/// Never throws: any failure degrades to an empty suggestion, which reproduces
/// the pre-feature behaviour exactly (the panel shows "Device" until renamed).
Future<String> detectSuggestedDeviceLabel() async {
  final os = Platform.operatingSystem;
  return suggestedDeviceLabelFor(
    operatingSystem: os,
    // Short-circuits, so the channel is only consulted on Android.
    isTelevision: os == 'android' && await _isAndroidTelevision(),
  );
}

/// Asks the Android side whether this is a TV (`UiModeManager`), matching the
/// check `HdrPlayerActivity.isTelevision()` already uses.
///
/// Outbound only — Dart registers no handler on `iptvs/device`, so this is
/// **not** a [ChannelHandlerOwner] case (that token contract governs inbound
/// handlers on process-static channels). A missing native half is not an error:
/// it just means "not a TV", so the suggestion degrades to "Android".
Future<bool> _isAndroidTelevision() async {
  try {
    return await _channel.invokeMethod<bool>('isTelevision') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}
