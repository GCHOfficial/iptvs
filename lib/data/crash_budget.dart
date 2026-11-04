import 'dart:io';

/// The per-install send budget shared by **every** crash-report source.
///
/// Why a budget exists at all: the Sentry organisation this app reports into
/// has a single 50 000 errors/month quota, shared with another product, and
/// the plan offers **no per-project rate limit**. A dashboard setting cannot
/// protect it, so the client has to. One misbehaving build — a reconnect loop
/// that throws on every tick, a device whose decoder crashes on every open —
/// would otherwise spend the whole organisation's month in an afternoon.
///
/// Three independent caps, all of which must pass:
///
/// * **per session** ([maxPerSession]) — bounds a single run that is failing
///   repeatedly. This is the one that stops a tight loop inside one launch.
/// * **per rolling 24 h** ([maxPerDay]) — bounds a device that keeps being
///   relaunched into the same failure.
/// * **per rolling 30 days** ([maxPerMonth]) — the cap that actually bounds
///   the *monthly* quota, and the only one whose arithmetic can be compared
///   against 50 000 directly. 20/day x 30 would be 600 events per install per
///   month, i.e. ~83 installs could exhaust the whole organisation; 60 per 30
///   days puts that ceiling at ~830 installs instead. See CLAUDE.md.
///
/// Plus **de-duplication**: one event per fingerprint per [dedupWindow]. A
/// crash that reproduces on every launch is worth knowing about once a day,
/// not once a launch.
///
/// And a **crash-loop guard**: [beginSession] counts launches that never
/// reached [markHealthy]. Once [crashLoopStartLimit] launches in a row have
/// died early, the caller must not start the SDK at all — the first crash of
/// the loop was already reported and everything after it is the same crash.
///
/// ## Why a plain file, in this format
///
/// The Android native layer has to apply the *same* budget to events the Dart
/// `beforeSend` never sees (Java/Kotlin uncaught exceptions, NDK crashes,
/// tombstones — see `crash_reporter.dart`). Kotlin cannot read
/// `flutter_secure_storage`'s encrypted blob, so the state lives in a small
/// file whose absolute path Dart hands to the native installer. Nothing in it
/// is a secret: three counters, a session id, and opaque fingerprint hashes.
///
/// The format is line-oriented `key=value` ASCII rather than JSON, because the
/// Kotlin half has to parse it in a **plain JVM unit test**: `org.json` on
/// Android is a stub that throws in unit tests, and pulling a real JSON
/// implementation onto the test classpath to read six integers would be the
/// tail wagging the dog. Every value here is a decimal integer or a
/// `[0-9a-f]{32}` hash, so there is nothing to escape and the two parsers
/// cannot disagree about quoting. `CrashScrub.kt` implements the same grammar
/// and `CrashScrubTest` pins it against the same vectors as
/// `test/crash_reporting_test.dart`.
///
/// Both layers read-modify-write the same file from the same process. A lost
/// update costs at most one event of budget in either direction, which is why
/// no locking is attempted; writes are atomic (temp file + rename) so a kill
/// mid-write cannot leave a half-written file behind, and an unreadable or
/// unknown-version file is treated as a fresh one.
class CrashBudgetState {
  CrashBudgetState({
    this.dayStartMs = 0,
    this.dayCount = 0,
    this.monthStartMs = 0,
    this.monthCount = 0,
    this.sessionId = 0,
    this.sessionCount = 0,
    this.starts = 0,
    Map<String, int>? seen,
  }) : seen = seen ?? <String, int>{};

  int dayStartMs;
  int dayCount;
  int monthStartMs;
  int monthCount;
  int sessionId;
  int sessionCount;

  /// Launches since the last [CrashBudget.markHealthy].
  int starts;

  /// Fingerprint -> when it was last sent, in epoch milliseconds.
  final Map<String, int> seen;

