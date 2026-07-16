# Android Release Signing

This document records the signing recovery, permanent release-signing rules,
and the evidence required before changing the Android package identity.

## Confirmed release history

The public GitHub release `v0.1.30`, published on 2026-07-14, contains
`iptvs-0.1.30-android.apk` with SHA-256:

```text
8cbbc6254243f6a39b2d7f9ddf051010eb1b4502639f2f5dee99b3c08177eb75
```

`apksigner verify --verbose --print-certs` reports:

```text
Certificate subject: CN=Android Debug, O=Android, C=US
Certificate SHA-256: CF:3C:C3:53:C7:02:B4:D5:48:E7:4C:75:32:25:61:2C:4E:AA:D9:4A:E0:E9:FB:D4:1C:BE:4A:C6:9C:85:3E:EC
Signature scheme: v2
```

That fingerprint matches `android/app/debug.keystore`. The Gradle files at both
the first public tag (`v0.1.0`) and latest inspected tag (`v0.1.30`) assign this
debug configuration to the release build type. Existing direct-download installs
must therefore be treated as signed by a publicly available private key.

## Recovery decision

Status: **transition selected; Play migration verified, direct release
verification pending**.

Known distribution:

- GitHub Releases publishes a directly installable universal APK.
- Existing GitHub APKs use application ID `com.gchofficial.iptvs`.
- Google Play internal testing now has an enrolled Play App Signing population.

The first Play internal-testing AAB and a subsequent update were accepted on
2026-07-15. No public Play artifact has shipped.

The selected recovery uses separate new identities:

| Distribution | Application ID | Update owner |
|---|---|---|
| Existing compromised GitHub APK | `com.gchofficial.iptvs` | Retired |
| New GitHub direct Stable/Beta | `com.gchofficial.iptvs.player.direct` | Signed GitHub updater |
| Google Play | `com.gchofficial.iptvs.player` | Google Play |
| Local development | `com.gchofficial.iptvs.player.dev` | None |

The new GitHub and Play applications install beside both the old app and each
other. This prevents signer/version conflicts and lets Store packages omit the
self-updater. User state must be restored through authenticated cloud sync or an
explicitly encrypted user-controlled export. Signing lineage is not a secure
recovery from a public private key: another holder of that key can authorize a
different lineage.

Keeping `com.gchofficial.iptvs` with a new certificate is suitable only for clean
installs or a deliberately documented uninstall/reinstall transition. Android
will reject it as an in-place update for existing direct-download installations.

The Google Play application was created with its final ID on 2026-07-14.

Google Play uses a separate upload key and a Play-managed app-signing key. The
direct certificate recorded below must never be supplied as either of those
keys. Upload-key setup and CI values are documented in
`docs/store-publishing.md`.

On 2026-07-16, Android developer verification registered both active release
identities. `com.gchofficial.iptvs.player` is registered with Google's
Play-managed app-signing certificate
`F4:D9:F8:2B:A1:DB:51:94:19:D4:9C:2B:7D:39:AA:A5:F0:10:A8:92:CB:F0:37:1A:AE:01:30:41:6E:DB:37:53`.
The outside-Play `com.gchofficial.iptvs.player.direct` package is registered
separately with the permanent direct-distribution certificate recorded below.
On 2026-07-16, the base APK of the internal-track app installed by Play on an
SM-S938B was pulled with `adb` and checked with
`tool/verify_android_apk_certificate.sh`; `apksigner` reported the exact
Play-managed SHA-256 fingerprint above.

## User-data transition from the retired app

Android deliberately isolates application data by application ID and signing
identity. Therefore neither `com.gchofficial.iptvs.player` nor
`com.gchofficial.iptvs.player.direct` can read the retired
`com.gchofficial.iptvs` app's secure storage or SQLite database. Installing a
new app beside the old one does not migrate anything automatically, and the old
app must not be uninstalled until the user has verified the replacement.

The supported migration is authenticated cloud sync, not a plaintext source
export:

1. In the old app, pair Cloud Sync with the user's panel account.
2. Select or create the destination cloud profile and use **Push to panel**.
   This pushes the complete source list, per-source settings such as hidden
   categories, metadata-provider configuration, and live/movie/series
   favorites.
