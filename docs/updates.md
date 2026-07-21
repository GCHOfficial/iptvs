# In-app updates — full detail

The app self-updates from its own **GitHub Releases** (`GCHOfficial/iptvs`; the `release.yml`
pipeline attaches `iptvs-<ver>-android.apk`, `iptvs-<ver>-windows-x64.zip`,
`iptvs-<ver>-linux-x86_64.AppImage`, and a detached
Ed25519-signed manifest to a `v<ver>` tag).
The compact rules live in CLAUDE.md; read this before changing the update flow, the release
pipeline, or the update dialog.

## Release changelog

The release body opens with a short **AI-generated changelog** (release.yml's "Generate AI
changelog" step: commit subjects since the previous tag → Gemini, key in the `GEMINI_API_KEY`
repo secret → `--notes-file`), with GitHub's auto-generated notes appended below. It tries
`gemini-3.5-flash` → `gemini-3.1-flash-lite` → `gemini-3-flash-preview` (two attempts each — the
primary 503s under load, which cut v0.1.29 without a changelog). The step is fail-open — no key /
no previous tag / API error just yields the auto notes — and the body is what the in-app update
dialog renders.

## Release publishing

The publish step drives the `gh` CLI directly with per-command retries (5 attempts, linear
backoff) — a GitHub API 503 mid-publish previously failed the whole job. Release existence is
probed with a raw `gh api` status check because `gh release view` reports "release not found"
for *any* REST failure, so an outage would misroute an existing release into `gh release
create` and a persistent "already exists" error; only a real HTTP 404 selects the create path,
anything non-404 goes back through retry. Re-runs converge: an existing release is edited
(title/notes/prerelease) and assets re-uploaded with `--clobber`, and an empty AI-changelog
body never overwrites an existing release's notes on the edit path. `--verify-tag` keeps a
manual dispatch from minting a release for a tag that was never pushed.

GitHub-direct builds expose a Stable/Beta selector. Stable uses GitHub's latest
normal release; Beta selects the highest signed, non-draft release including
prereleases. Development, Google Play, and Microsoft Store builds do not run or
show the GitHub updater. Store test tracks/flights are reserved for submission
validation; ongoing beta users install the separate GitHub-direct distribution.

## Adding a release platform (forward-compatibility)

The manifest lists one artifact per platform, and a client parses the whole list. A build only
knows the platforms in `kKnownReleasePlatforms`; since the skip-unknown parser landed it *ignores*
the rest, but **builds that predate that parser threw and rejected the entire manifest** on the
first unknown platform. That is exactly how 0.1.38 broke auto-update everywhere: it was the first
release to add a `linux-x86_64` artifact, and every ≤0.1.37 client (strict `{android, windows-x64}`
parser) crashed parsing it — on Windows and Android too, not just Linux.

Rules when introducing a new platform artifact into the manifest:

- **Never add a new platform key to the manifest while a meaningful population still runs a build
  whose parser predates the skip-unknown behaviour.** Those clients cannot be fixed remotely — the
  broken parser is baked in and auto-update is the thing that's down.
