# Cloud sync + profiles — full detail

A **web panel** lets users manage their source list with a real keyboard instead of a TV remote;
devices **pull** it down with no on-device login, and can optionally **push** their local list
back up (two-way). It's entirely optional — when the Supabase build config is absent the feature
hides itself and the app is unchanged. The compact rules live in CLAUDE.md; read this before
changing sync, pairing, profiles, or anything under `supabase/`.

## Backend

Supabase (the only free option bundling Postgres + Auth + RLS + a client SDK that's safe to call
directly from a static page). Schema + the entire security boundary live in
[`supabase/migrations/`](../supabase/migrations/) (timestamped `<version>_<name>.sql`, the first
is the schema + RLS) — read the first file's header before changing it. Five tables (`profiles`,
`sources`, `metadata_configs`, `devices`, `pairings`) with **deny-by-default RLS** (no policy = no
access) and `SECURITY DEFINER` RPCs: three pairing
(`request_pairing`/`pairing_status`/`claim_pairing`), the profile-scoped push
(`push_sources`/`push_metadata`/`push_favorites`, each `(payload, p_profile_id)`), and
`set_device_profile`. Migrations are applied to the live project and re-applying is idempotent;
the Supabase GitHub integration auto-applies new ones on push.

## Cloud profiles

An account holds multiple named `profiles`; each is a complete setup — its `sources` (which carry
a `profile_id` and a per-source `settings` jsonb for hidden categories), `metadata_configs`
(re-keyed to one row per profile), and the profile's `favorites` jsonb. A device's
`devices.active_profile_id` is which profile it syncs; the device picks it (panel only
creates/renames profiles). The `..._profiles.sql` migration backfills a `Default` profile per
existing owner, so a single-profile account is unchanged. Owner-scoping stays the security
boundary (`profile_id` is only an added filter); legacy 1-arg `push_*` delegate to the device's
active profile for older app builds.

## Open-source security model

The Supabase URL + **anon/publishable** key ship in the app and the panel (safe *by design* —
access is gated only by RLS). The `service_role` key must never appear in any client or this
repo. Devices authenticate as **anonymous** Supabase users with **no direct table writes** (every
write policy requires `is_real_user()`); they gain read access only after a real account claims
their pairing code (`claim_pairing`). The optional **push** is the one device→cloud write path
and goes through the `push_sources`/`push_metadata` `SECURITY DEFINER` RPCs, which are
owner-scoped via `current_device_owner()`: an *unpaired* anonymous caller has no owner and is
rejected, and a payload can't touch another account's rows (insert forces `owner = o`; the
upsert's `DO UPDATE` is guarded by `owner = o`). A paired device can already read all of its
owner's credentials, so writing that **same** owner's list adds no cross-account blast radius.
Pairing codes are short-lived + rate-limited. Push uses last-write-wins **refined by a
field-preserving server-side merge** (see "Credential round-trip" below): a device push replaces
the profile's source set and reorders it, but per source the `fields` (and per profile the
metadata `config`) merge through `merge_preserving_nonempty(stored, incoming)`, so a push can add
or change a field but can never blank a stored non-empty value — only a direct panel edit can.
Every `SECURITY DEFINER` function pins `search_path = ''` with schema-qualified references
(the profile-cap trigger is `SECURITY INVOKER` and serializes concurrent inserts per owner with a
transaction-scoped advisory lock, so the cap of 20 holds under parallel creation).

### Last-write-wins and timestamp authority

Conflict resolution is last-write-wins at the row level: a push deletes the profile's sources that
aren't in the payload and upserts the rest (and reorders them). At the **field** level it is
refined by the field-preserving merge below — the incoming non-empty values win, but a
missing/blank incoming value can't overwrite a stored non-empty one. Timestamp
authority is the **server** — `updated_at` is stamped by the `touch_updated_at` BEFORE-UPDATE
trigger and explicit `now()` in the push RPCs; the snapshot-revision triggers also advance it for
source and metadata inserts, updates, and deletes. Clients send no timestamps and none are
compared.
Concurrent writers therefore resolve by write order, not clock, so clock skew and equal client
timestamps are irrelevant. A pull always reflects whatever the last successful write left in the
row.

### Credential round-trip (Phase 1) and the E2EE ladder

