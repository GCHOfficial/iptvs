// The MAG portal watchdog (keep-alive) — the pure half.
//
// **This is a hypothesis test, not a known fix.** See docs/sources.md
// "The portal watchdog (keep-alive)". Everything here mirrors the behaviour of
// the real STB client, sourced from the open-source `stalker_portal`
// middleware (`azhurb/stalker_portal`, read through a complete fork since the
// upstream repo was stripped when it was archived):
//
//   * `c/watchdog.js:71-105` — the request a box sends:
//     `type=watchdog`, `action=get_events`, `cur_play_type`, `event_active_id`,
//     `init`.
//   * `c/watchdog.js:6-12` — the client's own default poll interval,
//     `this.request_timeout = 30000` (30 s).
//   * `c/watchdog.js:14-69` — `run(timeout, timeslot)`:
//     `this.request_timeout = timeout*1000 || this.request_timeout`, one
//     immediate `send_request(true)` (i.e. `init=1`), then `setInterval` at
//     that period. So an absent or zero portal value leaves the box polling
//     every 30 s.
//   * `c/xpcom.common.js:1172,1399` — where the interval comes from:
//     `this.user['watchdog_timeout']`, parsed out of the `get_profile`
//     payload, handed to `watchdog.run(...)`.
//   * `server/config.ini:196-197` — the portal-side default and its documented
//     range: `; Timeout for polling the server in seconds. Set between 30 and
//     300.` / `watchdog_timeout = 120`.
//   * `c/xpcom.common.js:2065+` (`stb.get_current_place`) — `cur_play_type`:
//     1 for live TV, 11 for TV archive, 14 for timeshift, 2 for VOD, 0 when
//     nothing is playing (and 0 while paused, from `watchdog.js:76-80`).
//   * `server/lib/watchdog.class.php:20-85` — what the portal does with it:
//     `users.keep_alive = NOW()`, `last_watchdog = NOW()`, plus `ip`,
//     `now_playing_type` and `just_started`, then returns any pending event.
//
// What the open-source server does when the polls stop is recorded honestly in
// docs/sources.md: `keep_alive` only drives "is this box online"
// (`server/lib/user.class.php:686`) and the streamer session counts
// (`server/lib/streamserver.class.php:195-200`, `server/lib/func.php:164,189`).
// Nothing in that code kills a running stream. The hypothesis is about what
// the *deployed* panels and streamers in front of real subscriptions do.

import 'package:flutter/foundation.dart' show immutable;

/// `cur_play_type` for a live TV channel (`stb.get_current_place`, the
/// `media_type == 'stream'` / `cur_place == 'tv'` branch).
const int kStalkerPlayTypeLiveTv = 1;

/// `cur_play_type` when nothing is playing.
const int kStalkerPlayTypeIdle = 0;

/// What a MAG box polls at when the portal's profile carries no
/// `watchdog_timeout` — `c/watchdog.js:8`, reached through the
/// `timeout*1000 || this.request_timeout` fallback at `c/watchdog.js:23`.
const Duration kStalkerWatchdogFallbackInterval = Duration(seconds: 30);

/// The range `server/config.ini:196` documents for `watchdog_timeout`
/// ("Set between 30 and 300"). The STB client does not clamp; we do, because a
/// panel that answers with something far outside it would otherwise either
/// hammer the portal or arm a keep-alive too slow to keep anything alive.
const Duration kStalkerWatchdogMinInterval = Duration(seconds: 30);
const Duration kStalkerWatchdogMaxInterval = Duration(seconds: 300);

/// Where [stalkerWatchdogInterval] got its answer — logged on the start line so
/// an export says whether the portal set the cadence or we fell back.
enum StalkerWatchdogIntervalSource { profile, fallback }

@immutable
class StalkerWatchdogInterval {
  const StalkerWatchdogInterval(this.interval, this.source);

  final Duration interval;
  final StalkerWatchdogIntervalSource source;

  @override
  bool operator ==(Object other) =>
      other is StalkerWatchdogInterval &&
      other.interval == interval &&
      other.source == source;

  @override
  int get hashCode => Object.hash(interval, source);

  @override
  String toString() =>
      'StalkerWatchdogInterval(${interval.inSeconds}s, ${source.name})';
}

/// The poll interval for a portal whose most recent `get_profile` returned
/// [profileJs], mirroring `c/xpcom.common.js:1172` + `c/watchdog.js:23`.
///
/// `parseInt` semantics on purpose: the portal sends this as a *string* at
/// least as often as a number, and `parseInt('120s', 10)` is 120 — so a
/// leading-digits parse is what the box actually does. A missing, unparseable,
/// zero or negative value is the client's own `|| this.request_timeout`
/// fallback.
StalkerWatchdogInterval stalkerWatchdogInterval(Map<dynamic, dynamic>? profileJs) {
  final seconds = _leadingInt(profileJs?['watchdog_timeout']);
  if (seconds == null || seconds <= 0) {
    return const StalkerWatchdogInterval(
      kStalkerWatchdogFallbackInterval,
      StalkerWatchdogIntervalSource.fallback,
    );
  }
  final clamped = seconds.clamp(
    kStalkerWatchdogMinInterval.inSeconds,
    kStalkerWatchdogMaxInterval.inSeconds,
  );
  return StalkerWatchdogInterval(
    Duration(seconds: clamped),
    StalkerWatchdogIntervalSource.profile,
  );
}

int? _leadingInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is! String) return null;
  final match = RegExp(r'^\s*(-?\d+)').firstMatch(value);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Whether poll number [n] (1-based) gets a diagnostics line.
///
/// The diagnostics log holds 2000 entries and is what a user exports for
/// support; a 30 s poll over a two-hour session is 240 lines, which would push
/// out the evidence the export was taken for. The first three prove the
/// watchdog armed and is answering, and one in ten after that is enough to
/// show it never stopped.
bool stalkerWatchdogShouldLog(int n) => n <= 3 || n % 10 == 0;

/// The `events=` field of the watchdog diagnostics line.
///
/// A count when the portal sent one (`msgs`, `server/lib/watchdog.class.php:55`),
/// otherwise the response's key **names** only. Never a value: the event
/// payload carries `msg` text that panels use for account notices, and
/// `%mac%`/`%sn%` substitution (`c/watchdog.js:218`) means it can carry the
/// subscriber's own identifiers.
String stalkerWatchdogEventsNote(dynamic js) {
  if (js is! Map) return 'none';
  final msgs = js['msgs'];
  if (msgs is num) return '${msgs.toInt()}';
  final parsed = msgs is String ? int.tryParse(msgs.trim()) : null;
  if (parsed != null) return '$parsed';
  if (js.isEmpty) return 'none';
  final keys = js.keys.map((k) => '$k').toList()..sort();
  return '[${keys.join(',')}]';
}

/// `HTTP <code>` for the watchdog line, pulled back out of a thrown message.
///
/// The transport throws `HTTP <nnn> from <redacted url>` for a status it
/// refuses, and returns only on 200 — so a success is 200 by construction and
/// a failure is whatever status is quoted in the message, or `-` for a failure
/// that never got one (a socket error, a non-JSON body).
String stalkerWatchdogStatus(Object error) {
  final match = RegExp(r'HTTP (\d{3})').firstMatch('$error');
  return match == null ? '-' : match.group(1)!;
}
