# Store Publishing

This document tracks the permanent Android/Google Play and Windows/Microsoft
Store distribution paths. GitHub Releases remain a separate direct-download
channel and must not silently share incompatible signing or update behavior.

The legal publisher/display name for both stores is **George-Cosmin Hanta**.
The reserved public product name is **IPTVS Player**. It is separate from that
legal identity, the Android application ID, and the Microsoft package identity.

## Android and Google Play

### Identity recovery

The existing `com.gchofficial.iptvs` GitHub APKs use the public debug key. The
app has not been distributed through Google Play or another managed-signing
store. A new application ID is therefore the recommended secure identity.

Confirmed Google Play ID: `com.gchofficial.iptvs.player`

The Play Console application **IPTVS Player** was created with that permanent ID
on 2026-07-14. GitHub-direct Android uses the deliberately separate
`com.gchofficial.iptvs.player.direct`; development uses `.player.dev`. Each has
separate secure storage and application data. The cloud migration must be
device-tested before telling users that profiles migrate.

The selected transition is the existing authenticated cloud push/pull path;
there is no plaintext manual transfer. Exact retained and reset state plus the
old-app verification sequence are recorded in `docs/android-signing.md`.

### Keys

Run the interactive helper from a trusted local terminal:

```bash
./tool/setup_android_signing.sh
```

The helper:

- Refuses to create a key inside the repository.
- Uses a 4096-bit RSA key and a 16-character minimum password.
- Creates a long-lived PKCS12 app-signing keystore.
- Prints the public SHA-256 certificate fingerprint.
- Can configure the protected GitHub `release` environment after confirmation.
- Does not create a plaintext/base64 secret file.

This permanent key signs only direct GitHub APKs. Keep its two encrypted offline
backups. The Play identity is intentionally separate, so enroll it in Play App
Signing with a Play-managed app-signing key and create a separate upload key for
routine App Bundle uploads. Neither Play key should be reused for GitHub builds.

Create the separate Play upload key with:

```bash
./tool/setup_play_upload_signing.sh
```

This helper creates `iptvs-google-play-upload.p12` and its public PEM certificate
outside the repository. It can configure a separate protected GitHub
`google-play` environment. The environment requires:

| Type | Name |
|---|---|
| Secret | `PLAY_UPLOAD_KEYSTORE_BASE64` |
| Secret | `PLAY_UPLOAD_KEYSTORE_PASSWORD` |
| Secret | `PLAY_UPLOAD_KEY_ALIAS` |
| Secret | `PLAY_UPLOAD_KEY_PASSWORD` |
| Variable | `PLAY_UPLOAD_CERT_SHA256` |

The upload key authenticates uploads to Google; it is not the app-signing key
that Google uses for APKs delivered to users. For this new app, upload the first
AAB signed by the upload key and leave Play's recommended default selected. Play
App Signing then generates and protects a separate RSA-4096 app-signing key and
registers the AAB's signing certificate as the upload certificate. The exported
public PEM is retained for recovery/verification; do not follow the existing-app
PEPK flow or upload either private keystore. Losing an upload key is recoverable
through Play's upload-key reset process, but it must still be backed up and
protected.

Permanent Play upload certificate SHA-256:

```text
51:3E:75:95:25:81:15:09:1E:5C:EB:44:87:87:97:35:35:D3:90:02:20:15:FE:D0:AD:B9:C4:3C:99:A9:34:41
```

Permanent direct-distribution certificate SHA-256:

```text
6E:36:3B:97:B8:5A:D9:99:20:CC:56:0D:5D:BF:6E:CD:94:80:9E:3D:84:F4:F1:3A:65:5A:15:00:4A:50:D5:3B
```

### Play implementation checklist

Play Console identity verification and application creation completed on
2026-07-14. Package IDs cannot be renamed after publication.

- [x] Confirm the permanent application ID: `com.gchofficial.iptvs.player`.
- [x] Generate and back up the separate GitHub-direct app-signing key.
- [x] Configure the protected GitHub release environment.
- [x] Document the side-by-side cloud migration path and exact retained/reset
  state without adding a plaintext credential export.
- [ ] Exercise the cloud migration from a released old APK into Play and
  GitHub-direct device installs.
- [x] Create **IPTVS Player** in Play Console with the new ID.
- [ ] Enroll in Play App Signing with a Play-managed app-signing key by uploading
  the first signed AAB using Google's recommended default.
- [x] Generate and configure a separate Play upload key. Permanent upload
  certificate SHA-256 is `51:3E:75:95:25:81:15:09:1E:5C:EB:44:87:87:97:35:35:D3:90:02:20:15:FE:D0:AD:B9:C4:3C:99:A9:34:41`.
- [ ] Confirm two encrypted offline backups of the Play upload keystore and
  password.
- [x] Add a protected App Bundle build using the upload key.
- [x] Verify the AAB package name, updater exclusions, archive signature, and
  expected upload certificate in CI.
- [ ] Record and verify the Play-managed app-signing certificate on an installed
  internal-track APK.
- [ ] Complete privacy, data-safety, content-rating, phone, and TV listings.
- [ ] Test internal-track phone and Android TV installs before production.

New Google Play apps and TV apps are published as Android App Bundles. Do not
upload the direct-download APK as the Play production artifact.

The manual **Google Play Bundle** GitHub workflow produces a signed AAB for
manual Console upload. It intentionally does not publish to a track yet: no Play
service-account credential is needed in GitHub, and a human can review the first
few submissions while the listing and policy forms are incomplete. Add API
upload only when repeated manual uploads become a real maintenance cost.

### Android distribution flavors and testing

