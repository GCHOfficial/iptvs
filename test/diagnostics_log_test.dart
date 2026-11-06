import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/diagnostics_log.dart';

void main() {
  final log = DiagnosticsLog.instance;

  setUp(log.clear);
  tearDown(log.clear);

  test('diagnostics entries are redacted before display and export', () {
    log.add(
      'source:https://user:pass@example.invalid/live/provideruser123/providerpass123/token',
      'failed https://user:pass@example.invalid/live/provideruser123/providerpass123/token',
    );
    final entry = log.entries.single;
    expect(entry.scope, isNot(contains('pass')));
    expect(entry.message, isNot(contains('pass')));
    expect(log.asText(), isNot(contains('user:pass')));
    expect(log.asText(), isNot(contains('providerpass123')));
  });

  group('build identity header', () {
    // Set once at boot and never cleared, so every test below restores it.
    tearDown(() => log.appBuild = '');

    test('every export says which build produced it', () {
      log.appBuild = '0.1.79+42';
      log.add('player', 'something');
      for (final text in [log.asText(), log.asTextBounded(1 << 20)]) {
        final lines = text.split('\n');
        // Beside `entries=`, so a reader scanning the top of a report sees
        // the build before the first log line.
        expect(lines[1], 'app=0.1.79+42 channel=development');
        expect(lines[2], 'entries=1');
      }
    });

    test('an unresolved version reads `unknown` rather than being omitted', () {
      // `PackageInfo.fromPlatform` is async; an export taken in the first
      // moments of a launch has to say so instead of silently dropping the
      // field, which would read as an older build that never had one.
      expect(log.asText(), contains('app=unknown channel=development'));
    });

    test('the bounded export still honours its cap with the extra line', () {
      log.appBuild = '0.1.79+42';
      for (var i = 0; i < 200; i++) {
        log.add('s', 'line $i padded out so the trim loop has work to do');
      }
      for (final cap in [0, 1, 40, 120, 900, 3000]) {
        final bounded = log.asTextBounded(cap);
        expect(
          utf8.encode(bounded).length,
          lessThanOrEqualTo(cap),
          reason: 'cap=$cap must be honoured with the app= line present',
        );
      }
    });
  });

  group('asTextBounded', () {
    int bytes(String value) => utf8.encode(value).length;

    test('returns the whole log untouched when it already fits', () {
      log.add('player', 'first');
      log.add('player', 'second');
      final full = log.asText();
      final bounded = log.asTextBounded(1 << 20);
      expect(bounded, contains('first'));
      expect(bounded, contains('second'));
      expect(bounded, isNot(contains('trimmed to fit')));
      // Only the export timestamp in the header can differ between the two.
      expect(bounded.split('\n').length, full.split('\n').length);
    });

    test('trims oldest-first and keeps the newest entries', () {
      for (var i = 0; i < 200; i++) {
        log.add('scope$i', 'entry number $i with some padding text to bulk it out');
      }
      // Comfortably smaller than the whole log, comfortably larger than the
      // header — so the trim is the behaviour under test rather than an edge.
      const cap = 2000;
      final bounded = log.asTextBounded(cap);

      expect(bytes(bounded), lessThanOrEqualTo(cap));
      // The newest entry is the one most likely to be about the problem being
      // reported. It must survive; the oldest must not.
      expect(bounded, contains('entry number 199'));
      expect(bounded, isNot(contains('entry number 0 ')));
      expect(bounded, contains('trimmed to fit'));
    });

    test('the trim note counts exactly the entries that were dropped', () {
      for (var i = 0; i < 60; i++) {
        log.add('s', 'line $i');
      }
      final bounded = log.asTextBounded(900);
      final match = RegExp(r'\((\d+) older entries trimmed to fit\)')
          .firstMatch(bounded);
      expect(match, isNotNull, reason: 'the note must be present when trimming');

      final dropped = int.parse(match!.group(1)!);
      // One body line per surviving entry; the header is two lines plus the
      // note plus the blank separator.
      final bodyLines = bounded
          .split('\n')
          .where((line) => RegExp(r'^\d{4}-').hasMatch(line))
          .length;
      expect(dropped + bodyLines, 60);
      // Nothing older than the cut survived, and the first survivor is
      // immediately after it.
      expect(bounded, contains('line ${60 - bodyLines}'));
      expect(bounded, isNot(contains('line ${60 - bodyLines - 1}\n')));
    });

    test('the note sits above the surviving entries, not after them', () {
      for (var i = 0; i < 60; i++) {
        log.add('s', 'line $i');
      }
      final bounded = log.asTextBounded(900);
      final noteAt = bounded.indexOf('older entries trimmed to fit');
      final firstEntryAt = bounded.indexOf('line ');
      expect(noteAt, greaterThan(-1));
      // A reader scans from the top: "there is a hole here" has to arrive
      // before the first surviving line.
      expect(noteAt, lessThan(firstEntryAt));
    });

    test('measures UTF-8 bytes, not characters', () {
      // Four bytes each. A character-counting implementation would overshoot
      // the cap by ~4x on a log like this and be rejected by the server.
      for (var i = 0; i < 200; i++) {
        log.add('s', '${'🛰' * 40} $i');
      }
      const cap = 3000;
      final bounded = log.asTextBounded(cap);
      expect(bytes(bounded), lessThanOrEqualTo(cap));
      expect(bounded.length, lessThan(cap));
    });

    test('never exceeds the cap even when the header alone does not fit', () {
      log.add('s', 'something');
      for (final cap in [0, 1, 10, 40]) {
        final bounded = log.asTextBounded(cap);
        expect(
          bytes(bounded),
          lessThanOrEqualTo(cap),
          reason: 'cap=$cap must be honoured, not approximated',
        );
      }
    });

    test('strips NUL, which Postgres text cannot hold at all', () {
      log.add('s', 'before\u0000after');
      final bounded = log.asTextBounded(1 << 20);
      expect(bounded, isNot(contains('\u0000')));
      expect(bounded, contains('beforeafter'));
    });

    test('an empty log still produces a well-formed export', () {
      final bounded = log.asTextBounded(kDiagnosticsMaxUploadBytes);
      expect(bounded, contains('entries=0'));
      expect(bounded, isNot(contains('trimmed to fit')));
    });
  });
}