  /// Schema version of the on-disk file. `CrashScrub.kt` writes and expects
  /// the same number; bump both together, and treat an unknown version as
  /// "start fresh" on both sides.
  static const int formatVersion = 1;

  static CrashBudgetState parse(String raw) {
    final state = CrashBudgetState();
    var sawVersion = false;
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final key = trimmed.substring(0, eq);
      final value = trimmed.substring(eq + 1);
      switch (key) {
        case 'v':
          if (int.tryParse(value) != formatVersion) return CrashBudgetState();
          sawVersion = true;
        case 'day':
          final pair = _pair(value);
          state.dayStartMs = pair.$1;
          state.dayCount = pair.$2;
        case 'month':
          final pair = _pair(value);
          state.monthStartMs = pair.$1;
          state.monthCount = pair.$2;
        case 'session':
          final pair = _pair(value);
          state.sessionId = pair.$1;
          state.sessionCount = pair.$2;
        case 'starts':
          state.starts = int.tryParse(value) ?? 0;
        case 'fp':
          final pair = value.split(',');
          if (pair.length == 2) {
            final at = int.tryParse(pair[1]);
            if (at != null && pair[0].isNotEmpty) state.seen[pair[0]] = at;
          }
      }
    }
    // A file with no recognisable version line is from a future (or broken)
    // writer. Starting fresh re-arms the caps from now, which is the safe
    // reading — the alternative is honouring counters we cannot interpret.
    return sawVersion ? state : CrashBudgetState();
  }

  static (int, int) _pair(String value) {
    final parts = value.split(',');
    if (parts.length != 2) return (0, 0);
    return (int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
  }

  String encode() {
    final buffer = StringBuffer()
      ..writeln('v=$formatVersion')
      ..writeln('day=$dayStartMs,$dayCount')
      ..writeln('month=$monthStartMs,$monthCount')
      ..writeln('session=$sessionId,$sessionCount')
      ..writeln('starts=$starts');
    for (final entry in seen.entries) {
      buffer.writeln('fp=${entry.key},${entry.value}');
    }
    return buffer.toString();
  }
}

/// Why one more event was *not* sent.
///
/// The name of each refusal is written to the exportable diagnostics log
/// beside the fingerprint's first 8 hex characters. Until it existed a refused
/// event left no trace at all on either side, so "the crash never reported"
/// and "the crash reported once and was de-duplicated for a day" were
/// indistinguishable from a user's export — which is exactly the question
/// asked of a budget. Nothing here is a secret: the reason is one of four
/// fixed words and the fingerprint is a SHA-256 prefix over type and symbol
/// names.
///
/// Mirrored by Kotlin's `CrashBudgetOutcome`; the four refusal names must stay
/// spelled the same on both sides, since one install's log carries both.
enum CrashBudgetOutcome {
  admitted,
  duplicate,
  session,
  day,
  month;

  bool get isAdmitted => this == CrashBudgetOutcome.admitted;
}

