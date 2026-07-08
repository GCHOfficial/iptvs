import 'package:flutter/widgets.dart';

/// A [FocusNode] that carries a **release-safe** routing key.
///
/// The live tab and the root Back ladder route D-pad logic off the focused
/// node's identity (`live.channel.*`, `live.category.*`, `media.*`, the search
/// cells, …). They used to read [FocusNode.debugLabel], but Flutter compiles
/// that to `null` in release builds — its setter body only runs inside an
/// `assert` (the framework's own doc: *"Will always return null in release
/// builds"*). On a real TV/box every route read then returned `''`, so the Back
/// ladder collapsed straight to the exit path and pane-crossing/Down navigation
/// silently stopped. [routeKey] is a real field that survives release.
class RoutedFocusNode extends FocusNode {
  RoutedFocusNode(this.routeKey) : super(debugLabel: routeKey);

  /// The stable routing key (also mirrored into [debugLabel] for diagnostics).
  final String routeKey;
}

/// The release-safe routing key of [node], or `''` when it carries none.
///
/// Non-routed nodes (plain `Focus`/`FocusScope`) return `''` in both debug and
/// release, so routing behaves identically in tests and on device.
String focusRouteKey(FocusNode? node) =>
    node is RoutedFocusNode ? node.routeKey : '';