Devices carry the **full** `fields` (credentials included) in both directions, and metadata API
keys ride the same path. This deliberately reverses the earlier device-side credential stripping
(commit d45d350), which had made two-way sync lossy: a device once pushed only a "cloud-safe"
projection (an Xtream `host` with no `username`/`password`, no m3u `playlistUrl` at all, and
metadata config without its API keys), so a push wholesale-replaced the row and **blanked** the
credentials a user had entered in the panel; the device then re-overlaid whatever local secrets it
had on pull, which only masked the loss on that one device.

Phase 1 established that a device push can never blank a stored non-empty value (the
`merge_preserving_nonempty` field-preserving merge on the push RPCs; only a direct panel edit can
clear a field). Phase 2/3 (below) split *secret* keys out of the broadly-readable rows entirely,
so the credential-bearing columns no longer carry credentials at all — but the same
never-blank-a-secret guarantee still holds through the secret RPCs' absent-means-preserve
semantics, and the broad `merge_preserving_nonempty` merge is unchanged.

## Isolated secrets + opt-in E2EE (Phase 2/3)

Secrets no longer live in the broadly-readable rows. The cloud `sources.fields` and
`metadata_configs.config` carry only **broad** keys; the **secret** keys travel through dedicated
RPCs and, when a profile opts into end-to-end encryption, are encrypted client-side under a
per-profile **content key (CK)** the server never sees in the clear.

### What is a secret

`lib/data/secret_keys.dart` is the canonical split. Source secret keys:
`{mac, username, password, playlistUrl, epgUrl, userAgent}`; metadata secret keys:
`{tmdbApiKey, tvdbApiKey, tvdbPin, mdblistApiKey}`. Everything else (`portal`, `host`,
`playlistExpiryHint`, provider choice, `autoEnrich`, per-source `settings`) is broad. `portal`/
`host` stay broad on purpose — they name the provider (so the panel and sources screen show a
recognisable subtitle) but can't stream on their own. A **server-side strip trigger** enforces
broad-only on the rows, so even a device that skips the split can't leak a secret into the
broad table.

### Server contract (RPCs the device calls)

- `get_secrets(p_profile_id)` → `{"sources":{"<source_id>":{"format":0|1,"payload":…}}, "metadata":{"format":0|1,"payload":…}|null}`.
- `push_sources(payload, p_profile_id)` — each source element **may** carry a `secret:
  {"format":0|1,"payload":…}`. **Absent = preserve** the stored secret server-side; the device
  sends the element only when it *knows* the secret. The server rejects a format that doesn't
  match the profile (E2EE profiles accept only `format` 1 at the current `ck_version`; plaintext
  profiles only `format` 0).
- `push_metadata(p_config, p_profile_id, p_secret)` — the new 3-arg form; `p_config` is broad
  only, `p_secret` is the same secret element (absent/null = preserve).
- `get_crypto_state(p_profile_id)` → `{enabled, ck_version}`.
- `set_device_public_key(p_public_key)` — idempotent registration of this device's public key.
- `get_device_ck(p_profile_id)` → `{ck_version, wrapped_ck}|null` — the CK wrapped **to this
  device**. `null` means this device isn't provisioned yet (locked).

`get_profile_crypto` / `provision_device_ck` / `enable` / `disable` / `rotate_content_key` are
**panel-only** and never called from Dart. Every one of these RPCs may throw "function does not
exist" against a pre-migration backend; the client treats that as **"no cloud secrets available"**
and degrades to broad-only sync — it never crashes (`isMissingFunctionError`).

### Crypto (`lib/data/cloud_crypto.dart`)

