/// Detects the upstream (demuxer-level) end of a live stream — the moment the
/// provider closes the HTTP connection mpv's demuxer is reading from — which
/// is **not** the same moment as the player's own EOF.
///
/// **Why this exists.** A clean server-side EOF already surfaces as mpv
/// `eof-reached` → media_kit `completed=true` (see `player_screen.dart`'s
/// `stream.completed` listener and `shouldReconnectOnCompleted`), and that is
/// what drives the reconnect. But by the time *that* fires, playback has
/// already drained whatever the demuxer had cached ahead of the playhead — an
/// owner's export showed `ahead=0ms` on the reconnect line after the cushion
/// had visibly sat around 30s for minutes, with nothing in the log recording
/// when the provider actually dropped the connection versus when the app
/// finally ran out of buffered media to keep playing from. mpv's
/// `demuxer-cache-state` sub-property `eof` goes true as soon as the demuxer
/// itself hits end-of-input, which is *before* `eof-reached` if there is
/// still cached media the player hasn't consumed yet — exactly the gap this
/// line is for.
///
/// Read over property-path addressing (mpv's generic node sub-property
/// mechanism — the same one `video-params/w` already uses elsewhere in this
/// file and in `linux_native_session.dart`'s `video-target-params/<suffix>`
/// reads), via `get_property_string`, which renders an mpv flag as `"yes"` or
/// `"no"`.
library;

/// Parses mpv's `demuxer-cache-state/eof` sub-property as read by
/// `get_property_string` (`"yes"`/`"no"`), over either the embedded
/// media_kit `NativePlayer` or the native Linux mpv IPC socket. Pure so the
/// parsing is unit-testable without a live mpv instance; anything that isn't
/// a recognised flag string (including an empty/failed read) is "not eof".
bool parseMpvEofFlag(String? raw) {
  if (raw == null) return false;
  switch (raw.trim().toLowerCase()) {
    case 'yes':
    case 'true':
      return true;
    default:
      return false;
  }
}

/// The exportable line for a detected upstream EOF: credential-free,
/// durations only. [aheadMs] is the media still cushioned ahead of the
/// playhead at the moment the demuxer itself reached end-of-input — the
/// figure that answers whether the provider's connection had been dead for a
/// while before playback actually caught up to it.
String upstreamEofLogLine(int aheadMs) => 'live upstream ended ahead=${aheadMs}ms';