/// File-backed [CrashBudgetState] with the three caps, the de-duplication
/// window and the crash-loop guard applied.
class CrashBudget {
  CrashBudget(this.file, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final File file;
  final DateTime Function() _clock;

  static const int maxPerSession = 5;
  static const int maxPerDay = 20;
  static const int maxPerMonth = 60;

  static const Duration dayWindow = Duration(hours: 24);
  static const Duration monthWindow = Duration(days: 30);
  static const Duration dedupWindow = Duration(hours: 24);

  /// Launches in a row that never reached [markHealthy] before the SDK is
  /// withheld entirely. Three means: the first startup crash is reported, the
  /// second launch still reports (it may be a *different* crash), and from the
  /// third the app stops talking to Sentry until one launch survives.
  static const int crashLoopStartLimit = 3;

  /// How long a launch must survive before it counts as healthy.
  ///
  /// Deliberately short. A television user who opens the app and presses Back
  /// out of it is a *normal* short launch, not a crash, and there is no
  /// reliable "process exited cleanly" signal on Android — so the guard has to
  /// be forgiving enough that ordinary use never trips it. Ten seconds is past
  /// every boot path in this app while being far longer than a startup crash
  /// survives.
  static const Duration healthyAfter = Duration(seconds: 10);

  /// Most fingerprints retained. Bounds the file; the oldest go first.
  static const int maxFingerprints = 64;

  CrashBudgetState _read() {
    try {
      if (!file.existsSync()) return CrashBudgetState();
      return CrashBudgetState.parse(file.readAsStringSync());
    } catch (_) {
      // A corrupt or unreadable budget must never take the app down.
      return CrashBudgetState();
    }
  }

  void _write(CrashBudgetState state) {
    try {
      final temp = File('${file.path}.tmp');
      temp.parent.createSync(recursive: true);
      temp.writeAsStringSync(state.encode(), flush: true);
      temp.renameSync(file.path);
    } catch (_) {
      // Losing the write loses budget accounting, not the app.
    }
  }

  void _rotate(CrashBudgetState state, int nowMs) {
    if (nowMs - state.dayStartMs >= dayWindow.inMilliseconds) {
      state.dayStartMs = nowMs;
      state.dayCount = 0;
    }
    if (nowMs - state.monthStartMs >= monthWindow.inMilliseconds) {
      state.monthStartMs = nowMs;
      state.monthCount = 0;
    }
    state.seen.removeWhere(
      (_, atMs) => nowMs - atMs >= dedupWindow.inMilliseconds,
    );
  }

  /// Opens a new session and returns the number of consecutive launches —
  /// including this one — that have not yet reached [markHealthy].
  ///
  /// The caller compares that against [crashLoopStartLimit] *before* starting
  /// the SDK, because the kill switch has to cover the native crash handlers
  /// too: those are installed by the SDK's own init, so declining to init is
  /// the only thing that silences every source at once.
  int beginSession() {
    final nowMs = _clock().millisecondsSinceEpoch;
    final state = _read();
    _rotate(state, nowMs);
    state.starts += 1;
    state.sessionId = nowMs;
    state.sessionCount = 0;
    _write(state);
    return state.starts;
  }

  /// Records that this launch got far enough to be considered healthy, which
  /// re-arms the crash-loop guard.
  void markHealthy() {
    final state = _read();
    if (state.starts == 0) return;
    state.starts = 0;
    _write(state);
  }

  /// Whether one more event may be sent, charging it to every cap when so.
  ///
  /// [fingerprint] is an opaque, already-hashed identity for the fault (see
  /// `crashFingerprint`). An empty string skips de-duplication only — the
  /// three caps still apply.
  bool admit(String fingerprint) => check(fingerprint).isAdmitted;

  /// [admit] with the reason, for the one log line a refusal leaves behind.
  CrashBudgetOutcome check(String fingerprint) {
    final nowMs = _clock().millisecondsSinceEpoch;
    final state = _read();
    _rotate(state, nowMs);

    if (fingerprint.isNotEmpty && state.seen.containsKey(fingerprint)) {
      // Still write: the rotate above may have pruned expired entries, and
      // dropping that work would re-walk them on every suppressed event.
      _write(state);
      return CrashBudgetOutcome.duplicate;
    }
    if (state.sessionCount >= maxPerSession) return CrashBudgetOutcome.session;
    if (state.dayCount >= maxPerDay) return CrashBudgetOutcome.day;
    if (state.monthCount >= maxPerMonth) return CrashBudgetOutcome.month;

    state.sessionCount += 1;
    state.dayCount += 1;
    state.monthCount += 1;
    if (fingerprint.isNotEmpty) {
      state.seen[fingerprint] = nowMs;
      if (state.seen.length > maxFingerprints) {
        final ordered = state.seen.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value));
        for (final entry in ordered.take(
          state.seen.length - maxFingerprints,
        )) {
          state.seen.remove(entry.key);
        }
      }
    }
    _write(state);
    return CrashBudgetOutcome.admitted;
  }
}
