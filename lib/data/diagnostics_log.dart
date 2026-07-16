import 'dart:collection';

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
      DiagnosticsEntry(time: DateTime.now(), scope: scope, message: message),
    );
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  /// Records the bounded, non-sensitive summary of one ingestion operation.
  /// Callers must not pass payloads or individual row contents here.
  void recordIngestion({
    required String scope,
    int compressedBytes = 0,
    int decodedBytes = 0,
    required Duration parseDuration,
    required Duration databaseDuration,
    int rejectedRows = 0,
  }) {
    add(
      scope,
      'ingestion compressed_bytes=${compressedBytes.clamp(0, 1 << 30)} '
      'decoded_bytes=${decodedBytes.clamp(0, 1 << 30)} '
      'parse_ms=${parseDuration.inMilliseconds.clamp(0, 1 << 31)} '
      'database_ms=${databaseDuration.inMilliseconds.clamp(0, 1 << 31)} '
      'rejected_rows=${rejectedRows.clamp(0, 1 << 30)}',
    );
  }

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
