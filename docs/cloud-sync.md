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
is the schema + RLS) — read the first file's header before changing it. **Ten** tables with
**deny-by-default RLS** (no policy = no access): five client-facing (`profiles`, `sources`,
`metadata_configs`, `devices`, `pairings`) that carry policies, and five **RPC-only** ones
(`source_secrets`, `metadata_secrets`, `profile_crypto`, `device_ck`, `push_rate`) that
deliberately have **zero** policies — RLS-enabled with no policy denies everything, so they are
reachable only through `SECURITY DEFINER` functions. The advisor reports those five as
`rls_enabled_no_policy` INFO; that is the design, not a gap. Since `20260727000000_tenant_isolation`
they also have **no table-level grants** to `anon`/`authenticated`, so the protection is two-layer
rather than resting solely on "zero policies".

**Ownership is enforced by the schema, not only by RPC predicates.** `profiles` and `sources` carry
a redundant `unique (id, owner)`, and every owner-bearing child (`sources`, `metadata_configs`,
`source_secrets`, `metadata_secrets`, `profile_crypto`) is pinned by a **composite foreign key**
`(parent_id, owner) → parent(id, owner)`. A row whose owner disagrees with its parent's is therefore
unrepresentable — for the RPCs, for the panel's direct RLS writes, and for anything added later.

Then `SECURITY DEFINER` RPCs: three pairing
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
active profile for older app builds. A profile may also carry an optional `pin` — see
[Profile PINs](#profile-pins).

## Open-source security model

The Supabase URL + **anon/publishable** key ship in the app and the panel (safe *by design* —
access is gated only by RLS). The `service_role` key must never appear in any client or this
repo. Devices authenticate as **anonymous** Supabase users with **no direct table writes** (every
write policy requires `is_real_user()`); they gain read access only after a real account claims
their pairing code (`claim_pairing`).

**An anonymous user is created only when the user opts in, never on the boot path.**
`CloudSync.ensureAnonSession()` creates a server-side account, so it is called from exactly two
places — opening the Cloud sync screen, and `requestPairingCode()`. The profile picker used to
call it too, which meant every install that reached the picker minted an anonymous user whether or
not it ever went near cloud sync: measured at ~1,900 anonymous users against **62** devices that
actually paired, growing ~50/day, and every one of them counts toward the project's monthly active
users. It now asks `CloudSync.hasSession` instead, which touches no network and creates nothing.
**That is not a weaker check:** a device with no session cannot be paired, because pairing only
happens through `requestPairingCode()`, which creates the session and persists it to the keychain —
so "no session" is a definitive *not paired*, not an unanswered question, and `pairingKnown` stays
true. If a session is somehow lost the old pairing is unreachable anyway (a fresh anonymous user is
a different device to the server), so treating that as unpaired is also correct. Keep new boot-path
code on `hasSession`; reach for `ensureAnonSession()` only behind a deliberate user action. The optional **push** is the one device→cloud write path
and goes through the `push_sources`/`push_metadata` `SECURITY DEFINER` RPCs, which are
owner-scoped via `current_device_owner()`: an *unpaired* anonymous caller has no owner and is
rejected, and a payload can't touch another account's rows. **How that is enforced changed in
`20260727000000_tenant_isolation`, and the previous wording was wrong.** The old claim — "insert
forces `owner = o`; the upsert's `DO UPDATE` is guarded by `owner = o`" — described the `sources`
row only, and an owner-guarded `ON CONFLICT` **skips a foreign row silently rather than rejecting
it**. Control therefore reached `push_sources`' secret loop still carrying another account's source
id, and `source_secrets.source_id` was an FK to `sources(id)` — existence, not ownership — so a
crafted payload could plant a credential (including `playlistUrl`, i.e. *which server the victim's
player connects to*) on a source it did not own, which `get_secrets` then served to the victim.
Now: the composite `(id, owner)` FKs make that row unrepresentable, and a foreign id **raises**
`iptvs: source id belongs to another account` before any mutation instead of being dropped
silently. A paired device can already read all of its owner's credentials, so writing that **same**
owner's list adds no cross-account blast radius.

Pairing codes are short-lived + rate-limited — and since the same migration that is enforced on
**every** path: `pairings` previously had a direct `pairings_insert` policy with no `is_real_user()`
and no validation trigger, so any anonymous session could insert an unbounded, attacker-chosen code
with its own TTL, bypassing `request_pairing`'s 5/min limit and 10-minute expiry entirely. The
policy is dropped (`request_pairing` is `SECURITY DEFINER`, so it bypasses RLS and is unaffected;
the only direct client access is a self-scoped `DELETE`), and a `pairings_validate` trigger bounds
the code, caps the TTL at 15 minutes, forbids a pre-set `claimed_by`, and freezes
`code`/`device_uid`/`expires_at` on UPDATE so only `claim_pairing`'s `claimed_by` write is legal.
A matching `devices_validate` trigger makes `device_uid` **immutable** — it was previously
re-pointable at an arbitrary uuid, which let an account capture a device's identity and receive
that device's pushed credentials. Push uses last-write-wins **refined by a
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

`profiles` is the one exception, and it has its own trigger
(`profiles_touch_updated_at`): **a favorites-only update does not advance the revision**. Favorites
are device-owned, so a favorites change is never one of the panel edits the manual push's
"panel changed" warning is about — and once favorites sync automatically, every device's pushes
would have moved the revision continuously, firing that dialog on a profile nobody had edited and
teaching users to click through the only prompt standing between a device push and overwriting real
panel edits. The exemption is computed as `to_jsonb(NEW) - 'favorites' - 'updated_at'` against the
same on OLD, so a column added later joins the comparison automatically and the failure mode of
forgetting this function is "the revision advances" — the safe direction. `updated_at` is projected
out because the push RPCs set it explicitly. **`touch_profile_snapshot_revision` bumps the profile
with an `updated_at`-only write, which is exactly the exempt shape**, so it sets a
transaction-local `iptvs.force_profile_revision` flag the trigger honours; without that, source and
metadata edits would silently stop being detectable and the guard would go quiet.
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
`{mac, username, password, playlistUrl, epgUrl, epgUrls, userAgent}`; metadata secret keys:
`{tmdbApiKey, tvdbApiKey, tvdbPin, mdblistApiKey}`. Everything else (`portal`, `host`,
`playlistExpiryHint`, provider choice, `autoEnrich`, per-source `settings`) is broad. `portal`/
`host` stay broad on purpose — they name the provider (so the panel and sources screen show a
recognisable subtitle) but can't stream on their own. A **server-side strip trigger** enforces
broad-only on the rows, so even a device that skips the split can't leak a secret into the
broad table.

That list exists **twice**, in two languages: `secret_keys.dart` and the `array[…]` literals inside
the SQL strip trigger. A drift between them is a real credential leak — a secret key the SQL doesn't
know about lands in the broad, non-E2EE table — so `test/secret_keys_parity_test.dart` asserts
set-equality, reading the *latest* `sources_validate`/`metadata_validate` definition across
`supabase/migrations/` rather than a hardcoded filename, so a future migration redefining the
trigger is picked up automatically.

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

- `request_pairing(p_label)` — the device's suggested name for itself (see "The device's name,
  decided at pairing time"). `claim_pairing(p_code, p_label)` is the panel-side counterpart.

**Standing constraint for every RPC in this schema: overloads must be arity-distinct with NO
`DEFAULT` on any parameter.** PostgREST picks the candidate whose *parameter-name set* matches the
request body's keys, and fails with `PGRST203` if two match. So
`claim_pairing(p_code)` + `claim_pairing(p_code, p_label DEFAULT null)` would make a `{p_code}`
body ambiguous and break **every** pairing — a total outage, not a degraded field. `push_metadata`
((jsonb), (jsonb,uuid), (jsonb,uuid,jsonb)) is the working precedent. A `DEFAULT` is only correct
if the narrower form is dropped in the same migration, which is itself unsafe here: the narrow
forms are **kept forever as thin delegates** because `request_pairing()` is called by installed app
versions that can be arbitrarily old, and `claim_pairing(p_code)` by a panel SPA tab that can
outlive a deploy.

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

**What the KAT does and does not establish.** It validates the field/point arithmetic on one known
input; it proves nothing about *input validation*, and because both implementations run the same
hand-rolled algorithm, a shared logic bug outside its path would not be caught by the interop gate
at all. Peer public-key validation is the control that actually matters — a malicious server handing
over a crafted `epk` could otherwise recover a device's long-lived private scalar (invalid-curve
attack), and P-256's cofactor of 1 means an accepted on-curve point is necessarily in the
prime-order subgroup, so that check is the whole defence. It is pinned on **both** sides by the
shared `ecdhP256Invalid` fixture group (off-curve, point-at-infinity encoding, `x >= p`,
compressed-point prefix, wrong length). Scalar multiplication is **not** constant-time on either
side (textbook double-and-add over variable-time bignums, with a Fermat inversion): the device's
long-lived scalar is only ever multiplied locally against a server-supplied `epk` with no timing
observable returned, and anyone positioned to measure it can read the private key out of the
keychain instead — so this is an accepted limitation, recorded rather than hidden.

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