3. Install the new Play or GitHub-direct app side by side, pair it with the same
   account, select the same cloud profile, and pull.
4. Compare source counts and representative favorites, then test playback before
   removing the old app.

Cloud sync does **not** transfer device-local profile names, the active source,
EPG/media caches, playback positions/Continue Watching, diagnostics, or update
preferences. Those values start fresh. Users who do not opt into cloud sync
must re-enter their source configuration manually; there is intentionally no
credential-bearing plaintext export. The two new identities also remain
isolated from each other, so the same cloud procedure is required when moving
between Play and GitHub-direct installations.

## Permanent build rules

- Debug builds may use `android/app/debug.keystore` and are non-distributable.
- The normal build workflow compiles a debug smoke APK and does not upload it.
- Release builds never fall back to the debug signing configuration.
- A release task fails when any signing environment variable is absent.
- The release workflow verifies the built APK certificate against a separately
  configured expected SHA-256 fingerprint before uploading it.
- Private keystores, passwords, and `key.properties` files are never committed.

Required Gradle environment variables:

```text
IPTVS_ANDROID_KEYSTORE_PATH
IPTVS_ANDROID_KEYSTORE_PASSWORD
IPTVS_ANDROID_KEY_ALIAS
IPTVS_ANDROID_KEY_PASSWORD
```

Required protected GitHub `release` environment configuration:

| Type | Name |
|---|---|
| Secret | `ANDROID_RELEASE_KEYSTORE_BASE64` |
| Secret | `ANDROID_RELEASE_KEYSTORE_PASSWORD` |
| Secret | `ANDROID_RELEASE_KEY_ALIAS` |
| Secret | `ANDROID_RELEASE_KEY_PASSWORD` |
| Variable | `ANDROID_RELEASE_CERT_SHA256` |

Configure required reviewers on the `release` environment. Build jobs receive
read-only repository access; only the final publish job receives
`contents: write`.

## Creating the permanent key

The permanent direct-distribution app-signing key was generated outside the
repository on 2026-07-14. Its non-secret identity is:

```text
Alias: iptvs-app
Certificate subject: CN=iptvs, O=George-Cosmin Hanta, C=RO
Certificate SHA-256: 6E:36:3B:97:B8:5A:D9:99:20:CC:56:0D:5D:BF:6E:CD:94:80:9E:3D:84:F4:F1:3A:65:5A:15:00:4A:50:D5:3B
```

The four signing secrets and `ANDROID_RELEASE_CERT_SHA256` variable are
configured in the GitHub `release` environment. Passwords and keystore contents
must never be copied into this document.

Generate the key on a trusted offline machine, outside the repository:

```bash
keytool -genkeypair -v -keystore iptvs-release.jks -alias iptvs \
  -keyalg RSA -keysize 4096 -validity 10000
```

Record the public certificate fingerprint:

```bash
keytool -list -v -keystore iptvs-release.jks -alias iptvs
```

Encode the keystore for the GitHub secret without printing it into logs:

```bash
base64 -w0 iptvs-release.jks > iptvs-release.jks.base64
```

Keep at least two encrypted offline backups. Loss of the signing key prevents
future direct-download updates; disclosure allows malicious replacement APKs.

## Verification checklist

- [x] Store/distribution inventory is complete.
- [x] Package-ID transition is selected and documented.
- [x] User-data migration behavior is tested with the Play internal build;
  cloud sources/favorites restored and documented device-local exclusions began
  fresh.
- [x] Permanent signing key is generated outside the repository.
- [x] At least two encrypted offline backups of the permanent key and credentials
  are confirmed by the owner.
- [x] Protected environment secrets and expected fingerprint are configured.
- [x] `flutter build apk --debug --flavor development` succeeds without release
  secrets.
- [x] `flutter build apk --release --flavor githubDirect` fails without release
  secrets.
- [x] A secret-backed release build succeeds with a disposable `/tmp` validation
  key; this does not replace creation of the protected permanent key.
- [x] `apksigner` reports the disposable validation fingerprint, proving the
  Gradle environment-variable path signs the output.
- [x] A protected GitHub release run reports the permanent fingerprint above.
- [x] A minimum-SDK (API 26) install/start smoke test passes. Current API 36
  phone/TV and Play internal-update paths are verified; every intermediate API
  is not required as an early-testing gate.