Android has explicit `development`, `githubDirect`, and `googlePlay` Gradle
flavors. The `googlePlay` manifest does not contain
`REQUEST_INSTALL_PACKAGES`, the updater `FileProvider`, or APK-installer package
visibility. Its Dart build channel is `googlePlay`, so startup checks and updater
settings are also absent. This is required because Play policy prohibits using
`REQUEST_INSTALL_PACKAGES` for application self-updates.

Use Play internal testing for mandatory pre-production Store validation. Ongoing
public beta builds remain on the separate GitHub-direct identity, so they can be
installed beside Play without signing or version-code conflicts. Do not switch a
Play installation to a GitHub APK from inside the app.
See Google's [testing-track guidance](https://support.google.com/googleplay/android-developer/answer/9845334)
and [`REQUEST_INSTALL_PACKAGES` policy](https://support.google.com/googleplay/android-developer/answer/12085295).

## Windows and Microsoft Store

### Public product name

`iptvs` was unavailable when checked in Partner Center on 2026-07-14. The owner
reserved **IPTVS Player** instead. Use this customer-facing title on Google Play
as well, and consistently in Store artwork, the app title, support pages, and
privacy policy. The repository name may remain `iptvs`; the Store title does not
determine the executable name or Android application ID.

### Recommended package type

Use a packaged MSIX submission rather than listing an unpackaged EXE/MSI:

- Microsoft hosts the package and signs it after certification.
- Windows manages installation and automatic updates.
- No paid Windows code-signing certificate is required for Store-only MSIX.
- Package flighting and Store restore/install behavior remain available.

The current GitHub artifact is a ZIP, not an offline EXE/MSI installer, so it is
not suitable for the Store's unpackaged Win32 route without building a separate
installer and purchasing/using trusted code signing.

### Partner Center information needed

In Partner Center, choose **New product > MSIX or PWA app** and reserve the app
name. Then copy the exact, case-sensitive values from **Product management >
Product identity**:

- Reserved product/display name
- `Package/Identity/Name`
- `Package/Identity/Publisher`
- Publisher display name
- Store/product ID

Do not invent these values in the manifest; Store submission will reject a
package whose identity does not match Partner Center.

### Reserved Partner Center identity

These values are exact and case-sensitive:

| Field | Value |
|---|---|
| Product/display name | `IPTVS Player` |
| `Package/Identity/Name` | `George-CosminHanta.IPTVSPlayer` |
| `Package/Identity/Publisher` | `CN=7DA809EF-3303-40F1-B760-21A6BCA24B17` |
| `Package/Properties/PublisherDisplayName` | `George-Cosmin Hanta` |
| Package Family Name | `George-CosminHanta.IPTVSPlayer_0a4z5zccam0py` |
| Package SID | `S-1-15-2-2604606762-3968970359-1786003176-2720169948-3773242850-1324970824-1308558992` |
| Store ID | `9P8KK9T379WN` |

### Required application changes

- Add an x64 MSIX packaging target using the Partner Center identity.
- Use four-part package versions with the fourth component reserved as `0`.
- Declare the desktop full-trust entry point and only required capabilities.
- Verify all runtime writes use application-data/cache directories; the installed
  package directory is read-only.
- Compile Store builds with a `microsoftStore` distribution-channel flag.
- Hide/disable GitHub update checks and detached PowerShell replacement in Store
  builds; Store-managed updates own that lifecycle.
- Keep the GitHub ZIP/direct updater as a separate `githubDirect` channel.
- Run the Windows App Certification Kit against the packaged Release build.
- Test clean install, upgrade, uninstall/reinstall, HDR surface creation, media
  playback, secure storage, firewall prompts, and file/cache persistence.

### Store submission checklist

- [x] Reserve the product name: `IPTVS Player`.
- [x] Record the Partner Center identity values above.
- [ ] Choose supported Windows versions and x64-only availability.
- [ ] Add deterministic MSIX packaging to the Windows release job.
- [x] Disable the self-updater in Store builds through build-time ownership:
  `microsoftStore` and `googlePlay` hide GitHub checks; `githubDirect` alone
  owns the self-updater.
- [ ] Validate package contents contain `iptvs.exe`, Flutter assets, and libmpv.
- [ ] Run the Windows App Certification Kit.
- [ ] Test installation and upgrade from Partner Center package flighting.
- [ ] Provide an accessible privacy-policy URL and support contact.
- [ ] Provide accurate screenshots, input requirements, and content disclosures.
- [ ] Give certification a testable demo path that needs no IPTV credentials.
- [ ] Confirm no bundled or promoted streams imply rights the app does not own.

## Release-channel invariant

```text
GitHub direct Android  -> signed APK, in-app authenticated updater
Google Play Android    -> signed AAB upload, Play-managed delivery
GitHub direct Windows  -> ZIP, authenticated in-app updater
Microsoft Store        -> MSIX, Store signing and Store-managed updates
```

The distribution channel is a build-time property. Runtime platform checks alone
cannot distinguish GitHub Windows from Microsoft Store Windows reliably enough
to decide who owns updates.

## Beta distribution model

| Installed channel | Beta mechanism | In-app GitHub updater |
|---|---|---|
| GitHub direct | User-selectable Stable/Beta signed GitHub release track | Enabled |
| Google Play | Internal track for Store validation; separate GitHub-direct app for ongoing beta | Disabled |
| Microsoft Store | Package flight for Store validation; portable GitHub-direct app for ongoing beta | Disabled |

GitHub beta builds are prereleases with the same signed-manifest and artifact
checks as stable direct builds. They use a separate Android application ID and,
on Windows, the portable distribution rather than Store MSIX identity. Store
users remain on Store-managed production updates. This deliberately avoids an
unsafe app toggle between incompatible installer/signing authorities.

Microsoft documents the known-user workflow under
[Package flights](https://learn.microsoft.com/en-us/windows/apps/publish/package-flights).
