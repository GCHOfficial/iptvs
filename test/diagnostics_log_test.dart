import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';

void main() {
  test('diagnostics entries are redacted before display and export', () {
    final log = DiagnosticsLog.instance;
    log.clear();
    log.add(
      'source:https://user:pass@example.invalid/live/provideruser123/providerpass123/token',
      'failed https://user:pass@example.invalid/live/provideruser123/providerpass123/token',
    );
    final entry = log.entries.single;
    expect(entry.scope, isNot(contains('pass')));
    expect(entry.message, isNot(contains('pass')));
    expect(log.asText(), isNot(contains('user:pass')));
    expect(log.asText(), isNot(contains('providerpass123')));
    log.clear();
  });
}
