/// Canonical split between *broad* (cloud-safe) fields and *secret* (credential /
/// locator) fields for cloud sync's Phase-2 isolated-secrets model.
///
/// In the cloud, a source row's `fields` and a metadata config carry **only the
/// broad keys**; every secret key travels through the dedicated secret RPCs
/// (`get_secrets` / the `secret` element on `push_sources` / `p_secret` on
/// `push_metadata`) and, when a profile has opt-in E2EE enabled, is encrypted
/// client-side under the content key (see [cloud_crypto.dart]). A server-side
/// strip trigger enforces broad-only on the `sources`/`metadata_configs` rows,
/// so a device that never applies this split cannot leak a secret into the
/// broadly-readable table.
///
/// The device carries the **full** field set locally (in the keychain via
/// `SourceStore`); the split is applied only at the cloud boundary.
library;

/// Secret keys of a source's `fields` map. Everything else (`portal`, `host`,
/// `playlistExpiryHint`, catch-up overrides in `settings`, …) is broad.
///
/// - `mac` — Stalker MAC (the portal's per-device credential).
/// - `username` / `password` — Xtream credentials.
/// - `playlistUrl` — the M3U locator, which typically embeds credentials in a
///   query string or path.
/// - `epgUrl` — an optional M3U EPG locator, likewise credential-bearing.
/// - `epgUrls` — additional XMLTV guide locators (newline-separated), for the
///   same reason: a guide URL carries credentials as often as a playlist does.
/// - `userAgent` — an optional M3U request header some providers key access on.
///
/// `portal`/`host` are deliberately **broad**: they identify the provider but
/// are not on their own sufficient to stream, and keeping them in the broad row
/// lets the panel and the sources screen show a recognisable subtitle.
const Set<String> kSourceSecretKeys = {
  'mac',
  'username',
  'password',
  'playlistUrl',
  'epgUrl',
  'epgUrls',
  'userAgent',
};

/// Secret keys of a metadata config. The provider choice and `autoEnrich` flag
/// are broad; the API keys/PIN are secret.
const Set<String> kMetadataSecretKeys = {
  'tmdbApiKey',
  'tvdbApiKey',
  'tvdbPin',
  'mdblistApiKey',
};

/// Splits [fields] into `(broad, secret)` against [secretKeys].
///
/// `broad` is every entry whose key is **not** in [secretKeys] (values kept
/// verbatim, including empties). `secret` is every entry whose key **is** in
/// [secretKeys] **and** whose value is non-empty — an empty secret value is
/// dropped so it reads as *absent* ("the device doesn't know this secret"),
/// which the push path treats as "preserve whatever the server has" rather than
/// "blank it".
(Map<String, String> broad, Map<String, String> secret) splitFields(
  Map<String, String> fields,
  Set<String> secretKeys,
) {
  final broad = <String, String>{};
  final secret = <String, String>{};
  for (final e in fields.entries) {
    if (secretKeys.contains(e.key)) {
      if (e.value.isNotEmpty) secret[e.key] = e.value;
    } else {
      broad[e.key] = e.value;
    }
  }
  return (broad, secret);
}

/// Merges a `(broad, secret)` split back into one field map. Secret entries win
/// over broad entries with the same key (there should be no overlap, but secret
/// is authoritative for a credential key if a legacy broad row still carries
/// one). Empty incoming values never overwrite a non-empty existing one.
Map<String, String> mergeFields(
  Map<String, String> broad,
  Map<String, String> secret,
) {
  final out = <String, String>{...broad};
  for (final e in secret.entries) {
    if (e.value.isNotEmpty) out[e.key] = e.value;
  }
  return out;
}

/// Overlays [local] onto [merged] as a belt-and-suspenders defensive fallback
/// (adversarial amendment B1): for any [keys] the cloud left absent/empty, keep
/// the device's existing non-empty local value. Cloud non-empty always wins;
/// local only *fills gaps*. Used on pull so a locked or partially-migrated cloud
/// profile can never blank a credential the device already holds.
Map<String, String> fillGapsFromLocal(
  Map<String, String> merged,
  Map<String, String> local,
  Set<String> keys,
) {
  final out = <String, String>{...merged};
  for (final key in keys) {
    final cloudValue = out[key];
    if (cloudValue != null && cloudValue.isNotEmpty) continue;
    final localValue = local[key];
    if (localValue != null && localValue.isNotEmpty) out[key] = localValue;
  }
  return out;
}