- **Rescue path for an already-broken cohort:** cut a new release whose manifest lists *only* the
  platform keys the stuck parser accepts (for the 0.1.38 incident: `android` + `windows-x64` only).
  `/latest` then serves a manifest they can parse, landing them on a build with the tolerant parser.
  Cost: the newly-added platform gets no auto-update for that release and must update manually once
  (its installs are new and already have the tolerant parser, which treats a missing entry as "no
  asset", not a crash). Restore the full manifest once the old cohort has drained.

## Layering

Layered like everything else — a shared Dart service does the network check + version compare;
the final install step is the only platform-specific part.

- **`lib/data/update_manifest.dart`** — strict signed-manifest schema and Ed25519 verification.
  The exact signed bytes bind version, minimum version, platform, exact filename, byte size,
  and SHA-256. Duplicate platforms, malformed hashes, and values beyond the platform ceilings
  fail closed. **Unknown platforms are skipped, not rejected** (`kKnownReleasePlatforms`): the
  parse loop ignores any artifact whose platform this build doesn't recognize, so a manifest
  that adds a future platform still parses on older clients (they just find no asset for it).
  This is deliberate — the original fail-closed behaviour bricked auto-update on *every*
  platform for all ≤0.1.37 clients the moment 0.1.38 first shipped a `linux-x86_64` artifact
  (their parser threw `Unsupported release platform` and rejected the whole manifest). **Adding
  a new release platform to the manifest is therefore only safe once the population of clients
  predating this skip-unknown parser has drained** — see below.
- **`lib/data/update_service.dart`** — `ReleaseInfo` and `UpdateService.fetchLatest()` (GETs
  `releases/latest`, locates only the exact manifest/signature assets, verifies the signature,
  and derives artifact URLs on the approved GitHub host; **GitHub 403s without a
  `User-Agent`**; 404 = "no releases yet" = up to date, not an error), `appVersion()` (via
  `package_info_plus` — returns the CI build-name, which is the tag minus `v`, so a release build
  reports `1.2.3` and compares equal to tag `v1.2.3`; local `flutter run` builds report the
  pubspec `1.0.0`), and the pure `compareVersions` / `isNewer` / `shouldAutoCheck` (unit-tested
  in `test/update_service_test.dart`).
- **`lib/data/update_store.dart`** — `skippedVersion` + `lastCheck` prefs in the keychain
  (mirrors `LocalProfileStore`; the app has no SharedPreferences), plus the authenticated
  metadata/path for a fully downloaded Android APK awaiting user installation. The pending
  record is cleared after the installed version catches up or when cache revalidation fails.
- **`lib/data/update_installer.dart`** — `download()` permits only HTTPS GitHub release hosts and
  approved redirect hosts, streams to a `.partial` temp file with a signed-size ceiling, verifies
  exact received length and SHA-256, and only then renames it to the install filename. Failure
  deletes the partial file. It then hands the verified file to the platform: **Android** fires the
  system package-installer over the **`iptvs/updates`** MethodChannel (`installApk`) only after
  native code confirms the APK is inside this app's cache, has the same package name, and has the
  same signing-certificate set as the installed app. Installation needs the
  `REQUEST_INSTALL_PACKAGES` permission + a **FileProvider** (`${applicationId}.fileprovider`,
  `@xml/file_paths` → `<cache-path>`, since `getTemporaryDirectory()` = the Android cache dir) —
  falls back to `requestInstallPermission` (unknown-sources settings) or the browser. The
  permission call completes only when Android returns from settings, allowing the same APK to be
  retried without a second download. Any later resume rechecks the cache-owned path, exact byte
  length, and SHA-256 before native package/signer verification runs again; **Windows**
  (no native C++) writes a PowerShell helper (`windowsUpdateScript`) that waits for our
  PID, rejects absolute/escaping/link archive entries, extracts into a new sibling staging
  directory, checks the expected executable, moves the old installation to a backup, swaps the
  staged directory into place, and restores/relaunches the backup when the replacement cannot
  start. The app then `exit(0)`s so `iptvs.exe` unlocks. **The helper is spawned via `cmd /c
  start` (`windowsUpdaterLaunch`), not a bare detached `powershell.exe`.** Its first act is
  `Wait-Process` on our GUI PID, so it is blocked when the app exits; a bare detached console
  child of a GUI process was torn down at that moment before creating any staging folder — the
  app closed and the update silently no-opped. `start` launches it as an independent,
  console-owning process that outlives the app. The helper also opens a `Start-Transcript`
  (`%TEMP%\iptvs_update.log`) so a failed run is diagnosable instead of invisible. This can only
  be executed end to end against a **packaged Release folder** on Windows, not `flutter run`; it
  requires a user-writable, unelevated install directory. **Linux** copies the verified AppImage beside the
running `APPIMAGE`, then a detached POSIX helper waits for our PID, atomically
swaps the file, relaunches it, and restores the backup if startup fails. Linux
in-app updates are available only from a writable AppImage; `flutter run` and
system-installed binaries fall back to the release page.
- **`lib/screens/update_flow.dart`** — `runUpdateCheck(context, manual:)` drives prompt →
  download → install (the "Update available" dialog with **Skip this version / Later / Update**,
  and the progress dialog). Entry points: a **manual** "Check for updates" `FocusableCard` on
  `sources_screen.dart` (`_UpdateCard`), and a **throttled startup** check in `home_shell.dart`
  (post-frame, release platforms only, honours the skipped version). Android records a verified
  APK before launching the system installer. Returning after an OEM Auto Blocker/settings detour,
  or recreating the app process, presents a **ready to install** prompt that reuses the cached APK;
  an already-upgraded app silently clears the pending record.

## D-pad behaviour

Each dialog's **primary action autofocuses** (so a TV remote's OK acts immediately — the modal's
focus scope otherwise lands on nothing until an arrow press), and the progress dialog carries an
autofocused **Cancel** (a focus target on TV + aborts a slow download; remote/system Back cancels
too). The "Update available" dialog (`_UpdateDialog`) **traps D-pad focus**: a boundary `Focus`
consumes bare Up/Down (they previously fell through the modal barrier onto the channel list
behind it on a TV) and cycles them between the actions and a focusable, scrollable changelog
rendered by `ReleaseNotesView` (formatted, not raw markdown). The public `showUpdateDialog` /
`UpdateChoice` exist so `test/update_dialog_test.dart` can pin the autofocus + focus-trap
behaviour.
The cached-update prompt follows the same primary-action rule: **Install** autofocuses, while
**Later** keeps the verified pending record for the next resume.

## Release-manifest signing

The update-manifest key is separate from Android app signing. Generate it outside the repository:

```bash
./tool/setup_update_signing.sh
```

The helper creates an Ed25519 private key, prints its raw 32-byte public key as Base64, and can
configure:

- protected `release` environment secrets `UPDATE_MANIFEST_PRIVATE_KEY_BASE64`
  and `UPDATE_MANIFEST_PRIVATE_KEY_PASSWORD`;
- repository variable `UPDATE_MANIFEST_PUBLIC_KEY`.

Permanent public verification key configured on 2026-07-14:

```text
JhwZvQIF8fgBgQoXkc+u3qcckiT94BEE6N4JRhcabLI=
```

Release builds embed only the public key through `--dart-define`. The publish job reconstructs
the manifest from the completed APK and ZIP, checks that the protected private key matches the
configured public key, signs the exact compact JSON bytes, and uploads the manifest plus detached
signature. Missing or mismatched keys fail the release. Keep two encrypted offline backups of the
private key; never commit it or its Base64 encoding. The owner confirmed both
private signing keys have two encrypted backups on 2026-07-14.
