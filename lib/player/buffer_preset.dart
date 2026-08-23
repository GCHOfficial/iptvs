/// How much media to hold ahead of playback — a user-facing, per-source choice.
///
/// The right answer is a property of the *link*, not of the app: a clean wired
/// connection wants short buffers and instant zapping, a flaky or throttled one
/// wants depth, and no single default serves both. We shipped one point on that
/// curve and gave users nothing when it was the wrong one.
///
/// A three-way preset rather than raw millisecond fields, deliberately. Four
/// interacting durations is a knob people copy out of forum posts, and an
/// invalid combination — a resume threshold above the stall watchdog's patience
/// — is a reconnect loop we would then have to explain. The presets are also
/// the unit both engines can agree on: ExoPlayer takes four `LoadControl`
/// durations, mpv takes cache seconds and a byte cap, and neither maps onto the
/// other's numbers.
///
/// **What it cannot do:** a deeper buffer converts frequent short stalls into
/// rarer long ones. It does not add bandwidth, so it is not a fix for a
/// saturated or throttled link — that is worth saying in the UI, because it is
/// the most common misreading of the setting.
library;

/// The presets, smallest cushion first.
enum BufferPreset {
  low,
  normal,
  high;

  /// The value stored in `SourceConfig.settings['bufferPreset']` and sent to
  /// the native players.
  String get storageName => name;
}

/// Parses a stored or transported preset name; anything unrecognised — including
/// a value written by a newer build — is [BufferPreset.normal], matching the
/// Kotlin `BufferPreset.fromName` fallback.
BufferPreset bufferPresetFromName(String? name) => switch (name?.toLowerCase()) {
  'low' => BufferPreset.low,
  'high' => BufferPreset.high,
  _ => BufferPreset.normal,
};

/// The next preset in the settings tile's cycle (low → normal → high → low).
BufferPreset nextBufferPreset(BufferPreset current) =>
    BufferPreset.values[(current.index + 1) % BufferPreset.values.length];

/// mpv properties for [preset], layered over [kLiveMpvOptions].
///
/// **Only `cache-secs`.** It is the lever that matters for a live HTTP stream —
/// how far ahead the demuxer prefetches once the stream cache is active — and,
/// unlike ExoPlayer's `bufferForPlaybackMs`, it is *not* a start gate: mpv
/// begins playing as soon as it can decode. Raising it therefore buys stall
/// resistance without costing zap latency, which is why the mpv side can afford
/// a proportionally deeper `high` than the ExoPlayer side.
///
/// **`demuxer-max-bytes` is deliberately not set here, and the reason is a
/// correction worth keeping.** It looked like the natural companion knob, but
/// media_kit already owns it: `PlayerConfiguration.bufferSize` maps straight
/// onto it, and this app sets it *per surface* — 64 MB for the fullscreen
/// player, media_kit's own default for the preview. Setting it from the preset
/// would silently override two deliberate, different choices with one, and on
/// the VOD path it would retune a cache sized for seek smoothness using a
/// control whose UI talks about live playback. The byte cap still bounds a deep
/// `cache-secs` — the prefetch simply stops at whichever limit comes first,
/// which degrades gracefully instead of growing without limit on a 2 GiB TV box.
///
/// [BufferPreset.normal] is empty for the same reason the iOS mapping returns
/// nil: whatever mpv and media_kit already do is what every build so far has
/// shipped, and "normal" has to mean exactly that rather than a tuning that
/// happens to resemble it.
Map<String, String> mpvBufferOptions(BufferPreset preset) => switch (preset) {
  BufferPreset.low => const {'cache-secs': '3'},
  BufferPreset.normal => const {},
  BufferPreset.high => const {'cache-secs': '30'},
};

/// Short label for the settings tile.
String bufferPresetLabel(BufferPreset preset) => switch (preset) {
  BufferPreset.low => 'Small',
  BufferPreset.normal => 'Normal',
  BufferPreset.high => 'Large',
};

/// One-line explanation of the trade, for the tile's subtitle.
///
/// Each says what it costs as well as what it buys — a preset that only
/// advertises its upside is one users ratchet to maximum and then report the
/// downside of as a separate bug.
String bufferPresetHint(BufferPreset preset) => switch (preset) {
  BufferPreset.low =>
    'Playback starts slightly faster, but a brief network hiccup is more likely '
        'to interrupt it.',
  BufferPreset.normal => 'Balanced. Use this unless playback stutters.',
  BufferPreset.high =>
    'Rides out an unsteady connection. Uses more memory; it cannot help if the '
        'connection is simply too slow.',
};
