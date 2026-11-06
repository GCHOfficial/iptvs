# In-app updates — full detail

The app self-updates from its own **GitHub Releases** (`GCHOfficial/iptvs`; the `release.yml`
pipeline attaches `iptvs-<ver>-android.apk`, `iptvs-<ver>-windows-x64.zip`,
`iptvs-<ver>-linux-x86_64.AppImage`, and a detached
Ed25519-signed manifest to a `v<ver>` tag).
The compact rules live in CLAUDE.md; read this before changing the update flow, the release
pipeline, or the update dialog.

## Cutting one

Two routes, and **the tag is what the release is addressed by either way**. Pushing a `v<ver>` tag
runs the pipeline directly. A manual `workflow_dispatch` (the only way to reach the `beta` track)
takes the version as an input and **creates the tag itself** at the dispatched commit, because the
publish step runs `gh release create --verify-tag` and refuses a tag that does not exist — a
dispatch without that step builds all three platforms and then aborts at the last one.

That step probes for the tag with a **REST status check**, the same idiom the publish step uses
for the release itself and for the same reason: `gh api --jq` prints a 404's error body to
*stdout*, so a missing tag came back as the string `{"message":"Not Found",...}` and the guard
read every absent tag as an existing one — a dispatch could never create its own tag, and died
here with `already exists at {"message":"Not Found"...}`. Only a real HTTP 404 counts as absent;
anything else is transient and fails the step rather than being mistaken for it.

That step never *moves* an existing tag. A published release is addressed by it, users may already
hold the artifacts it named, and the signed manifest authenticates a specific build — re-pointing
it would invalidate all three, so a tag that exists at a different commit is a hard failure asking
for a new version instead.

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

## Crash reporting (Sentry)

The three release workflows — `release.yml`, `google-play.yml`, `microsoft-store.yml` — pass
**`--dart-define=SENTRY_DSN=${{ vars.SENTRY_DSN }}`** on their build command, and each one runs
`tool/sentry_register_release.sh <version>` afterwards. `build.yml` deliberately passes **no**
DSN on any of its six builds: CI builds crash on purpose (that is what a lint gate is for) and
every one of those would be charged against an organisation-wide 50 000 errors/month quota that
is shared with another product. An absent DSN means the SDK is never started at all, so leaving
it out is the whole of that protection — see CLAUDE.md's Sentry bullet and
`lib/data/crash_reporter.dart`. The **one** other workflow that passes a DSN is the dispatch-only
`crash-test-apk.yml`, below.

`release` is `iptvs@<build name>` — the tag minus its `v`, the same string the workflow passes
to `--build-name` — and `dist` is the build number (`github.run_number`, or `0` for the Store).
`environment` is the existing `DISTRIBUTION_CHANNEL` define, so the dashboard separates
`githubDirect` from `googlePlay` and `microsoftStore` without a fourth knob. The Android native
layer reports the same three, because the Dart SDK is what configures it (`autoInitializeNativeSdk`
stays at its default `true`, and `configureAndroidOptions` maps release/dist/environment across).

The registration step is **`continue-on-error` and the script exits 0 on every path**. A Sentry
outage, a rotated token or a fork with no secrets must never be the reason a release does not
ship; the release object is a convenience anyway, since Sentry creates one implicitly from the
first event carrying the tag. The token is `secrets.SENTRY_AUTH_TOKEN`, passed through `env:` and
never interpolated into a `run:` block. It is a **personal** user token (scopes `org:read
project:read project:releases`, as Sentry reports them), so it acts as its owner and lives **only as an environment secret** on `release`, `google-play` and
`microsoft-store` — each gated on a required reviewer — never at repository level, where any
workflow could read it. `sentry-check.yml` borrows the `release` environment for the same reason,
so each of its runs waits for that approval; `SENTRY_ORG`, `SENTRY_PROJECT` and `SENTRY_URL`
(`https://de.sentry.io/` — the organisation is in the EU region) are repo *variables*, like
`SUPABASE_URL`. No new Action is added, so there is no new SHA to pin.