Primitives: PBKDF2-HMAC-SHA256 (600 000 iterations in production; panel-side KEK — the read path
bounds an envelope's `iter` to **[100 000, 10 000 000]** in both `crypto.js` and `cloud_crypto.dart`;
before that bound existed the server's documented ≥100 000 floor validated `profile_crypto
.kdf_iterations`, a column *no read path consults*, so `iter: 1` was accepted silently and a huge
one wedged the tab — confidentiality never depended on it, but the stated control was inert),
HKDF-SHA256,
AES-256-GCM (12-byte random IV, 128-bit tag), ECDH P-256. **Note:** `package:cryptography` 2.9.0
ships no working ECDH on the Dart VM or native Flutter (`DartEcdh` throws), so the P-256 curve is
implemented in pure Dart in `cloud_crypto.dart` and validated against the RFC 5903 §8.1
known-answer vector. The ECDH shared secret is the X coordinate encoded as **exactly 32 bytes,
big-endian, left-padded** (a leading-zero X must round-trip — pinned by a dedicated fixture case).

Envelopes are JSON; every binary field is **standard base64 (RFC 4648, with padding — never
base64url)**:

- **Secret** (`format` 1): `v`=1, `alg`="A256GCM", `ckv`, `iv`, `ct` (`ciphertext||tag`).
  Plaintext = UTF-8 of the secret map as **canonical JSON** (keys sorted ascending, no
  whitespace). AES key = the CK.
- **Device-wrapped CK**: `v`, `alg`, `kdf`="HKDF-SHA256", `ckv`, `epk` (65-byte uncompressed
  `0x04||X||Y`), `iv`, `ct`. AES key = HKDF-SHA256(ikm = ECDH shared X, salt = empty, info = AAD).
- **CK-under-KEK** (panel-side, passphrase): `kdf`="PBKDF2-SHA256", `salt`, `iter`, plus the usual
  fields.

The **AAD is always reconstructed from context** (never read from the envelope) and passed to
AES-GCM; `ckv` is additionally cross-checked against the expected content-key version. AAD strings:

- source secret — `iptvs.secret.v1|source|<profile_id>|<source_id>|<ck_version>`
- metadata secret — `iptvs.secret.v1|metadata|<profile_id>|<ck_version>`
- CK-under-KEK — `iptvs.kek.v1|<profile_id>|<ck_version>`
- device wrap — `iptvs.devicewrap.v1|<profile_id>|<device_uid>|<ck_version>`

Every decrypt/version/auth failure throws `CloudCryptoException` and **fails closed** — a decrypt
path never returns an empty map or silently drops a credential. The cross-language interop gate is
`test/fixtures/crypto_vectors.json` (published RFC/NIST KATs + self-generated end-to-end vectors,
authored by the Dart side, asserted by both `test/cloud_crypto_test.dart` and the panel's Node
tests).

### Device lifecycle + the LOCKED state

On first cloud use the device generates a P-256 key pair (`generateP256KeyPair`), persists the
private scalar in the keychain (`cloud_device_priv_key`/`cloud_device_pub_key`, alongside the
other secure-storage keys), and registers the public key via `set_device_public_key`. When
`get_crypto_state` reports `enabled`, the device fetches `get_device_ck`, unwraps the CK with its
private key (`decodeDeviceWrap`), and holds the CK **in memory only** (never persisted).

`CloudSync.cryptoStatus(profileId)` collapses this to three states (`CloudCryptoStatus`):

- **off** — E2EE disabled (or pre-migration). Secrets travel as `format` 0 (plaintext), still
  RLS+TLS protected.
- **ready** — E2EE on and the CK is unwrapped: pull decrypts, push encrypts (`format` 1).
- **locked** — E2EE on but no CK / unwrap failed / unknown `v`/`alg`/`ckv`. **Devices never prompt
  for the passphrase** (TV constraint). A locked device: shows the actionable message *"This
  profile is end-to-end encrypted. Open the panel and unlock it to finish setting up this
  device."*, **has Push disabled entirely**, pulls broad fields only, and marks any source without
  a locally-known secret as **needs-attention** in the sources screen (badge + snackbar; a source
  with empty credentials is never activated — fail closed).

**Defensive local overlay (pull):** after merging broad fields with the decrypted secret, the pull
overlays the device's existing local config for any secret key the cloud left absent/empty
(`fillGapsFromLocal`, `MetadataConfig.fromCloudParts`). Cloud non-empty always wins; local only
fills gaps. So a locked device — or a partially-migrated profile — never blanks a credential the
device already holds.

**Source-move clears the secret:** a source's secret is bound to its `source_id` through the AAD.
Moving/re-creating a source (a new `source_id`) means the old ciphertext can't be decrypted under
the new id, so the secret does not follow — the panel/device must re-enter it. This is intentional
(the AAD binding is what stops a secret being replayed under a different source).

### Panel Security UI + hardening

The panel owns every crypto-admin flow (devices never see the passphrase). A per-profile
**Security** tab offers: Enable (passphrase entered twice + an explicit loss warning — losing the
passphrase means re-entering credentials), Unlock, Rotate passphrase, Rotate content key, Disable,
and Lock now.

**Passphrase policy (`panel/src/passphrase.js`).** The wrapped CK, its salt and its iteration count
all sit in one `profile_crypto` row, so the operator-in-the-threat-model gets an *offline* attack
with no rate limit and no lockout: **the passphrase's own entropy is the entire margin.** At 600 k
iterations that is ≈1.8 × 10⁴ guesses/s on one consumer GPU, so the former 8-character floor fell in
**minutes** for a typical human-chosen password (~22 bits). Raising KDF cost cannot fix this —
Argon2id at 64 MiB buys ≈4 bits, 1 GiB ≈8–9, against a ~28-bit shortfall — so the fix is entropy:
a **Generate** button produces a 6-word diceware phrase from a 1024-word list (**60 bits**) and is
the intended path, gated behind an "I have saved this" confirmation because loss is unrecoverable;
hand-typed entry is still allowed but floored at **16 characters**. The wordlist length must stay a
power of two (masked selection would otherwise be biased) and duplicate-free — both pinned by
`panel/test/passphrase.test.js`, because either failure silently halves entropy at runtime.

**`rotateContentKey` verifies the typed passphrase before minting anything.** `requireUnlocked`
only proves a *session* CK exists; it says nothing about what was typed into "Current passphrase".
Without the check a typo overwrote the stored `wrapped_ck` with one wrapped under the wrong KEK —
server-accepted, success toast, session still unlocked — after which the *correct* passphrase no
longer worked either and `disableE2ee` (which requires an unlocked session) was unreachable: the
profile became permanently unrecoverable from the panel. The guard re-derives the KEK and lets the
GCM tag reject, then constant-time-compares against the session key. Order is load-bearing and is
pinned by `panel/test/crypto_hardening.test.js`. The session unlock derives the KEK once per session and holds the unwrapped CK
**only in a module-closure variable** (`panel/src/secrets.js` — never `localStorage`/
`sessionStorage`), zeroed on lock, profile switch, auth change, and a **15-minute idle auto-lock**.
The Devices tab shows per-device provisioning for the profile with a "Send key" action when
unlocked (wraps the CK to that device's `public_key` → `provision_device_ck`). While a profile is
locked, source edits are **broad-only** — the stored secret is preserved, never blanked — and
adding a new secret-bearing source is blocked. Enable/disable/rotate-content-key pass the
`profiles.updated_at` they observed as `p_expected_revision`; a concurrent device push surfaces a
friendly "changed since read — retry".

All panel pages ship a strict **CSP** (no inline scripts/styles, `connect-src` limited to self +
the Supabase origin; the legal pages run with `script-src 'none'`), injected at build time by
`panel/vite.config.js`. This is part of the threat boundary below: the CSP is what makes "XSS'd
panel" a hard target rather than a soft one.

The policy deliberately carries **no `frame-ancestors`**. The panel is static files on GitHub
Pages, which cannot set response headers, so the CSP can only be delivered by `<meta
http-equiv>` — and `frame-ancestors` is **ignored by spec** when delivered that way. It enforced
nothing and only logged a console warning, while advertising clickjacking protection the panel
did not have. Anti-framing is instead enforced by **`panel/src/framebust.js`**, the mandatory
*first* import of `main.js`: ES module dependencies evaluate in source order, so it throws before
the entry graph evaluates and a framed panel builds no UI and attaches no listeners. It refuses
to run rather than busting out — no `top.location = …`, which would make the panel an
open-redirect gadget — and offers the user a plain link to the real origin instead. This matters
because the panel is exactly the surface worth framing: passphrase entry, provider credential
fields, and the device "Send key" action. Keep that import first. If the panel ever moves to a
host that can send headers, serve this policy as a real `Content-Security-Policy` header and
restore `frame-ancestors 'none'` there.

### Threat boundary

E2EE **protects** the credential/API-key secrets against: the database at rest, a Supabase
operator or insider **reading** the tables, and an RLS bug that over-exposes the *broad* tables —
none of those ever see plaintext secrets, only ciphertext they can't unwrap without the CK. **That
protection reduces entirely to the offline strength of the passphrase** (see "Passphrase policy"
above): the wrapped CK, salt and iteration count are all in one row, so a reader of that row gets
an unlimited offline attack. This is the whole reason the generator exists.

It **does not protect** against: a compromised or XSS'd panel *while it is unlocked* (it holds the
CK in memory and can read/rewrite secrets), or a malicious already-paired device that legitimately
holds the CK.

**An *active* (writing) backend is a third category, and it is outside the guarantee.** The earlier
wording covered only an operator who *reads*; an operator or compromised backend that also
**writes** defeats E2EE by other routes, and both clients currently trust the server on these:

- **Downgrade to plaintext.** Both clients decide whether to encrypt from `get_crypto_state.enabled`
  (`secrets.js` `encodeSecretElement`, `cloud_sync.dart` `_CryptoState`). A backend answering
  `{enabled: false}` makes every client push provider credentials and metadata API keys in
  `format 0`. The server-side format gate is the stated defence, but it lives in the same trust
  domain as the attacker. Neither client remembers that a profile *was* E2EE.
- **Content-key rollback.** `cloud_sync.dart` takes `ck_version` from the very `device_ck` row it is
  about to unwrap and never compares it to the version `get_crypto_state` reported, so a backend
  serving a consistent pre-rotation bundle pins a device to a **revoked** generation.

Consequently, "`rotate_content_key` … makes every old-version envelope fail its `ckv` check" holds
against a device that knows the current `ck_version` — i.e. **rotation is a remedy for a compromised
device, not for a compromised backend**. Revocation cannot un-leak a CK a device already cached; the
remedy for a suspected device compromise remains `rotate_content_key` (panel-side), which mints a
new `ck_version`, re-wraps to the still-trusted devices, and invalidates old-version envelopes.

Closing the two bullets above needs client-side sticky state (a per-profile "was enabled" flag and a
monotonic `ck_version` high-water mark in secure storage). **Not yet implemented** — recorded here
rather than left implied, because a boundary that reads as complete and isn't is worse than a
documented gap.

### Validation limits and rate limiting

Writes are bounded at two layers (`..._harden_cloud.sql`): **BEFORE INSERT/UPDATE triggers** on
`sources`/`profiles`/`metadata_configs` call shared `assert_*` helpers — binding the panel's
*direct* table writes as well as the RPCs — and each push RPC additionally checks the top-level
array count and byte size **before any mutation**. Rejections raise `check_violation` with a
stable `iptvs: ` message prefix and never interpolate payload values (a raw CHECK constraint was
deliberately rejected: its "Failing row contains (…)" detail would leak credentials through
client error surfaces). Limits are sized ≥10x above realistic maxima from the 250k-channel
validation corpus — e.g. 200,000 favorites, 50,000 hidden-category ids per kind, 8 KiB per field
value, 16 MB payload ceilings — so a legitimate user on a huge portal is never rejected. The
push RPCs are rate-limited DB-side (`check_push_rate`, 30 calls/min per device session —
deliberately per-device, not per-owner, since two devices on one account are independent
human-driven callers — one self-resetting row per subject in the policy-less `push_rate`
table, reaped on account deletion). Reads/pulls are deliberately unthrottled
(PostgREST has no per-user limit and an Edge proxy isn't justified) — accepted risk, mitigated
by RLS scoping and the payload caps. Client-side, the panel's `friendlyError` and the app's
`friendlyCloudError` show `iptvs: `-prefixed messages as-is and reduce everything else to
generic text — Postgres `details`/`hint` are never rendered.

## Pairing flow (code-based, works on every platform)

The device shows a code ([`cloud_sync_screen.dart`](../lib/screens/cloud_sync_screen.dart)); the
user enters it in the panel's Devices page; the device polls `pairing_status` until claimed, then
pulls. Once paired, the screen shows a **profile picker** (list the account's profiles, switch →
`set_device_profile` + re-pull) and offers **Pull now** / **Push to panel** (push confirms first,
since it overwrites that profile).

## Flutter side

[`cloud_config.dart`](../lib/data/cloud_config.dart) (build-time `--dart-define`
`SUPABASE_URL`/`SUPABASE_ANON_KEY`/`PANEL_URL`; `isConfigured` gates the whole feature),
[`cloud_sync.dart`](../lib/data/cloud_sync.dart) (`CloudSync`: anon session, pairing, profile
selection (`listProfiles`/`activeProfileId`/`setProfile`), and profile-scoped
`pullSources`/`pullMetadata`/`pullFavorites` + `pushSources`/`pushMetadata`/`pushFavorites`.
Sources/metadata write through `SourceStore`; favorites use `AppDatabase` and are mapped between
the credential-derived `Source.id` (local key) and the `SourceConfig` UUID (cloud key) via
`config.build().id`. Cloud-managed source ids are tracked in secure storage so a pull replaces
the managed set in panel order but leaves local-only sources alone). Source ids are UUIDs
(`newSourceId`/`isUuid` in [`source_config.dart`](../lib/sources/source_config.dart)) so they
round-trip through the `uuid`-typed cloud column; push rewrites any legacy non-UUID id first.
[`secure_local_storage.dart`](../lib/data/secure_local_storage.dart) persists the Supabase session
in the keychain, not plaintext prefs. Init is in `main.dart`, behind `isConfigured`.
[`secret_keys.dart`](../lib/data/secret_keys.dart) is the broad/secret split;
[`cloud_crypto.dart`](../lib/data/cloud_crypto.dart) is the pure crypto surface (envelopes, AAD,
the pure-Dart P-256). The device P-256 key pair persists in the keychain
(`cloud_device_priv_key`/`cloud_device_pub_key`) via the same `FlutterSecureStorage` as the rest.
The pure mappers/helpers (`cloudRowToConfig`, the id helpers, `splitFields`/`mergeFields`/
`fillGapsFromLocal`, `buildSecretElement`/`decodeSecretEntry`, `isMissingFunctionError`,
`MetadataConfig.fromCloudParts`, `sourceCredentialsMissing`) are unit-tested in
`test/cloud_sync_test.dart`; the crypto vectors + fail-closed cases in `test/cloud_crypto_test.dart`.

## Web panel

[`panel/`](../panel/) — a tiny Vite + `@supabase/supabase-js` SPA (no framework). **Magic-link
sign-in only** (no OAuth). Field shapes mirror `SourceConfig` per kind. Sources carry an integer
`position` and the list has **↑/↓ reorder** controls (positions self-heal to a clean `0..n-1` on
reorder; new sources append); devices show sources in that order. Branded with the app icon
(`panel/public/icon.png`, copied from `assets/icon/`). Deployed to **GitHub Pages** by
[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) (`upload-pages-artifact@v5` +
`deploy-pages@v5`; Supabase values from repo Variables). Note: the Flutter web target lives in
`web/`; the panel deliberately lives in `panel/`.

## Profiles (device-side)

The app boots into `ProfilePickScreen` (`main.dart` `home:`, `bootMode: true`) — a "Who's
watching?" grid that combines **cloud profiles** (only when built with Supabase config *and*
paired) and **local profiles**, which need no cloud at all. At boot the screen decides for itself
whether to appear: `shouldShowPickerAtStartup(mode, profileCount)` with the persisted
`ProfilePickerStartup` mode (`auto` = only when >1 profile, `always`, `off`; cycled from a
`FocusableCard` row atop `sources_screen.dart`) — otherwise it silently short-circuits to
`HomeShell`, so a single-profile install boots exactly as before. Profiles are also reachable
from the channel-list AppBar avatar (`ProfileAvatarButton` → "Change profile") and a Profiles
action on the sources screen.

Isolation model (`lib/data/local_profile_store.dart`): every profile — local *and* cloud — owns a
`ProfileSnapshot` of the device state (source list + active source + metadata config + the
cloud-managed ids set from `CloudSync.managedSourceIds`). Switching away snapshots the current
state into its owner; switching to a local profile restores its snapshot verbatim (including an
empty list — and clears the managed-ids set so a later cloud "Pull now" can't merge cloud sources
into a local profile); switching to a cloud profile restores its snapshot first (its device-local
extra sources + managed ids), then does the normal `setProfile` + pull. This keeps `pullSources`'s
"preserve non-managed sources" semantic working on the right baseline and prevents cross-profile
source leaks. New local profiles are seeded with only the Demo source. Local profiles can be
deleted in the picker's manage mode; cloud profiles are managed in the web panel.

**Deleting the *active* profile** needs care: at delete time that profile's device state is still
live in the store, and the picker must not let it leak or be mis-attributed. So deleting the
profile you're currently "in" resets the live state to a neutral empty baseline
(`_restoreSnapshot(const ProfileSnapshot())`) and marks **no** profile active — the picker never
auto-promotes another entry to "active" just because it's first in the list. This is what
guarantees the core invariant: *no profile's stored snapshot is ever overwritten with state that
isn't its own.* The mechanism relies on two things staying true — the parking write
(`_snapshotCurrent`) is a no-op while no profile is active, and `_check` only marks a profile
active when a genuine persisted selection (local `activeId` / cloud `active_profile_id`) points at
it. Selecting a profile afterwards restores its snapshot through the normal switch path. Deleting a
*non-active* profile leaves the active profile and its live state untouched. Single-profile
short-circuit (`shouldShowPickerAtStartup`) is unaffected: an install with one profile still boots
straight to `HomeShell`, since that profile carries a persisted active id.

JSON round-trips, the startup decision, and the stable cloud-avatar colour hash are unit-tested in
`test/profile_store_test.dart`; the deletion contract (non-active delete, delete-active with others
present / as the last profile, and the `friendlyCloudError` surface) is pinned by
`test/profile_pick_screen_test.dart`.
