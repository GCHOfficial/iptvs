import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'net.dart';

class DiagnosticsEntry {
  final DateTime time;
  final String scope;
  final String message;

  const DiagnosticsEntry({
    required this.time,
    required this.scope,
    required this.message,
  });
}

class DiagnosticsLog extends ChangeNotifier {
  DiagnosticsLog._();

  static final DiagnosticsLog instance = DiagnosticsLog._();
  static const _maxEntries = 800;

  final Queue<DiagnosticsEntry> _entries = Queue<DiagnosticsEntry>();

  List<DiagnosticsEntry> get entries => List.unmodifiable(_entries);

  void add(String scope, String message) {
    _entries.addLast(
      DiagnosticsEntry(
        time: DateTime.now(),
        scope: redactText(scope),
        message: redactText(message),
      ),
    );
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  /// [add], **and** mirror to the debug console.
  ///
  /// Two different audiences: the exportable log is what a user sends back, the
  /// console is what a developer watches during `flutter run`. Most call sites
  /// want one of the two — but a few facts are wanted by both, and they are the
  /// ones that describe what the app decided *before there is anything on
  /// screen to look at*. For those, "nothing in the console" and "the code
  /// never ran" are indistinguishable, and that ambiguity has already cost one
  /// debugging round trip: the device-class and layout-geometry lines went to
  /// the export only, so an attached `flutter run` showed no trace of a
  /// decision that had in fact been made.
  ///
  /// Same redaction as [add] — this is the same content, so it carries the same
  /// rule — and the same `iptvs.<scope>` naming the rest of the app prints
  /// under. Debug-only: release builds keep the exportable half and drop the
  /// console noise.
  void addAndPrint(String scope, String message) {
    add(scope, message);
    if (!kDebugMode) return;
    final redacted = redactText(message);
    developer.log(redacted, name: 'iptvs.${redactText(scope)}');
    debugPrint('[iptvs.${redactText(scope)}] $redacted');
  }

  /// Records the bounded, non-sensitive summary of one ingestion operation.
  /// Callers must not pass payloads or individual row contents here.
  void recordIngestion({
    required String scope,
    int? compressedBytes,
    int? decodedBytes,
    required Duration providerDuration,
    required Duration databaseDuration,
    int? rejectedRows,
  }) {
    add(
      scope,
      'ingestion compressed_bytes=${_bounded(compressedBytes)} '
      'decoded_bytes=${_bounded(decodedBytes)} '
      'provider_ms=${providerDuration.inMilliseconds.clamp(0, 1 << 31)} '
      'database_ms=${databaseDuration.inMilliseconds.clamp(0, 1 << 31)} '
      'rejected_rows=${_bounded(rejectedRows)}',
    );
  }

  String _bounded(int? value) =>
      value == null ? 'unknown' : value.clamp(0, 1 << 30).toString();

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String asText() {
    final lines = <String>[
      'iptvs diagnostics exported ${DateTime.now().toIso8601String()}',
      'entries=${_entries.length}',
      '',
      ..._entries.map(
        (entry) =>
            '${entry.time.toIso8601String()} [${entry.scope}] '
            '${redactText(entry.message)}',
      ),
    ];
    return lines.join('\n');
  }
}
