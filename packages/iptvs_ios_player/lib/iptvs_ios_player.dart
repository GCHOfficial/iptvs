/// Empty Dart façade for the `iptvs_ios_player` plugin.
///
/// This package exists only to carry the native iOS engine shim (see
/// `ios/Classes/IptvsIosPlayerPlugin.swift` and the `IptvsPlayerCore` SwiftPM
/// package). `pub` requires every plugin to have a `lib/<name>.dart` entry
/// point, but the app talks to the native side directly over the existing
/// `iptvs/native_hdr_player` method channel (see `lib/player/`), the same
/// channel the Android native player already uses — there is nothing for
/// Dart code in this repo to import here. `GeneratedPluginRegistrant`
/// registers `IptvsIosPlayerPlugin` automatically once this package is a
/// path dependency in the app's `pubspec.yaml`.
library;
