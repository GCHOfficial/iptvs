/// Matching an XMLTV guide's channels onto ours.
///
/// The historical path is exact: a guide's `<programme channel="…">` id is
/// looked up in a `tvg-id → our channel id` map built from the playlist's own
/// `tvg-id` attributes, and anything unmatched is dropped. That is correct and
/// cheap for a *provider's own* guide, where both sides come from the same
/// panel and the ids agree by construction.
///
/// It contributes close to nothing for a **third-party** guide, which is the
/// whole point of letting a source carry more than one XMLTV URL: an
/// independent guide numbers its channels its own way, so almost every id
/// misses and the extra guide lands empty. Hence name matching — normalise both
/// sides' display names and claim what the ids couldn't.
///
/// Name matching is deliberately **exact-after-normalisation**, never fuzzy.
/// Edit-distance matching would paint a channel with another channel's
/// schedule, and wrong programme data is worse than none: the row looks
/// authoritative, the catch-up window is computed from it, and nothing about it
/// reads as a guess.
library;

import 'source.dart';

/// Whole-word tokens dropped from a channel name before comparing.
///
/// Stream-quality and packaging markers only — they distinguish two *feeds of
/// the same channel*, which share a schedule, so dropping them is what lets one
/// guide entry light up both the HD and the SD row of a playlist that carries
/// both.
///
/// Deliberately short. Every token added here merges two names that used to be
/// distinct, and a token that is *part of a channel's identity* rather than its
/// encoding (`plus`, `multi`, `ts`, `one`, `extra`) would silently collapse
/// genuinely different channels into one ambiguous key.
const Set<String> _qualityTokens = {
  'hd',
  'hdtv',
  'sd',
  'fhd',
  'uhd',
  'qhd',
  '4k',
  '8k',
  'hevc',
  'h265',
  'h264',
  // 'raw' is deliberately NOT here. Unlike the rest of this set it is part of
  // real channel identities — "WWE Raw" would normalise to `wwe` and collide
  // with a plain "WWE" channel, so one guide entry would paint WWE's schedule
  // onto WWE Raw. That is the "wrong data is worse than none" outcome this
  // library argues against. ('backup' stays: it is a feed marker, and no
  // channel is identified by the word.)
  'backup',
  '50fps',
  '60fps',
};

/// Accent folding for the Latin ranges an IPTV playlist actually carries.
///
/// Romanian (`ă â î ș ț`) matters here in particular: the same channel is
/// routinely spelled with and without diacritics across a playlist and a guide,
/// and with the comma-below vs cedilla variants of `ș`/`ț` — which are distinct
/// code points, so `Digi Sport` vs `Digi Șport` would otherwise never match.
const Map<String, String> _foldings = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ă': 'a',
  'ā': 'a', 'ą': 'a',
  'ç': 'c', 'ć': 'c', 'č': 'c',
  'ď': 'd', 'đ': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ě': 'e', 'ę': 'e', 'ē': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'į': 'i',
  'ł': 'l', 'ĺ': 'l', 'ľ': 'l',
  'ñ': 'n', 'ń': 'n', 'ň': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ő': 'o', 'ø': 'o',
  'ř': 'r', 'ŕ': 'r',
  'ś': 's', 'š': 's', 'ş': 's', 'ș': 's',
  'ť': 't', 'ţ': 't', 'ț': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ű': 'u', 'ū': 'u', 'ů': 'u',
  'ý': 'y', 'ÿ': 'y',
  'ź': 'z', 'ż': 'z', 'ž': 'z',
  'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

/// Separator run between name tokens.
///
/// Hoisted because [normalizeChannelName] runs once per channel and a large
/// portal carries 250k of them — building this pattern inside the function
/// allocated and compiled a `RegExp` per channel, on the main isolate.
final RegExp _nameSeparators = RegExp(r'[^a-z0-9]+');

/// A leading country/language tag: `RO: Digi Sport`, `UK | Sky Sports`,
/// `|FR| TF1`. Ubiquitous in IPTV playlists, absent from every real guide, so
/// without stripping it almost nothing matches.
///
/// Requires an explicit `:` or `|` separator and a 2–3 letter tag. A bare
/// leading word is **not** stripped — `Film Now` must not become `Now`.
final RegExp _leadingCountryTag = RegExp(r'^\s*\|?\s*([a-z]{2,3})\s*[:|]\s*');

/// Collapse a channel name to a comparison key, or `''` when nothing
/// identifying survives (an all-punctuation or quality-token-only name), which
/// callers must treat as unmatchable rather than as a key.
///
/// Parenthesised and bracketed content is deliberately **kept**: it is where
/// playlists put the disambiguator (`HBO (RO)` vs `HBO (HU)`), and dropping it
/// is what would let a guide paint one country's channel with another's
/// schedule.
String normalizeChannelName(String raw) {
  var s = raw.toLowerCase().trim();
  s = s.replaceFirst(_leadingCountryTag, '');
  final folded = StringBuffer();
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    folded.write(_foldings[ch] ?? ch);
  }
  // Split on anything non-alphanumeric so quality markers are dropped as whole
  // *words* — a substring rule would turn "Sharjah" into "Sarjah" via "h"…"d"
  // and, more plausibly, eat the "hd" inside "HDNet".
  final tokens = folded
      .toString()
      .split(_nameSeparators)
      .where((t) => t.isNotEmpty && !_qualityTokens.contains(t));
  return tokens.join();
}

