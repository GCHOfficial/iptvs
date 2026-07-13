# In-app updates — full detail

The app self-updates from its own **GitHub Releases** (`GCHOfficial/iptvs`; the `release.yml`
pipeline attaches `iptvs-<ver>-android.apk` and `iptvs-<ver>-windows-x64.zip` to a `v<ver>` tag).
The compact rules live in CLAUDE.md; read this before changing the update flow, the release
pipeline, or the update dialog.

## Release changelog

The release body opens with a short **AI-generated changelog** (release.yml's "Generate AI
changelog" step: commit subjects since the previous tag → Gemini, key in the `GEMINI_API_KEY`
repo secret → `body_path`), with GitHub's auto-generated notes appended below. It tries
`gemini-3.5-flash` → `gemini-3.1-flash-lite` → `gemini-3-flash-preview` (two attempts each — the
primary 503s under load, which cut v0.1.29 without a changelog). The step is fail-open — no key /
no previous tag / API error just yields the auto notes — and the body is what the in-app update
dialog renders.

## Layering

Layered like everything else — a shared Dart service does the network check + version compare;
the final install step is the only platform-specific part.

- **`lib/data/update_service.dart`** — `ReleaseInfo` (+ the pure `ReleaseInfo.fromJson` that
  picks the per-platform asset by filename), `UpdateService.fetchLatest()` (GETs
  `releases/latest` with the `net.dart` `HttpClient` idiom; **GitHub 403s without a
  `User-Agent`**; 404 = "no releases yet" = up to date, not an error), `appVersion()` (via
  `package_info_plus` — returns the CI build-name, which is the tag minus `v`, so a release build
  reports `1.2.3` and compares equal to tag `v1.2.3`; local `flutter run` builds report the
  pubspec `1.0.0`), and the pure `compareVersions` / `isNewer` / `shouldAutoCheck` (unit-tested
  in `test/update_service_test.dart`).
- **`lib/data/update_store.dart`** — `skippedVersion` + `lastCheck` prefs in the keychain
  (mirrors `LocalProfileStore`; the app has no SharedPreferences).
- **`lib/data/update_installer.dart`** — `download()` (streams the asset to the temp dir with
  progress; **first file-writing code in the app**), then per platform: **Android** fires the
  system package-installer over the **`iptvs/updates`** MethodChannel (`installApk`), needing the
  `REQUEST_INSTALL_PACKAGES` permission + a **FileProvider** (`${applicationId}.fileprovider`,
  `@xml/file_paths` → `<cache-path>`, since `getTemporaryDirectory()` = the Android cache dir) —
  falls back to `requestInstallPermission` (unknown-sources settings) or the browser; **Windows**
  (no native C++) writes a detached PowerShell helper (`windowsUpdateScript`) that
  `Wait-Process`es our PID, `Expand-Archive -Force`s the zip over the install folder, and
  relaunches — then the app `exit(0)`s so `iptvs.exe` unlocks (the Windows swap can only be
  verified against a **packaged Release folder**, not `flutter run`; needs a user-writable,
  unelevated install dir).
- **`lib/screens/update_flow.dart`** — `runUpdateCheck(context, manual:)` drives prompt →
  download → install (the "Update available" dialog with **Skip this version / Later / Update**,
  and the progress dialog). Entry points: a **manual** "Check for updates" `FocusableCard` on
  `sources_screen.dart` (`_UpdateCard`), and a **throttled startup** check in `home_shell.dart`
  (post-frame, release platforms only, honours the skipped version).

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
