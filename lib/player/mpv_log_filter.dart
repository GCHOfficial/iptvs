/// Which mpv log entries reach the exportable diagnostics log.
///
/// FFmpeg-prefixed lines are dropped wholesale: decode and demux complaints
/// (`hevc: Could not find ref with POC …`, UDTA/timescale noise) are non-fatal
/// and arrive in floods, and real playback failures come through
/// `stream.error`. **The exception is FFmpeg's HTTP transport.** Its lines are
/// rare and are the only record of a connection-level event:
/// - `http: Stream ends prematurely at …`
/// - `http: Will reconnect at … in N second(s)`
/// - `HTTP error 403 Forbidden`
///
/// Dropping them made an in-place reconnect attempt invisible by construction.
/// While investigating a provider's "clean EOF" reloads, the export could not
/// say whether FFmpeg had tried to resume or never tried. The caller still
/// redacts the text, because an HTTP line can quote a credentialed URL.
bool shouldRelayMpvLog({
  required String level,
  required String prefix,
  required String text,
}) {
  if (level != 'warn' && level != 'error') return false;
  if (!prefix.contains('ffmpeg')) return true;
  final t = text.trimLeft();
  return t.startsWith('http:') ||
      t.startsWith('https:') ||
      t.contains('HTTP error') ||
      t.contains('Will reconnect') ||
      t.contains('Stream ends prematurely');
}