### Symbols: the engine's are uploaded, ours aren't

The release builds do **not** pass `--split-debug-info` or `--obfuscate`, and none of *our* debug
information is uploaded. That is a decision, not an omission:

- `--split-debug-info` is what turns Dart AOT stack traces into bare addresses: it is the only
  thing that adds `--dwarf-stack-traces` to the `gen_snapshot` invocation
  (`flutter_tools/lib/src/base/build.dart`, the `shouldSplitDebugInfo` block). Without it, every
  Dart frame Sentry receives already carries its function name and `package:` URI. Adding it and
  uploading the symbols would be net-neutral when the upload works and strictly worse when it
  does not — and an upload that "must never fail a release" is, by construction, one that can
  fail. Sentry does not re-symbolicate events it has already processed, so a single failed upload
  would make that whole release's crashes permanently unreadable.
- The other three artifacts named in the usual recipe do not exist here. Windows Release builds
  emit **no PDBs** (`windows/CMakeLists.txt` sets no `/Zi`, and anything that appeared next to
  the exe would be swept into the public release zip by its `Release/*` glob), Linux Release
  compiles with **no `-g`**, and the `.so`s in the APK are third-party prebuilts shipped stripped.
- **The Flutter engine's symbols are uploaded** (`tool/sentry_upload_engine_symbols.sh`, in the
  Android build jobs of `release.yml` and `google-play.yml`). The engine (`libflutter.so`) is
  where the Play-vitals native crashes lived (Impeller, Skia's text layout, the Dart VM), and
  without its symbols those frames arrive as bare addresses. Google publishes them per engine
  revision and ABI (`flutter_infra_release/flutter/<rev>/android-{arm,arm64,x64}-release/
  symbols.zip`). The script reads the revision from `flutter --version --machine`, downloads all
  three, and runs a pinned `npx @sentry/cli@3.8.0 debug-files upload`. It is `continue-on-error`,
  exits 0 on every path, and the token only arrives via `env:`.
  - If it fails for a release, that release's engine frames stay unsymbolicated, since Sentry
    doesn't re-symbolicate processed events. Dart frames are unaffected.
  - There are **no** published engine symbols for `windows-x64` or `linux-x64` at the current
    revision, so desktop engine frames stay unsymbolicated.
- **Kotlin/Java frames are R8-obfuscated, and the mapping is uploaded per build.** Flutter's Gradle
  plugin turns on R8 shrinking *and* obfuscation for every `--release` APK/AAB unless `--no-shrink`
  is passed, and none of our builds pass it: in the shipped 0.1.76 APK the only readable
  `com.gchofficial.iptvs` classes are the two manifest-declared activities, and a real crash-test
  event arrived as `at f5.run(r8-map-id-f87c1a5f…:73)`. Deobfuscating that needs two halves agreeing
  on one identifier, and **the identifier cannot be derived**, because the mapping file does not
  exist yet when the manifest is merged. So CI generates it:
  - Each Android job runs `uuidgen` into `IPTVS_SENTRY_PROGUARD_UUID` (through `$GITHUB_ENV`, so the
    build step and the upload step cannot disagree) **before** the build.
    `android/app/build.gradle.kts` validates it and feeds two manifest placeholders;
    `AndroidManifest.xml` carries one `<meta-data>` whose **name** is a placeholder too. With a UUID
    the key is `io.sentry.proguard-uuid` — what sentry-java 8.62.0's `ManifestMetadataReader` reads
    (`PROGUARD_UUID`, line 108, applied at line 550) into `SentryOptions.proguardUuid`, which
    `DebugMeta.createDebugImagesFromOptions` attaches to every event as the `proguard` debug image.
    Without one the key becomes `io.sentry.proguard-uuid.unset`, which sentry-java never looks for,
    so the option stays null and no image is attached. **Rewriting the key rather than blanking the
    value is the point:** `readString` would hand back `""` and that image check is `!= null`, so an
    empty value would ship an unresolvable empty-UUID image on every event. A set-but-malformed UUID
    fails the build (only a broken workflow edit can cause it); unset is the ordinary local case.
  - **The manifest alone does nothing, because the Dart init overwrites it.** `sentry_flutter`
    10.3.0 starts the Android SDK from Dart, and its `configureAndroidOptions`
    (`sentry_native_java_init.dart:237`) runs inside `SentryAndroid.init`'s options callback —
    *after* the manifest has been read — and assigns `androidOptions.proguardUuid =
    options.proguardUuid`. Left null on the Dart side, that nulls the manifest value, and every
    Java/Kotlin event goes out naming no mapping. The 2026-11-04 crash test showed exactly this:
    mapping uploaded, manifest correct, frame still `f5.run(r8-map-id-…:73)`. So
    `CrashReporter.start` reads the value back out of the **merged manifest** over `iptvs/device`
    (`sentryProguardUuid`, `MainActivity`) and sets `SentryFlutterOptions.proguardUuid` to it. Read
    back rather than passed as a `--dart-define`, so the manifest stays the one source and nothing
    has to be kept in step with it. The rejected alternative — initialising the Android SDK
    ourselves in Kotlin so nothing overwrites the manifest — would move every privacy option,
    the consent gate and the crash-loop guard out of the one place they are set, and change when the
    native crash handlers are installed.
  - **What proves it is the event, never the build.** The crash-test workflow keeps its
    `mapping.txt` as an artifact so the deobfuscated Kotlin frame can be predicted before the button
    is pressed, and `sentry-check.yml`'s optional `event_id` input reads that event back: its
    `proguard` image, processing errors, and in-app frames.
  - After the build, `tool/sentry_upload_proguard_mapping.sh <mapping.txt> <uuid>` uploads
    `build/app/outputs/mapping/<variant>/mapping.txt` with the pinned
    `npx @sentry/cli@3.8.0 upload-proguard --uuid … --require-one`. `--uuid` is hidden from that
    version's `--help` but present and honoured — it is what the Sentry Gradle plugin passes, and the
    pin is what keeps it from moving. Variants: `githubDirectRelease` (release.yml),
    `googlePlayRelease` (google-play.yml), `developmentRelease` (crash-test-apk.yml). If the given
    path is missing the script falls back to the one unambiguous `mapping.txt` under the output tree
    and says so, because a wrong variant path would otherwise degrade silently for months.
    Like the engine-symbol upload it is `continue-on-error`, exits 0 on every path, and takes the
    token only through `env:`.
  - **It uploads a *copy* stamped with `# iptvs-proguard-uuid: <uuid>`, and that line is
    load-bearing.** Sentry decides what it is missing by the file's **checksum**, not by the UUID
    the caller asserts, so a mapping byte-identical to one already on the server is answered
    `Nothing to upload, all files are on the server` and the new UUID is attached to **nothing** —
    silently, with a zero exit. `release.yml` and `google-play.yml` build the same commit and R8
    can emit identical mappings for both, so the second channel's frames would stay obfuscated
    while every step stayed green; two consecutive `sentry_pipeline_check.sh` runs reproduced it.
    R8's own header is a block of `#` comments, so this is the file's native comment syntax, and
    the line is what makes the bytes unique per UUID. The script warns loudly if it ever sees
    `Nothing to upload` for a freshly generated UUID, since with the stamp that can only mean the
    stamp stopped working.
  - The pipeline check's step 5 therefore demands **both halves**: `UPLOADED <probe uuid>` in the
    CLI output *and* a read-back of that debug id from the API. A silent exit 0 is not proof.
  - **This is not the Sentry Gradle plugin**, which stays banned: it instruments bytecode, turning
    `android.util.Log` into breadcrumbs and auto-instrumenting HTTP, and our provider URLs carry
    credentials.
  - **0.1.76 and every earlier build stay obfuscated, permanently.** Their APKs carry no UUID, and
    Sentry does not reprocess events it has already handled — this works from the next release on.
  - Play's own vitals were never affected: an AAB carries its mapping to Play.
  - `tool/sentry_pipeline_check.sh` now also runs this upload with a synthetic mapping, because the
    mapping upload needs a different token scope from the debug-file upload and a release-time
    failure is only a warning.

### The `renderer` tag

Every event carries a `renderer` tag (`impeller` / `skia-gl`), so the Android renderer denylist
(docs/player.md "The Flutter renderer") is answerable from the dashboard rather than from a guess:
a recurrence of the TCL/RTD2875P native crashes on an event tagged `skia-gl` would rule the
renderer out, which is exactly what that denylist is betting against.

It is set **twice, on purpose**, because the Dart `beforeSend` is not the whole chokepoint:

- `CrashReporter._tagRenderer` puts it on the **Dart** scope after `SentryFlutter.init` returns.
  `sentry_flutter` installs a `NativeScopeObserver` and leaves `enableNdkScopeSync` at its default
  `true`, so a Dart `setTag` is mirrored onto the Java SDK's scope (`Sentry.setTag` over JNI) and
  from there into sentry-ndk's.
- `NativeCrashScrubber`'s Java `beforeSend` stamps it too, which is what makes it independent of
  scope-sync *timing* and of whether an event's scope survived the process. That one callback is
  the only place Java/Kotlin exceptions, NDK crashes and Android 12+ tombstones all pass through —
  the same reason the redaction lives there. It fills the tag **only when nothing has set it**, so
  an envelope replayed from a previous launch's outbox keeps the renderer it actually crashed on.

The value is not PII and is one of two fixed words plus, in the diagnostics log only, a reason
(`default` / `manifest` / `forced-debug` / `soc:<MODEL>`).

### Every diagnostics export names its build

`DiagnosticsLog.asText`/`asTextBounded` put `app=<version>+<build> channel=<rawChannel>` in the
header, beside `entries=`. Without it "it still happens" and "it happens again on the build that
was supposed to fix it" are the same text, and the Send-diagnostics path had no other field saying
which build a log came from. `channel` is the **raw** `DISTRIBUTION_CHANNEL` define rather than the
parsed enum, because an unrecognised value parses to `development` and a build whose channel define
was wrong is exactly the one that needs to say so. The version is read asynchronously
(`PackageInfo.fromPlatform`, un-awaited in `main`), so an export taken in the first moments of a
launch reads `app=unknown` rather than silently omitting the field. The bounded variant measures
its header, so the extra line is accounted for in the trim rather than pushing the result over the
256 KiB server cap.

### The send budget

`CrashBudget` (`lib/data/crash_budget.dart`) and its Kotlin twin `CrashBudgetFile`
(`crash/CrashScrub.kt`) share one line-oriented file in the app's support directory and apply the
same four limits to every event either language sends: 5 per session, 20 per rolling 24 h, 60 per
rolling 30 days, and **one event per fingerprint per 24 h**. The caps are explained in CLAUDE.md;
the fingerprint is the part with a trap in it.

**The fingerprint is built from the *innermost* frames, and the order is load-bearing.** Sentry's
protocol stores a stack trace **outermost first** — sentry-dart reverses the parsed Dart trace in
`SentryStackTraceFactory.parse`, and sentry-java calls `Collections.reverse` at the end of
`SentryStackTraceFactory.getStackFrames` — so `frames.first` is the process entry point and
`frames.last` is the throw site. Both halves used to take the *first* three frames whenever no
frame was marked in-app, which on Android means the same three for every uncaught main-thread
exception that will ever be thrown:

```
com.android.internal.os.ZygoteInit.main
com.android.internal.os.RuntimeInit$MethodAndArgsCaller.run
java.lang.reflect.Method.invoke
```

Every Kotlin crash of one exception type therefore shared one fingerprint, and a device sent the
first and silently dropped the rest for 24 h. `fingerprintFrames` (Dart) /
`CrashScrub.fingerprintFrames` (Kotlin) now read the list from the throw site outwards: the
innermost in-app frames when the event has any, otherwise the innermost three. Pinned against the
real `IPTVS-2`/`IPTVS-4` frame list in `test/crash_reporting_test.dart` and `CrashScrubTest`, with
two crash sites behind the identical framework prefix.

**On Android no frame is ever in-app, so the fallback is the only path there.** sentry-java decides
`SentryStackFrame.isInApp` from `SentryOptions.inAppIncludes`, there are no default excludes, and
the single include is the one `AndroidOptionsInitializer.readDefaultOptionValues` adds: the
**applicationId**, `com.gchofficial.iptvs.player[.dev|.direct]`. This app's classes live under the
**namespace** `com.gchofficial.iptvs`, which is not a prefix of it, so `isInApp` comes back `null`
for app and framework frames alike. `sentry_flutter` 10.3.0 configures neither list
(`configureAndroidOptions` never touches them). Widening the include would not fix it either: R8
renames app classes, and the shipped frame really is `f5.run`. Dart events are unaffected —
sentry-dart marks `package:iptvs` frames in-app — but they get the same innermost-first rule, since
the two languages share one budget file and a rule that differed would de-duplicate one fault twice.

The change makes every stored fingerprint stale, which costs nothing: an unmatched `seen` key
simply never de-duplicates and the entries expire after 24 h. The file format is **not** bumped,
because bumping it would also discard the three rolling counters, which are real quota accounting.

**A refusal now leaves exactly one line.** Dart writes
`crash report dropped (duplicate|session|day|month) fp=<first 8 hex>` to `DiagnosticsLog`
(`library` scope, so it rides an exported log); Kotlin writes the same text through
`Log.w("IptvsCrash", …)`. Kotlin deliberately does **not** use the exportable log: the only
native→Dart relay this app has is `MainActivity.logPlaybackDiagnostic`, which pushes on
`iptvs/native_hdr_player` — a channel whose Dart handler exists only while a player route is
mounted, and which must be called on the main thread, while `beforeSend` runs on whichever thread
just crashed. Both lines are credential-free by construction: one of four fixed words plus a hash
prefix. Before this, a refused event left no trace at all on either side, so "the crash was never
reported" and "the crash reported once and was de-duplicated for a day" were indistinguishable from
a user's export — which is the one question a budget is asked.

**Field note (2026-11-04), so it is not re-litigated.** Three crash-test Kotlin events were admitted
within five hours of one another on one phone (15:16Z, 19:07Z, 19:51Z) with the same exception type
and stack shape, which looks like evidence that the de-duplication was working. It is not: the three
events carry three different `device.id` context values (`a966cfed…`, `55a6828e…`, `f0e03868…`).
That id is sentry-java's `Installation.id`, a UUID file in `context.getFilesDir()` — the same
directory `getApplicationSupportDirectory()` returns and the budget file lives in. Three different
ids mean the directory was emptied before each dispatch's install, so each event met an empty
budget. The admissions say nothing about the fingerprint either way.

### The crash-test APK

Nothing in CI can prove that crash capture works end to end. CI may not carry a DSN (the rule
above), a unit test cannot start the SDK at all, and the two handlers that matter most — the NDK
signal handler and the Android 12+ tombstone integration — are only installed on a real device by
a real `--release` build. So the proof is a **hand-dispatched APK with four deliberate faults in
it**: `.github/workflows/crash-test-apk.yml`, `workflow_dispatch` only, never on push, PR or
schedule.

**The deliberate exception to "only the three release workflows pass a DSN".** That build passes
`--dart-define=SENTRY_DSN=${{ vars.SENTRY_DSN }}` *and*
`--dart-define=IPTVS_CRASH_TEST=true`. The second define is what makes the first one safe to
grant: it forces `options.environment` to **`crashtest`** (`sentryEnvironment` in
`lib/data/crash_test.dart`, applied in `crash_reporter.dart`), so the whole run can be selected
or discarded in the dashboard with `environment:crashtest` and no manufactured event is ever
mistaken for a field report. Nothing else about the pipeline changes: the consent switch, the
crash-loop guard and every `CrashBudget` cap still apply — the budget is *part of what is being
proven*, which is why fault (d) exists.

**What is in the build.** `kCrashTest` is a compile-time `bool.fromEnvironment`, a `const false`
everywhere else, so the Diagnostics screen's "Crash test" section
(`lib/screens/crash_test_section.dart`) and everything it reaches are tree-shaken out of a
shipped app. The section is `FocusableCard`-based and carries no text field, so it is D-pad
navigable like the rest of the screen; each action states in one line what should appear in
Sentry, and a status line says whether the SDK is actually running — without it a working scrub
and a build that never started Sentry look identical from the dashboard (nothing arrives).

| # | Fault | What it proves |
|---|-------|----------------|
| a | Uncaught Dart `CrashTestException` thrown from a `Timer` | The Dart `beforeSend` runs, `cleanCrashText` scrubs the fake provider URL, and the event is charged to `CrashBudget`. Thrown from a timer because `main` installs no `runZonedGuarded`, so an error escaping a timer callback reaches `PlatformDispatcher.onError` — the hook `sentry_flutter`'s `OnErrorIntegration` installs. Thrown inline it would be caught by the framework's gesture guard and arrive as a different event entirely. |
| b | Uncaught Kotlin `RuntimeException` on the Android main thread | sentry-java's `UncaughtExceptionHandlerIntegration` captures a Java-side event at all, and `NativeCrashScrubber` — **not** the Dart `beforeSend`, which never sees one — is what redacts the URL. The handler replies to the method call *first* and then `post`s the throw: thrown inline it would not be uncaught, because `MethodChannel`'s incoming handler wraps `onMethodCall` in a try/catch and turns the exception into an error reply. |
| c | `raise(SIGSEGV)` through `dart:ffi` on the UI thread | The NDK handler writes an outbox envelope that the **next** launch sends, and `libflutter.so` frames symbolicate against the engine debug files already uploaded for this engine revision. This is why the APK must be `--release`: the debug files are for the release-mode engine. |
| d | A repeat of (a), from the same throw site | `CrashBudget`'s one-event-per-fingerprint-per-24 h de-duplication drops it. It only works because `runCrashTest` funnels both actions through one `_throwUncaughtDartException`; two throw sites would mean two fingerprints and two admitted events. |

**The fake credentials are pinned against the scrubber.** `crashTestLocator` builds
`http://panel.example.com:8080/live/<user>/<pass>/4821.ts?token=<token>` at runtime from parts —
the two shapes the redaction has to handle, assembled rather than written as one literal so the
source carries no credential-shaped pair for GitGuardian to flag. A crash test quoting a URL the
scrub already ignores would "pass" while proving nothing, so
`test/crash_reporting_test.dart` asserts the Dart message against `cleanCrashText` and
`CrashTestTest` asserts the Kotlin twin against `CrashScrub.redactText`. The strings to grep a
Sentry event for are `crashtest-example`, `not-a-real-secret` and `not-a-real-token`; if any of
them reaches the dashboard, the scrubbing is broken.

**The Kotlin gate reads the same define, not a second switch.** `android/app/build.gradle.kts`
decodes Flutter's `dart-defines` project property (the comma-joined, base64-encoded `KEY=VALUE`
list `flutter_tools`' `encodeDartDefines` produces and `FlutterPlugin.kt` forwards) into
`BuildConfig.CRASH_TEST`. An environment variable beside the define would have mirrored the
release-signing block in the same file, and was rejected for exactly that reason: two switches
that can be set independently will eventually disagree, and the disagreement is silent. The
decode fails **closed** — absent property, unparseable entry or any value but the literal `true`
leaves it false — and no release workflow passes the define, so no distributable build can reach
the `true` branch. In a normal build `MainActivity`'s `crashTestThrow` branch answers
`notImplemented()` and R8 folds it away.

**Build shape.** `--release`, `development` flavor (applicationId
`com.gchofficial.iptvs.player.dev`, so it installs *beside* a store or GitHub-direct build rather
than replacing it — verified by `tool/verify_android_distribution_manifest.sh`), signed with the
committed **public** debug keystore exactly as `build.yml`'s release-lint build, uploaded as a
7-day artifact named `iptvs-crash-test-apk-NOT-FOR-DISTRIBUTION`. It could not be published even
by accident: the release workflow verifies the certificate against the protected fingerprint.
Supabase config is deliberately not passed — the cloud panel has nothing to do with crash
capture. `FLUTTER_VERSION` must stay in step with `build.yml`'s, or the engine frames in fault
(c) have no matching debug files and arrive as bare addresses. The job runs in the protected
`release` environment, for the `SENTRY_AUTH_TOKEN` the R8-mapping upload needs — so **every
dispatch now waits for the owner to approve it**, a second cost on a build that crashes itself
against a shared error quota. It uploads its own `developmentRelease` mapping, because fault (b)
otherwise proves capture without proving readability. `--build-name` comes from a dispatch input
defaulting to **`0.0.0-crashtest`**: without it these events report `iptvs@1.0.0`, the pubspec
default this project has never shipped, and tagging four deliberate faults with a *real* version
would corrupt that release's crash-free rate and "first seen in".

## Discord announcement

The last step of the publish job posts the release to Discord (`DISCORD_RELEASE_WEBHOOK` repo
secret; the step is skipped when it is absent, so forks neither post nor fail). Three things
about it are deliberate:

- **It runs after `gh release upload`, not before.** An announcement that lands before the
  assets exist points people at a release with nothing attached, and the upload is the step
  most likely to need a retry.
- **It reuses `body.md`** — the same Gemini changelog that becomes the release notes and feeds
  the in-app update dialog — so the three never disagree. That file is empty whenever the
  changelog step failed open, which is handled rather than posting a blank embed.
- **It is fail-open and payload-safe.** The release is already published by the time it runs, so
  a Discord outage logs a warning instead of turning a successful release red. The description
  is truncated to Discord's 4096-character embed cap (a longer changelog would otherwise get the
  *whole payload* rejected), and the JSON is built with `jq --arg` so markdown quotes, newlines
  and backslashes cannot break or inject into it.

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
  **Status:** the 0.1.38 rescue is complete — `linux-x86_64` is back in the signed manifest
  (`release.yml`), since every install is now 0.1.38+ (skip-unknown parser). Linux auto-update is
  live again.

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
  (`%TEMP%\iptvs_update.log`) so a failed run is diagnosable instead of invisible.
  **Both scratch directories are siblings of the install and are created hidden.** They have to
  share the install's volume — the swap is a rename, not a copy — so they cannot be moved to
  `%TEMP%`; an install in a visible location (a Desktop folder is the common case for the GitHub
  Direct zip) otherwise flashed `.iptvs-update-stage-*` and `.iptvs-update-backup-*` at the user
  for the seconds the swap took. Two consequences to keep intact: the staging folder *becomes* the
  install folder, so its Hidden attribute must be **cleared after the rename** (likewise on the
  rollback path, which restores from the hidden backup) or the app's own folder disappears from
  Explorer; and the helper `Set-Location`s to the parent first, because it inherits its working
  directory from the app it is replacing and a directory that is a live process's CWD cannot be
  deleted — which would strand the backup beside the install permanently. Backup/stage removal
  retries briefly rather than making one silent attempt. The success path (swap, un-hide, relaunch,
  cleanup) is covered by `test/windows_update_script_test.dart`, which runs the generated script for
  real against a launchable payload. This can only
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