/// Our channels indexed by [normalizeChannelName], for the name-matching pass.
///
/// A key maps to **every** channel that normalises to it, not to one: a
/// playlist routinely carries the same channel as separate HD and SD entries,
/// and both rows should show the schedule the one guide entry describes.
/// A name shared by more than this many of our channels is treated as
/// ambiguous and matches nothing.
///
/// Two costs meet here. A name that dozens of rows share is not a channel
/// identity but a generic label, and claiming all of them is more likely wrong
/// than right. And every claim *multiplies* the guide: programmes are stored
/// per `channel_id`, so one guide channel claiming N of ours writes N copies of
/// its schedule — on a 960k-programme guide (docs/validation-baseline.md) an
/// uncapped fan-out is a multi-million-row ingest.
///
/// Dropping the whole group rather than keeping the first few is deliberate:
/// there is no principled way to pick which variants win, and rule 3 already
/// says an ambiguous match goes to nobody. Name matching is purely additive
/// over the exact `tvg-id` path, so the cap only ever limits what it *adds* —
/// it can never take a guide away from a channel that had one.
const int kMaxNameMatchGroup = 8;

Map<String, List<String>> buildChannelNameIndex(List<Channel> channels) {
  final index = <String, List<String>>{};
  for (final c in channels) {
    final key = normalizeChannelName(c.name);
    if (key.isEmpty) continue;
    (index[key] ??= <String>[]).add(c.id);
  }
  index.removeWhere((_, ids) => ids.length > kMaxNameMatchGroup);
  return index;
}

/// The name index to use for a source carrying [extraCount] user-added guides
/// — empty when there are none.
///
/// **Name matching is for user-added guides only; a provider's own guide stays
/// on exact `tvg-id` matching.** Two reasons, and both are about not changing
/// what already works.
///
/// *Behaviour.* A provider's guide and its playlist come from the same panel,
/// so their ids agree by construction and names add nothing an id missed except
/// guesses. Turning it on there would silently change the EPG of every existing
/// install on upgrade: channels that had no guide can acquire one from a
/// same-normalised-name channel, and since programmes are stored per
/// `channel_id`, one guide entry claiming several of our rows multiplies a
/// ~10^6-programme ingest. Neither is something the user asked for by adding a
/// guide, because they added none.
///
/// *Cost.* [buildChannelNameIndex] is O(channels) with per-channel string work,
/// and it runs on the main isolate. Building it unconditionally would put
/// provider-sized map work on the UI thread on every EPG refresh for every
/// user, against a 250k-channel baseline — exactly what CLAUDE.md's
/// "don't add new parse/map work on the main isolate" rule is about. Gated, it
/// is paid only by users who opted in by adding a guide.
Map<String, List<String>> epgNameIndexFor(
  List<Channel> channels, {
  required int extraCount,
}) => extraCount <= 0 ? const {} : buildChannelNameIndex(channels);

/// Our channels' `tvg-id`s, for the exact-match pass. Shared by every source
/// that parses XMLTV.
Map<String, String> buildTvgIdIndex(List<Channel> channels) {
  final map = <String, String>{};
  for (final c in channels) {
    final tvg = c.extra['tvgId']?.toString();
    if (tvg != null && tvg.isNotEmpty) map[tvg] = c.id;
  }
  return map;
}

/// Resolves a guide's channel ids onto ours, over one streaming parse.
///
/// Usage is driven by XMLTV's document order, which the DTD fixes as
/// `(channel*, programme*)`: every `<channel>` declaration is fed to
/// [declareChannel], and the first [resolve] call — necessarily from a
/// `<programme>`, i.e. after the last declaration — freezes the claims. That is
/// what makes a single pass enough to let exact ids beat names *globally*
/// rather than merely in document order.
///
/// Claim rules, in order:
///
///  1. **A guide channel whose id is one of our `tvg-id`s claims that channel.**
///     Exact, and it beats every name claim — but only among the channels the
///     guide actually *declares*. A malformed guide that emits a programme for
///     an id it never declared cannot beat a name claim, because by then the
///     claims are frozen and that channel's rows are already written: honouring
///     it would stack a second schedule on the channel rather than replace the
///     first, which is the overlap all of this exists to prevent. See
///     [resolve].
///  2. **A guide channel whose *name* normalises onto ours claims it, but only
///     if step 1 left it unclaimed.** So a playlist whose `tvg-id`s are
///     provider-specific junk still gets a guide, while a channel the guide
///     already covers properly is never second-guessed.
///  3. **An our-channel contested by two guide channels goes to neither.** Two
///     names that normalise identically are genuinely ambiguous, and picking by
///     document order would be a coin flip rendered as fact.
///
/// A guide that declares no `<channel>` elements at all (some do skip them)
/// resolves purely through rule 1 — byte-for-byte the historical behaviour.
class XmltvChannelResolver {
  XmltvChannelResolver({
    required this.tvgIdToChannelId,
    this.nameToChannelIds = const {},
  });

