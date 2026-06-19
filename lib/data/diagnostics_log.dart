import 'dart:collection';

import 'package:flutter/foundation.dart';

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
            '${entry.time.toIso8601String()} [${entry.scope}] ${entry.message}',
      ),
    ];
    return lines.join('\n');
  }
}