**The policy is delivered twice, and deliberately not identically.** The `<meta http-equiv>` copy
carries **no `frame-ancestors`**: that directive is **ignored by spec** when delivered that way, so
listing it enforced nothing, logged a console warning, and advertised clickjacking protection the
panel did not have. The `_headers` copy (emitted into every build by the `iptvs-security-policy`
plugin) *does* carry `frame-ancestors 'none'`, alongside `X-Frame-Options`, `nosniff`,
`Referrer-Policy` and HSTS. Where both are present a browser enforces the intersection — identical
directives, plus one the meta tag could never carry.

Which one is live depends on the host, which is why both exist: **GitHub Pages serves static files
and cannot set response headers**, so that deployment is the meta tag alone; **Cloudflare Pages
reads `_headers`**, so the apex deployment gets the real thing. `_headers` is inert on GitHub Pages
(served as a plain file, revealing nothing the meta tag doesn't already state), which is what lets
both targets share one build config. HSTS is deliberately without `includeSubDomains`/`preload` —
the apex is the panel, but the domain's other names are mail infrastructure, and a static site
should not pin HTTPS across a whole zone; set it zone-wide in Cloudflare if that is ever wanted.

Anti-framing is *also* enforced by **`panel/src/framebust.js`**, the mandatory *first* import of
`main.js`: ES module dependencies evaluate in source order, so it throws before the entry graph
evaluates and a framed panel builds no UI and attaches no listeners. It refuses to run rather than
busting out — no `top.location = …`, which would make the panel an open-redirect gadget — and
offers the user a plain link to the real origin instead. **Keep that import first even though the
header now exists**: it is the only protection on the GitHub Pages copy, which stays live for
already-shipped app installs (see "Hosting" below). This matters because the panel is exactly the
surface worth framing: passphrase entry, provider credential fields, and the device "Send key"
action.

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

**An *active* (writing) backend is a third category.** The earlier wording covered only an operator
who *reads*; one that also **writes** attacks E2EE by two other routes, and both clients used to
trust the server on them. Both are now closed by **sticky client-side state** — the server is not
believed when it contradicts what a client has already seen:

- **Downgrade to plaintext.** Both clients decide whether to encrypt from `get_crypto_state.enabled`,
  so a backend answering `{enabled: false}` — or simply 404-ing the crypto RPCs, which is
  indistinguishable from a pre-migration backend — would collect every client's provider credentials
  and metadata API keys as `format 0`. Each client now records that a profile *was* seen encrypted
  (panel: `localStorage` `iptvs_e2ee_seen`; device: an `E2eeMark` in secure storage) and, on a
  contradiction, resolves to **`locked` + `downgraded`** rather than encoding plaintext. Push is
  refused with `CloudPushBlockedException` / `kCloudE2eeDowngradedMessage`, deliberately worded
  differently from the plain locked message: "not set up yet" and "the encryption this profile had
  has disappeared" call for different user action. Clearing the mark takes an explicit local action
  (the panel's own `disableE2ee`, or an acknowledgement) — never a server assertion.
- **Content-key rollback.** `cloud_sync.dart` used to take `ck_version` from the very `device_ck` row
  it was about to unwrap (`?? ckVersion`) and never compare it with what `get_crypto_state`
  reported, so a backend serving a *consistent* pre-rotation bundle pinned a device to a **revoked**
  generation — the `ckv`-in-AAD binding prevents *mixing* generations but establishes no freshness.
  Now `isCkVersionRollback` treats the reported version as a **floor** and additionally compares
  against a monotonic high-water mark advanced only on a successful unwrap, so a rollback fails even
  if both RPCs lie. The `?? ckVersion` fallback is gone: a row with no version cannot be checked and
  is therefore rejected.

`buildSecretElement` also fails closed rather than open: `locked` used to be "treated as `off`
defensively", which meant *emitting plaintext*. It now throws. An empty secret still returns `null`
(send no element → server preserves), which is safe in any state because no plaintext is involved —
that is the "absent = preserve" contract, not a downgrade.

The read direction is closed too: `decodeSecretEntry` refuses a `format` 0 entry whenever the status
is not `off`. Without that, an active backend could still feed a locked/ready device attacker-chosen
*plaintext* — including `playlistUrl`, i.e. which server the player connects to. Returning empty
reproduces what real E2EE would do (those bytes wouldn't decrypt) and the local overlay keeps the
credential the device already holds.

**The residual, stated plainly:** a legitimate panel-side *disable* is byte-identical, from a
device's point of view, to the attack. So turning E2EE off costs one explicit acknowledgement per
device and per browser (or an unpair). That asymmetry is the design, not a bug — the client cannot
tell the two apart, so it asks rather than guessing. Note also that the sticky mark is
**unauthenticated in the tightening direction**: a hostile server can set it once, which degrades a
device to local-credentials-only with no push. That is safe (and such a server could deny service
anyway). The `ck_version` watermark, by contrast, **is** authenticated — it advances only after a
successful `decodeDeviceWrap`, and the server cannot mint a wrap at a version whose CK it does not
hold, so it cannot be inflated to wedge a device permanently.

Even so: **rotation remains a remedy for a compromised device, not for a compromised backend.**
Revocation cannot un-leak a CK a device already cached; the remedy for a suspected device compromise
is `rotate_content_key` (panel-side), which mints a new `ck_version`, re-wraps to the still-trusted
devices, and invalidates old-version envelopes.

### Validation limits and rate limiting

Writes are bounded at two layers (`..._harden_cloud.sql`): **BEFORE INSERT/UPDATE triggers** on
`sources`/`profiles`/`metadata_configs` — plus `source_secrets`/`metadata_secrets`
(`..._secrets_store.sql`) and `pairings`/`devices` (`..._tenant_isolation.sql`; those two were the
gap — the header's "every device→cloud write" claim did not hold for them) — call shared `assert_*`
helpers, binding the panel's *direct* table writes as well as the RPCs, and each push RPC
additionally checks the top-level
array count and byte size **before any mutation**. Rejections raise `check_violation` with a
stable `iptvs: ` message prefix and never interpolate payload values (a raw CHECK constraint was
deliberately rejected: its "Failing row contains (…)" detail would leak credentials through
client error surfaces). Limits are sized ≥10x above realistic maxima from the 250k-channel
validation corpus — e.g. 200,000 favorites, 50,000 hidden-category ids per kind, 8 KiB per field
value, 16 MB payload ceilings — so a legitimate user on a huge portal is never rejected. The
push RPCs are rate-limited DB-side (`check_push_rate`, 30 calls/min per device session —
deliberately per-device, not per-owner, since two devices on one account are independent
human-driven callers — one self-resetting row per subject in the policy-less `push_rate`
table, reaped on account deletion). `claim_pairing` is rate-limited too (10/min) — it was the only
push/claim-class RPC without a throttle, and a successful claim grants read access to that device's
owner's data. `pairings.suggested_label` is bounded at **256 and rejected outright if it contains
control characters** (`..._pairing_suggested_label.sql`). That ceiling **must stay ≤
`devices_validate`'s `max_label`** (also 256): a suggestion that passed at pairing INSERT but failed
`devices_validate` inside `claim_pairing` would let a device store a value that makes its owner's
claim fail outright — a denial of pairing. `claim_pairing` bounds the panel's label **before** it
looks the code up, deliberately, so the error cannot depend on whether the code exists; validating
after the lookup would turn an oversized label into an oracle for code validity. Reads/pulls are deliberately unthrottled
(PostgREST has no per-user limit and an Edge proxy isn't justified) — accepted risk, mitigated
by RLS scoping and the payload caps. Client-side, the panel's `friendlyError` and the app's
`friendlyCloudError` both show `iptvs: `-prefixed messages as-is, map permission/RLS errors to a
generic "not allowed", and reduce everything else to generic text. (`friendlyCloudError` used to
render any Postgres `message` verbatim-but-redacted, so a raw
`duplicate key value violates unique constraint …` reached the user; it now genericises like the
panel.) The load-bearing half holds on both — Postgres puts row values in `details`/`hint`, and
**neither client ever renders those**, which is what keeps CHECK-style "Failing row contains (…)"
credential leaks off the screen. The panel's `console.error` sites are held to the same standard:
they log code + scrubbed message, never the raw error object, because `details`/`hint` would carry
the offending row into a browser console that is one screen-share away from public.

**The one exception to "reduce everything else to generic text" is a 429**, because it is the only
failure the user can act on — and on the sign-in form it is the only one that occurs in normal
operation. Magic-link sends are throttled twice: a *per-address* cooldown ("you can only request
this after N seconds") and the *project-wide* email send quota ("email rate limit exceeded"), which
is shared across every address. `friendlyError` matches the message **and** `status`/`code`
(`over_email_send_rate_limit` / `over_request_rate_limit` — server-controlled enums, never payload
data), names the wait when GoTrue names one, and otherwise says to wait a few minutes. It reads
"Something went wrong." otherwise, which is what a real user saw when the project quota ran out:
they read it as a panel bug, re-submitted ~60 times in eleven minutes, and tried a second mailbox —
which cannot help, since the quota is not per address. The sign-in form also locks its submit
button for the duration of the request, so a double-tap can neither spend quota twice nor race
GoTrue's user insert into a `users_email_partial_key` duplicate-key 500 (observed once).

Note that the quota itself is a **dashboard** setting, not a code one: Supabase's built-in email
service is capped at a couple of sends per hour for the whole project and is explicitly not for
production. Raising it means configuring custom SMTP under **Auth → Emails → SMTP Settings** and
then raising **Auth → Rate Limits → email sent**.

> **Never add `alter table … force row level security`.** It looks like obvious hardening and it
> would break the system. The five RPC-only tables have **zero** policies by design, and every
> `SECURITY DEFINER` RPC runs as `postgres` — which is also the table owner. `FORCE` subjects the
> owner to RLS, so with no policies present every one of those RPCs would silently read and write
> nothing. The residual risk it would address is nil anyway: no client-reachable role owns these
> tables (PostgREST connects as `authenticator` and `SET ROLE`s to `anon`/`authenticated`, and
> `service_role` bypasses RLS via `BYPASSRLS` regardless). The correct defence-in-depth is the
> table-level `REVOKE` in `..._tenant_isolation.sql`, which also strips **TRUNCATE** — RLS does not
> filter TRUNCATE at all, so holding it on an RLS-protected table is a latent full-wipe primitive.

## Pairing flow (code-based, works on every platform)

The device shows a code ([`cloud_sync_screen.dart`](../lib/screens/cloud_sync_screen.dart)); the
user enters it in the panel's Devices page; the device polls `pairing_status` until claimed, then
pulls. Once paired, the screen shows a **profile picker** (list the account's profiles, switch →
`set_device_profile` + re-pull) and offers **Pull now** / **Push to panel** (push confirms first,
since it overwrites that profile).

### The QR shortcut

The primary device here is a television, and reading eight characters off it across a room and
typing them into a phone is the slowest step in the whole flow — and the one step that can be
handed to a camera. The pairing screen therefore also renders the code as a QR encoding
`<panelUrl>/?code=ABCD2345` (`pairingPanelLink`, `lib/data/cloud_config.dart`, pure and
unit-tested); the panel reads it back with `pairingCodeFromUrl` (`panel/src/validate.js`),
prefills its Pair field, and puts the caret on the optional name instead.

Both halves fail closed, because the fallback is the form the user was going to fill in anyway:

- **Device.** The QR sits *beside* the printed code and link, never instead of them — it is no use
  to someone pairing from the same machine, and a phone camera pointed at a lit panel is exactly
  where a scan fails. A `PANEL_URL` that won't parse yields the plain link and a blank code yields
  the plain panel URL (`pairingPanelLink`). It is drawn on an explicit white plate with dark
  modules: `QrImageView`'s background defaults to transparent, which on this screen would be dark
  on dark — visibly present, scannable as nothing.

  Rendering lives in `lib/widgets/pairing_qr.dart` (`PairingQrView`) rather than on the screen, so
  its layout can be swept across window sizes and text scales without standing up a `SourceStore`,
  an `AppDatabase` and a fake `CloudSync` — `layout_overflow_test.dart` is scoped to the three
  fixed-extent browsing surfaces and does not cover this screen. Two things it pins, neither
  visible at a single window size:

  - **The symbol is sized against the window, not left at a fixed 180 px.** `QrImageView` falls
    back to `constraints.biggest.shortestSide` with no `size` (infinite inside a Column), and a
    fixed `size` wider than the incoming constraints is clamped on **width only** — drawing a
    rectangle no scanner will read. `PairingQrView` clamps between `minSide` and `maxSide` against
    `MediaQuery.sizeOf` minus the card's own chrome.
  - **`QrValidator.validate` is not a sufficient guard, and the obvious reading of it is wrong.**
    `QrCode.fromData` picks a version through `_calculateTypeNumberFromData`, which walks 1..39 and
    simply returns the largest when nothing fits instead of failing — so validation reports *valid*
    for a payload that throws `InputTooLongException` the moment it is really encoded, deep inside
    the painter where no `errorStateBuilder` can catch it. An over-long `PANEL_URL` took the whole
    pairing screen down. `maxLinkLength` (300) bounds the input well below any version's capacity,
    which puts that path out of reach; the bound is argued from legibility anyway, since a symbol
    denser than roughly 60 modules can't be read off a television at `maxSide`.
- **Panel.** `code` is attacker-supplied by construction, so it is accepted only in the exact shape
  `gen_pairing_code()` emits (8 chars of `ABCDEFGHJKMNPQRSTUVWXYZ23456789` — no I/L/O/0/1, so a
  misread can't become a *different* valid code) and refused otherwise, on the way in *and* on the
  way back out of storage.

**Two details of the panel side are load-bearing and neither is obvious:**

- **The code is stashed in `localStorage` (`stashPairingCode`), because it has to survive the
  sign-in.** The person scanning a television's QR on their phone is precisely the person least
  likely to be signed in already, and `signInWithOtp`'s `emailRedirectTo` is
  `origin + BASE_URL` — no query string — with the link commonly opening in a *different tab*. So
  neither the URL nor `sessionStorage` carries it across. (Widening `emailRedirectTo` to include
  the query was rejected: the project's redirect allow-list is exact, and a mismatch would break
  sign-in outright rather than degrade the shortcut.) The stash carries a timestamp and expires at
  `PAIRING_CODE_TTL_MS`, matching `request_pairing`'s own 10-minute expiry — a prefill the server
  would reject is worse than no prefill.
- **Rendering stays idempotent: the code is read on render and cleared only on a successful
  `claim_pairing`.** `onAuthStateChange` (INITIAL_SESSION) and `getSession().then` both call
  `render()` on load, so a signed-in user runs `renderDevices()` twice concurrently. A
  consume-on-render let the second pass overwrite the first's prefilled form with an empty one —
  and take the focus and `history.replaceState` cleanup with it. The URL is stripped once the code
  reaches the form; `urlWithoutPairingCode` returns null when there is no `code` parameter, which
  is what keeps the second render from churning history.

The QR is a convenience over the existing flow, not a new authorisation path: it carries the same
short-lived, rate-limited code to the same `claim_pairing` RPC.

### The device's name, decided at pairing time

A freshly paired device used to be nameless (`devices.label = ''`, rendered "Device") until the
owner used Rename. Both ends now contribute a name, and the server merges them
(`20260804000000_pairing_suggested_label.sql`):

- The **device** sends a platform-derived suggestion — "Android TV", "Android", "Windows PC",
  "Linux", "Mac", "iPhone" — via `request_pairing(p_label)`, stored on the pairing row as
  `pairings.suggested_label`. It is **zero-typing on purpose**: the primary device is a TV with a
  D-pad remote, so the pairing screen shows the suggestion as read-only text and adds **no text
  field, no focus target, and no Back-ladder rung**. Android TV vs handset comes from
  `UiModeManager` over the outbound-only `iptvs/device` channel — outbound only, so it is *not* a
  `ChannelHandlerOwner` case.
- The **panel** offers an optional Name box beside the code, passed as `claim_pairing(p_code,
  p_label)`.

**Precedence — panel-supplied > existing `devices.label` (same owner only) > device suggestion >
`''`.** This is the scalar analogue of `merge_preserving_nonempty`: an absent value never blanks a
stored one, and only an explicit panel action changes a stored non-empty name. A re-pair with the
panel field left blank must not clobber a hand-chosen "Living room TV" with "Android TV".

The "same owner only" qualifier is deliberate: a device re-paired to a **different** account starts
from its own suggestion and never carries the previous owner's chosen name into the new owner's
device list. That closes a small pre-existing cross-account information flow.

`suggested_label` is **attacker-controlled text from an anonymous session that lands in another
account's device list**, so it is bounded (256, matching `devices_validate` — see the coupling note
under "Validation limits"), rejected outright if it contains control characters, frozen on UPDATE
alongside the rest of the pairing row, and rendered through the panel's `esc()` into a text node.
It carries **zero authority** — nothing branches on it. Accepted residuals: the suggestion is
unauthenticated by nature (any anon-key holder can claim to be "Living room TV"), and bidi /
zero-width Unicode is not caught by the control-character check.

## Flutter side

[`cloud_config.dart`](../lib/data/cloud_config.dart) (build-time `--dart-define`
## Favorites sync is a delta, and it runs on its own

Favorites are the one collection that syncs **automatically** (`cloud_auto_sync.dart`,
`CloudAutoSync`, started from `HomeShell`). Everything else still syncs only when the user presses
Pull/Push on the cloud screen.

That is possible only because favorites push *changes* rather than state. `push_favorites` replaces
the whole `profiles.favorites` array, which is safe while pushing is deliberate but not on a timer:
two devices pushing whole sets race, and the later push erases what the earlier one added. Unlike
`sources`, favorites have no `merge_preserving_nonempty` equivalent to fall back on — **a missing
element is indistinguishable from a deletion** when all you have is the final set.

The delta removes that ambiguity at the source: the payload says `add` or `remove` outright, so the
server never infers intent from an absence. `push_favorites_delta` merges the two halves per row
under the profile's row lock, so concurrent pushes serialise and two devices can only conflict on
the *same* favorite — where "whichever push the server saw last" is the answer a revision check
would have given anyway. That is why `CloudAutoSync` has **no `profiles.updated_at` guard**: the row
lock makes one unnecessary rather than merely cheaper.

**There are deliberately no tombstones, and adding them would be a mistake.** An earlier draft
carried soft-deleted entries (`deleted_at`) so other devices could learn about a deletion. They earn
their keep in a "fetch changes since T" model, where a device that missed the delete would never
hear about it otherwise — but this sync is not that. `pullFavorites` **mirrors** the profile
(clearing the cloud-managed sources and re-applying the stored set), so a favorite the server no
longer holds is already removed from every device that pulls. Deleting the element outright says the
same thing with less machinery, and drops the tombstone pruning, the timestamp keys and their
validation with it.

It also keeps `profiles.favorites` in **exactly the shape every already-shipped client expects**.
Shipped `pullFavorites` reads only `source_id`/`kind`/`item_id` and has no notion of `deleted_at`,
so a tombstone looked like an ordinary favorite to it: an older build would have pulled a deleted
favorite straight back and then pushed the resurrection to every other device. That mixed-version
hazard is real whenever a store release is waiting on review while a direct build ships — and it is
the reason the element shape must stay closed to new keys unless every shipped reader is known to
tolerate them.

Computing a delta needs local change tracking, because a favorite in the cloud but not locally is
either "deleted here" or "added there and not pulled yet". That is `favorites_outbox` (schema v14):
an outbox of pending toggles, not a snapshot of the last push, so it is bounded by what the user
touched rather than by library size. It is written by `AppDatabase.setFavorite` — the single choke
point for *user* intent — and never by the pull, which mirrors through
`clearFavorites`/`setFavorites`; queueing the cloud's own state would push it straight back and
resurrect whatever the pull just deleted. The pull **rebases the outbox onto the pulled state**,
because mirroring the profile would otherwise visibly undo a favorite the user just toggled.

`push_favorites` (whole-set) stays supported forever — installs are arbitrarily old, and a mixed
fleet is normal while a store release waits on review. A legacy whole-set push still overwrites the
set, which is today's last-write-wins behaviour and no worse than today. Nothing in the delta path
changes what an old client reads or writes, which is what makes deploying the migration safe ahead
of a store build.

**The service is bound to a profile id, and must be re-bound when that changes.** It is started
from `_loadActive`, not `initState`, precisely because `_loadActive` is what every profile switch
and cloud-screen return already calls. Binding it once at startup left it pushing this device's
favorite changes into the *previous* profile after a switch, and meant pairing for the first time
did nothing until the next launch. Re-binding flushes the outgoing service first — the outbox is
not profile-scoped, so anything still queued would otherwise be evaluated against the new profile's
managed sources. It no-ops when the profile is unchanged (the common case: `_loadActive` also fires
on every *source* change) and holds a re-entrancy guard, since two overlapping loads would
otherwise build two services on the same stream and push every change twice.

Pushes are debounced (5 s) and coalesced, so favoriting five channels is one round trip; a change
made during an in-flight push is queued rather than dropped, a failed push retries and never
throws at its caller, and `flush()` runs on app pause because a backgrounded Android process may
never get another turn. Auto-sync shares the server's 30-per-minute `push` budget rather than
getting one of its own.

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
[`device_label.dart`](../lib/data/device_label.dart) derives the pairing-time name suggestion:
`suggestedDeviceLabelFor` is the pure platform→name mapping, `detectSuggestedDeviceLabel` is the
impure detector (`Platform.operatingSystem` plus the outbound-only `iptvs/device` channel on
Android). It **never throws** — any failure degrades to an empty suggestion, which reproduces the
pre-feature behaviour exactly. `requestPairingCode({label})` sends it, falling back to the 0-arg
`request_pairing()` on `isMissingFunctionError` only, so a real rate-limit or auth rejection still
surfaces.
The pure mappers/helpers (`cloudRowToConfig`, the id helpers, `splitFields`/`mergeFields`/
`fillGapsFromLocal`, `buildSecretElement`/`decodeSecretEntry`, `isMissingFunctionError`,
`MetadataConfig.fromCloudParts`, `sourceCredentialsMissing`, `suggestedDeviceLabelFor`) are
unit-tested in `test/cloud_sync_test.dart`; the crypto vectors + fail-closed cases in `test/cloud_crypto_test.dart`.

## Web panel

[`panel/`](../panel/) — a tiny Vite + `@supabase/supabase-js` SPA (no framework). **Magic-link
sign-in only** (no OAuth). Field shapes mirror `SourceConfig` per kind. Sources carry an integer
`position` and the list has **↑/↓ reorder** controls (positions self-heal to a clean `0..n-1` on
reorder; new sources append); devices show sources in that order. Branded with the app icon
(`panel/public/icon.png`, copied from `assets/icon/`). Note: the Flutter web target lives in
`web/`; the panel deliberately lives in `panel/`.

#### Hosting: three origins, and why

| Origin | Serves | Source | Deployed by |
| --- | --- | --- | --- |
| `iptvs.click` | landing page, store badges, knowledge base | `kb/` (Astro Starlight) | `pages.yml` → Cloudflare Pages `iptvs-site` |
| `panel.iptvs.click` | the source panel | `panel/` | `pages.yml` → Cloudflare Pages `iptvs-panel` |
| `gchofficial.github.io/iptvs/` | a redirect, nothing else | `redirect/` | `github-pages-redirect.yml` → GitHub Pages |

**The panel is a separate origin from the site as a security boundary, not for tidiness.** It holds
an authenticated Supabase session, an unwrapped CK and provider credentials, and its runtime
dependency tree is one package; Starlight's is hundreds, and its Markdown is the part most likely to
take community PRs. Same origin would put every one of those inside the panel's `localStorage` and
session — which is precisely the "XSS'd panel" case the [threat boundary](#threat-boundary) says the
crypto does *not* cover. The two CSPs measure the same conclusion: a built Starlight docs page
carries ~16 inline `<script>` blocks and ~80 inline `style=` attributes (Shiki), so it needs
per-build script hashes plus an `'unsafe-inline'` exemption scoped to `style-src-attr` (a style
*attribute* has no hash form). The panel is a flat `script-src 'self'` with nothing inline. One
origin means one policy, and it would have been the looser one.

**The github.io URL can never simply stop answering.** `CloudConfig.panelUrl`
(`lib/data/cloud_config.dart`) is a compile-time constant, so every install carries the URL it was
built with, and that is what the pairing screen prints and what `pairingPanelLink` encodes into the
QR. Installs are arbitrarily old. `redirect/` therefore serves that path forever, forwarding to
`panel.iptvs.click` **with the query string intact** — the QR carries `?code=ABCD2345` and the panel
reads it to prefill the Pair form, so a bare `<meta refresh>` (which drops the query) would turn a
working shortcut into a blank form. It deploys from its own workflow because it is the only thing
left needing `pages: write`, and it changes roughly never.

**Every origin the panel is served from must be in Supabase's Auth → URL Configuration
redirect allow-list**, which is exact. Two consequences: a missing entry breaks sign-in outright,
and — the reason never to widen it to a wildcard — that allow-list is what stops a **forked copy**
of this panel, standing at an attacker's own domain, from completing a magic-link flow against this
project. The Supabase URL and anon key are public by design; the allow-list is the control.

Supabase values come from repo **Variables** (`SUPABASE_URL`, `SUPABASE_ANON_KEY`), the site's
canonical origin from `SITE_URL`; the deploys need `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` **Secrets** and skip themselves when those are absent, so a fork publishes
nothing and fails nothing. Scope the token to Pages:Edit on this account — never a global key — and
keep secrets out of any `pull_request_target` workflow. `wrangler` is a lockfile-pinned
devDependency rather than an `npx wrangler@4` resolving a fresh minor at run time: everything else
in this repo's CI is pinned, and a deploy credential is the wrong place to make an exception.

`PANEL_BASE=/` now that the panel owns an origin; `/iptvs/` was a GitHub Pages *project page*
artefact. The base path is baked into the bundle and `import.meta.env.BASE_URL` is what
`emailRedirectTo` is composed from, so it has to match the origin it is served at.

### Xtream detection on an M3U source (suggest, never convert)

The add/edit form detects an Xtream `get.php` shape in an M3U playlist URL
(`xtreamCredentialsFromPlaylistUrl` in `panel/src/validate.js`, pinned by
`panel/test/xtream_detect.test.js`) and offers **"Switch to Xtream"** with host/username/password
prefilled from the link already pasted.

**It offers; it never rewrites** — a browser cannot verify a provider panel, so this is a guess
about a URL shape and converting on it blind could break a working source. The app is the half
that verifies. Full rationale, including why `no-cors` doesn't help and why a server-side probe
was deferred, is in **[sources.md](sources.md)** ("Why the web panel suggests and the app proves").

## Profile PINs

A profile can require **four digits** before a device switches into it. The whole feature is one
optional column, one RPC, and one dialog — but it is worth being precise about what it is, because
the temptation to treat it as a security control leads to worse decisions in every direction.

**It is a gate on a shared television, not a secret.** Four digits is ten thousand values, so
anyone holding the verifier recovers the PIN by trying all of them — whatever KDF cost we pick.
Three consequences follow, and each of them is the reason something is built the way it is:

* `profiles.pin` is a **broad** column, not a secret one. It is not routed through the secret
  store and not encrypted under the profile's content key. Encrypting it would buy nothing (see
  above) while making the gate unenforceable on an **E2EE-locked** device — which is precisely the
  device that still has to enforce it. Fail-closed there would mean "no profile opens at all",
  i.e. a lockout rather than a gate.
* The credentials a PIN sits in front of are protected **independently** — by the keychain, by
  RLS, by the secret store, by E2EE. None of that changes with or without a PIN, so nothing about
  the security model rests on this column.
* Iterations (`kProfilePinIterations` = 10 000, PBKDF2-HMAC-SHA-256) are sized for the slowest
  device that must *verify* one — a remote-only set-top box, on the UI path — not for an attacker.
  One derivation measured ~25 ms in the desktop VM; it runs **synchronously on the UI thread** and
  has not been measured on a set-top box, so a hundred thousand rounds would multiply an already
  unmeasured stall by ten and buy nothing.

What actually makes guessing tedious is the **cooldown**: five consecutive misses stop input for
30 seconds (`kPinAttemptsBeforeLockout` / `kPinLockout`), which puts an exhaustive search at
roughly seventeen hours of uninterrupted button-pressing. That is the defence that matches the
threat — the person standing in front of the television.

The count is deliberately **not** dialog state (`_attempts` in `pin_entry.dart`, keyed per
profile, process-lifetime). It was, first, and that made the cooldown decoration: four wrong tries
and a Back press bought four more, indefinitely. Killing the app still clears it, which is the
honest limit of a device-side gate.

### The format is a three-implementation contract

`pbkdf2-sha256$<iterations>$<base64 salt>$<base64 hash>` (16-byte salt, 32-byte hash, ~90 chars).

* `lib/data/profile_pin.dart` derives **and checks** it. It is the only implementation that ever
  sees a PIN.
* `panel/src/pin.js` derives it through WebCrypto. The panel can *set* or *clear* a PIN and can
  never be asked to prove one — a browser is not where that check belongs.
* Postgres checks the **shape only** (`profiles_validate`), so a malformed write is rejected
  rather than becoming a profile nobody can open. Its iteration bound (and the panel's) is
  deliberately *narrower* than the app's parser accepts — a verifier the server stores but the
  device cannot read is exactly the unopenable profile the check exists to prevent.

Both client tests assert the same two vectors (`test/profile_pin_test.dart`,
`panel/test/pin.test.js`), cross-checked against an independent PBKDF2 implementation. That is
what guarantees a PIN set in the panel opens the profile on a television that has never talked to
that panel — there is no feedback path that would reveal a mismatch later.

**An unreadable verifier fails closed.** A build that cannot parse the stored string (a future
algorithm, a longer PIN) leaves the profile shut and says why. Reading it as "no PIN" would turn
every forward-compatible change into a silent removal of the gate on every older install.

**The gate is enforced by the client, so an app build older than this feature ignores it.** That is
inherent — the server cannot check a PIN it never sees — and it is another reason not to describe
this as protection. It is also why nothing else was made to depend on it: no push, pull, or secret
path consults `pin`, so an old build that ignores the column behaves exactly as it always did.

### Write paths

* Panel: a direct `update` under the existing owner-scoped `profiles_update` policy.
* Device: `set_profile_pin(p_profile_id, p_pin)` — devices hold zero direct table writes, so this
  follows the same SECURITY DEFINER shape as the push RPCs (owner resolution, profile ownership,
  then `check_push_rate`). Validation is the shared trigger's, so the two paths cannot diverge.

A PIN change **advances `profiles.updated_at`** like any other profile edit. It is deliberately
not given the favorites-style exemption: favorites are exempt because they are device-owned and
push constantly, while a PIN changes about once in a profile's life. One extra "changed on the
panel" prompt is a fair price for not putting a second hole in a guard that exists to stop a
device push overwriting real panel edits. Pinned by `supabase/tests/16_profile_pin.test.sql`.

### Device side

`_ProfileEntry.locked` drives a lock badge on the avatar (in **every** mode — "this will ask for a
PIN" is something you want to know *before* choosing a profile), and `ProfilePickScreen` asks
before switching. Three rules that are easy to get wrong:

* **The active profile is not re-asked** when the picker is opened from the avatar menu: you are
  already inside that profile, and its data is on the screen behind the dialog. The one exception
  is a locked *boot* (`_lockedBoot`), where the app has not been handed over yet — there, even
  re-selecting the active profile asks, and **Skip is withdrawn**, since Skip is the other way
  past this screen.
* **A locked active profile overrides the startup mode** (`shouldShowPickerAtStartup(...,
  activeProfileLocked: true)`). Without that, `off` — or `auto` with a single profile — would boot
  straight into the locked profile, and the gate would exist only for accounts that happen to have
  several profiles *and* have left the picker on.
* **A cloud profile's verifier is mirrored device-side** (`LocalProfileStore.cloudPins`, refreshed
  on every successful listing) **with its name beside it**. The boot check runs before any cloud
  call can answer, and an offline device must not hand over a locked profile just because it could
  not ask. The name is cached because an offline boot into a locked cloud profile has to *draw*
  that profile for its PIN to be typed — with only the verifier there would be a "Who's watching?"
  with nothing to watch with. Staleness fails closed (a PIN cleared on the panel stays enforced
  until the next successful listing) and self-heals.

  Two boundaries keep that cache from outliving its account. The fallback is used only when the
  server **never answered** — a device the panel unpaired answers *not paired* definitively, and
  reading the cache there would conjure a locked profile it can no longer sync and hold the boot on
  it. And `CloudSync.unpair` clears the cache (`clearCloudPins`) for the same reason it clears the
  sticky E2EE marks: re-pairing to a *different* account that happens to reuse a profile id would
  otherwise inherit a lock nobody set.

Manage mode opens a per-profile menu (Set/Change PIN, Remove PIN, Delete). Changing or clearing a
PIN asks for the current one; **deleting does not**. That asymmetry is deliberate: deleting
reveals nothing — it only destroys — and it is the one way out of a forgotten PIN on a
device-local profile, which has no panel to clear it from. Behind the PIN, a delete would leave a
profile that can be neither opened nor removed.

The dialog (`lib/widgets/pin_entry.dart`) draws an **in-app keypad everywhere except desktop**
(`pinKeypadForPlatform`): on a television a `TextField` opens the platform IME, which on Android TV
is a full alphabetic keyboard that traps D-pad focus — the reason `TvTextField` exists at all — and
four digits deserve better than that. Desktop always has a keyboard attached, so the pad would be a
mouse-only detour. Hardware digits work on **both** surfaces regardless: a remote's number keys
bubble from whichever pad button holds focus up to the dialog's own handler.

**The pad fits the window; it never scrolls.** This is a modal the user cannot leave without typing
four digits, and on a remote a key below the fold is simply unreachable — a D-pad does not scroll a
dialog. So the lattice is laid out at its comfortable size inside `Flexible` + `FittedBox`
(`scaleDown`, so a roomy layout is unchanged) and shrinks into whatever height the lines above
leave; the explanatory line — the one piece of chrome that is nice rather than necessary — is
dropped below a 420 px viewport so the pad keeps that space, and the digit labels opt out of the
platform text scale because the pad's size is already a layout fact. A landscape handset at a 2.0
text scale is the case that forces all three.

Pinned by `test/pin_entry_test.dart` (both surfaces, the full arrows-and-OK walk of the pad
including the corner where Down from 7 has to find 0, the cooldown), the PIN group in
`test/profile_pick_screen_test.dart` (the gate, the locked boot, manage mode operable with OK
alone), and a sweep in `test/layout_overflow_test.dart` — 7 window sizes from 320x568 to 1920x1080
x text scales 1.0/1.3/2.0, asserting every key is **inside the window** and the pad still types.

## Profiles (device-side)

The app boots into `ProfilePickScreen` (`main.dart` `home:`, `bootMode: true`) — a "Who's
watching?" grid that combines **cloud profiles** (only when built with Supabase config *and*
paired) and **local profiles**, which need no cloud at all. At boot the screen decides for itself
whether to appear: `shouldShowPickerAtStartup(mode, profileCount, activeProfileLocked:,
hasActiveProfile:)` with the persisted `ProfilePickerStartup` mode (`auto` = only when >1 profile,
`always`, `off`; cycled from a `FocusableCard` row atop `sources_screen.dart`) — otherwise it
silently short-circuits to `HomeShell`, so a single-profile install boots exactly as before. A
**PIN-locked active profile overrides every mode** and holds the screen; see
[Profile PINs](#profile-pins). An **ownerless device — profiles exist but none is active —
overrides every mode too**; see [Deleting a profile](#deleting-a-profile) for why that state is
otherwise unrecoverable. Profiles are also reachable
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
source leaks. New local profiles are seeded with only the Demo source. Manage mode opens a
per-profile menu — set/change/remove its PIN, and (local profiles only) delete it; cloud profiles
are otherwise managed in the web panel.

### Deleting a profile

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
*non-active* profile leaves the active profile and its live state untouched.

That empty baseline is correct but it is not a resting place, and leaving the device parked there
was a shipped dead end: **the picker is the only thing that restores a snapshot**, and with one
profile left `shouldShowPickerAtStartup(auto, 1)` answers *false* — so the survivor booted into an
empty library on every launch, force-close included, until the user found "Change profile" by hand.
(`off` reaches the same dead end at any profile count.) Two changes close it, and both are needed:

* **The boot check knows about ownerless.** `hasActiveProfile: !ownerless` in `_check`; profiles
  present with nothing owning the device forces the picker open whatever the mode says.

  Ownerless-ness is a **persisted device-local mark** (`LocalProfileStore.ownerless`), written at
  delete-of-active, and *not* inferred from "is some entry drawn as active". Both directions of
  that inference are wrong. A device that is merely **offline** cannot draw its active cloud
  profile — its store still holds that profile's sources, and inferring from the entry list would
  put "Who's watching?" in front of that user on every launch with no network. In the other
  direction, deleting the active *local* profile leaves the cloud `active_profile_id` pointing at
  a profile whose sources are **not** loaded (switching to a local profile never clears it, and
  there is no RPC that can), so that stale pointer would claim the empty baseline — the boot
  short-circuits into it *and* `_selectProfile`'s identity shortcut answers a tap on it with
  `_goHome()`, both landing in the empty library. While the mark is set, `_check` marks **no**
  entry active, which disarms both paths at once.

  The mark is joined by one inference, for installs that already hit this bug on an older build
  and will never have a mark written retroactively: profiles exist, no local active id, **and no
  cloud pairing** to explain it. That last clause is what keeps the offline-cloud device out.
  Clearing is symmetric — selecting a profile, creating one, and the adoption below all clear it,
  and a local active id present alongside a mark proves the mark stale (only a real selection
  writes one), so it self-heals.
* **Delete-of-active adopts the sole survivor** (`_adoptSoleSurvivor`): exactly one profile left,
  local, and unlocked → restore its snapshot and mark it active, right there. Ownership is
  unambiguous with one candidate, and the user who deletes and then walks straight into the app
  (Skip, or the avatar menu) shouldn't have to wait for a relaunch to get their library back.
  Adopting is safe *because* nothing is active at that moment: `_snapshotCurrent` is a no-op, so
  the survivor's stored snapshot cannot be overwritten before it is read back — the invariant
  above still holds. A **locked** survivor is deliberately *not* adopted (its sources would sit one
  Skip away with no PIN asked) and neither is a cloud one (entering it is a pull, not a restore);
  both are reached through the picker the ownerless check now opens.

JSON round-trips, the startup decision, and the stable cloud-avatar colour hash are unit-tested in
`test/profile_store_test.dart` (including the ownerless override); the deletion contract
(non-active delete, delete-active with others present / as the last profile, sole-survivor
adoption, a locked survivor left unadopted, the ownerless boot, and the `friendlyCloudError`
surface) and the PIN gate are pinned by `test/profile_pick_screen_test.dart`.