  /// Our channels' `tvg-id`s (rule 1). Never mutated.
  final Map<String, String> tvgIdToChannelId;

  /// Our channels by normalised name (rule 2); empty disables name matching.
  final Map<String, List<String>> nameToChannelIds;

  /// Guide channel id → the display names it declared, in document order.
  final Map<String, List<String>> _declared = {};

  /// Guide channel id → our channel ids, once frozen.
  Map<String, List<String>>? _claims;

  /// Records one `<channel id="…">` declaration and its `<display-name>`s.
  /// Ignored once [resolve] has frozen the claims — a guide that interleaves
  /// declarations among its programmes gets the ones that arrived in time,
  /// rather than a mapping that changes halfway through the parse.
  void declareChannel(String guideId, Iterable<String> displayNames) {
    if (_claims != null || guideId.isEmpty) return;
    (_declared[guideId] ??= <String>[]).addAll(displayNames);
  }

  /// Our channel ids a guide programme on [guideId] applies to — empty when the
  /// guide channel is not one of ours. Freezes the claims on first call.
  ///
  /// A guide id the guide never *declared* is answered straight from the exact
  /// map, which is what keeps a declaration-less guide on exactly the
  /// historical path. That answer is memoised rather than rebuilt per
  /// programme: a real guide carries ~10^6 programmes over ~10^4 channels, so
  /// allocating the single-element list once per programme would be the
  /// dominant allocation of the whole parse.
  List<String> resolve(String guideId) {
    final claims = _claims ??= _freeze();
    final declared = claims[guideId];
    if (declared != null) return declared;
    return _undeclared.putIfAbsent(guideId, () {
      final exact = tvgIdToChannelId[guideId];
      // A channel a *name* already claimed is not re-claimed by an undeclared
      // id — that would be the same overlap rule 3 exists to prevent, arriving
      // through the back door.
      if (exact == null || _nameClaimed.contains(exact)) return const [];
      return [exact];
    });
  }

  /// True once [resolve] has been called and [declareChannel] is inert.
  bool get isFrozen => _claims != null;

  /// Memoised answers for guide ids that were never declared.
  final Map<String, List<String>> _undeclared = {};

  /// Our channel ids taken by rule 2, so an undeclared exact id can't also
  /// take them in [resolve].
  final Set<String> _nameClaimed = {};

  Map<String, List<String>> _freeze() {
    final claims = <String, List<String>>{};
    // Our channel id → the guide channel holding it. An entry survives a
    // contest even though the claim itself is revoked: it marks the channel
    // *taken*, so a third claimant can't quietly pick up what two others were
    // denied.
    final claimedBy = <String, String>{};

    void claim(String guideId, String channelId) {
      final existing = claimedBy[channelId];
      if (existing == guideId) return;
      if (existing != null) {
        // Contested (rule 3): revoke the earlier claim rather than choose.
        claims[existing]?.remove(channelId);
        _nameClaimed.remove(channelId);
        return;
      }
      claimedBy[channelId] = guideId;
      (claims[guideId] ??= <String>[]).add(channelId);
    }

    // Rule 1 — exact ids. Iterates the *guide's* declarations, not our
    // `tvg-id` map: the latter runs to one entry per channel (250k on a large
    // portal), and walking it here would build a second map that size for no
    // gain. An id the guide declares but we don't carry simply misses, and one
    // we carry but the guide never declares is answered by [resolve]'s
    // fallback.
    for (final guideId in _declared.keys) {
      final channelId = tvgIdToChannelId[guideId];
      if (channelId != null) claim(guideId, channelId);
    }
    final exactlyClaimed = Set<String>.of(claimedBy.keys);

    // Rule 2 — names, for whatever rule 1 left unclaimed. Contests are settled
    // by [claim], **not** skipped here: two guide channels whose names
    // normalise alike must both lose the channel, and a pre-emptive `continue`
    // would instead hand it to whichever was declared first.
    for (final entry in _declared.entries) {
      for (final name in entry.value) {
        final key = normalizeChannelName(name);
        if (key.isEmpty) continue;
        final candidates = nameToChannelIds[key];
        if (candidates == null) continue;
        for (final channelId in candidates) {
          if (exactlyClaimed.contains(channelId)) continue;
          claim(entry.key, channelId);
          if (claimedBy[channelId] == entry.key) _nameClaimed.add(channelId);
        }
      }
    }

    claims.removeWhere((_, ids) => ids.isEmpty);
    return claims;
  }
}
