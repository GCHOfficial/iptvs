import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'distribution_channel.dart';
import 'net.dart';

/// The byte ceiling the cloud `submit_diagnostics` RPC enforces server-side
/// (`assert_diagnostics_valid`, 256 KiB).
///
/// The client trims to fit rather than letting the server reject: a user who
/// has just read a consent paragraph and pressed Send should not be told their
/// log is the wrong shape — and the oldest entries are the least likely to be
/// about the problem they are reporting.
const int kDiagnosticsMaxUploadBytes = 256 * 1024;

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

  String _appBuild = '';

  /// `<version>+<build>` for the running build, e.g. `0.1.79+42`.
  ///
  /// Set once during boot (`_recordBuildIdentity` in `main.dart`) because
  /// `PackageInfo.fromPlatform` is async while [asText] and [asTextBounded]
  /// are not. Until then the header reads `app=unknown`, which is the honest
  /// answer for an export taken in the first few hundred milliseconds.
  ///
  /// It exists because an exported log that does not say which build produced
  /// it cannot be read against a changelog: "it still happens" and "it happens
  /// again on a build that was supposed to fix it" are the same text.
  set appBuild(String value) => _appBuild = value.trim();

  /// The two build-identity fields every export carries, beside `entries=`.
  ///
  /// `channel` is the raw `DISTRIBUTION_CHANNEL` define rather than the parsed
  /// enum: an unrecognised value parses to `development`, and a report from a
  /// build whose channel define was wrong is exactly the report that needs to
  /// say so.
  String get _buildIdentityLine =>
      'app=${_appBuild.isEmpty ? 'unknown' : _appBuild} '
      'channel=${DistributionConfig.rawChannel}';

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
      _buildIdentityLine,
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

  /// [asText], trimmed **oldest-first** to fit [maxBytes] of UTF-8.
  ///
  /// This is what leaves the device — uploaded to the developer, or served over
  /// the LAN — and it is a *snapshot*: the caller takes it once, when the user
  /// presses Send, and both paths serve that exact string. The text the user
  /// agreed to send is therefore byte-for-byte the text that goes, which is the
  /// only version of "shows you what it will send" that is actually true of a
  /// log still being appended to by a running player.
  ///
  /// Oldest-first because the newest entries are the ones describing the
  /// problem being reported; a report trimmed from the other end would arrive
  /// with the evidence missing. When anything is dropped the result says so, in
  /// the header rather than at the end: a reader scans a log from the top, and
  /// "there is a hole here" has to arrive before the first surviving line, not
  /// after the last.
  ///
  /// NUL is stripped. Postgres `text` cannot hold U+0000 at all, so a log that
  /// somehow carried one would be refused by the driver with an error that is
  /// *not* an `iptvs: ` message — i.e. the one failure the UI could not explain.
  ///
  /// Pure with respect to the log: it reads [entries] and mutates nothing.
  String asTextBounded(int maxBytes) {
    // Both header lines are part of the size accounting below: `overhead` is
    // measured from this list, so adding a line here is accounted for without
    // touching the trim loop.
    final header = <String>[
      'iptvs diagnostics exported ${DateTime.now().toIso8601String()}',
      _buildIdentityLine,
      'entries=${_entries.length}',
    ];
    final lines = _entries
        .map(
          (entry) =>
              '${entry.time.toIso8601String()} [${entry.scope}] '
              '${redactText(entry.message)}',
        )
        .map(_stripNul)
        .toList(growable: false);

    final full = [...header, '', ...lines].join('\n');
    if (_utf8Length(full) <= maxBytes) return full;

    // Keep the longest *suffix* of entries that fits, accounting for the note
    // the trim itself costs. Accumulated newest-backwards rather than
    // re-encoding a candidate string per step: the log is bounded at 800
    // entries, but re-joining 800 times to measure is work for nothing.
    var kept = 0;
    var used = 0;
    for (var i = lines.length - 1; i >= 0; i--) {
      final cost = _utf8Length(lines[i]) + 1; // + the '\n' that joins it
      // The note's size depends on the count it prints, so it is re-measured
      // on every candidate rather than reserved once.
      final note = _trimNote(lines.length - kept - 1);
      // The blank element is the separator line between the header block and
      // the entries; joining it contributes its own '\n' and nothing else.
      final overhead = _utf8Length([...header, note, ''].join('\n'));
      if (overhead + used + cost > maxBytes) break;
      used += cost;
      kept++;
    }

    final dropped = lines.length - kept;
    final out = [
      ...header,
      _trimNote(dropped),
      '',
      ...lines.sublist(dropped),
    ].join('\n');
    // A ceiling small enough that even the header does not fit is not a real
    // configuration, but it must not return something *over* the limit — the
    // server would reject it and the user would see a failure with no cause.
    // Cut on a UTF-8 boundary rather than a code-unit one.
    if (_utf8Length(out) <= maxBytes) return out;
    return _truncateUtf8(out, maxBytes);
  }

  static String _trimNote(int dropped) => '($dropped older entries trimmed '
      'to fit)';

  static String _stripNul(String value) =>
      value.contains('\u0000') ? value.replaceAll('\u0000', '') : value;

  static int _utf8Length(String value) => utf8.encode(value).length;

  static String _truncateUtf8(String value, int maxBytes) {
    if (maxBytes <= 0) return '';
    final bytes = utf8.encode(value);
    if (bytes.length <= maxBytes) return value;
    var end = maxBytes;
    // Walk back off a continuation byte (10xxxxxx) so the cut never lands
    // inside a multi-byte sequence and produces invalid UTF-8.
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
  }
}
