# Store Publishing

This document tracks the permanent Android/Google Play and Windows/Microsoft
Store distribution paths. GitHub Releases remain a separate direct-download
channel and must not silently share incompatible signing or update behavior.

The legal publisher/display name for both stores is **George-Cosmin Hanta**.
The reserved public product name is **IPTVS Player**. It is separate from that
legal identity, the Android application ID, and the Microsoft package identity.

## Android and Google Play

### Package identities

Three permanent, deliberately separate application IDs — each with its own secure
storage and application data, so they install side by side:

| Channel | Application ID |
|---|---|
| Google Play | `com.gchofficial.iptvs.player` |
| GitHub direct | `com.gchofficial.iptvs.player.direct` |
| Development | `com.gchofficial.iptvs.player.dev` |

Package IDs cannot be renamed after publication. Moving a user between channels
goes through the authenticated cloud push/pull path — there is no plaintext
manual transfer; see `docs/android-signing.md` for exactly what is retained and
reset.

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

Permanent Play-managed app-signing certificate SHA-256:

```text
F4:D9:F8:2B:A1:DB:51:94:19:D4:9C:2B:7D:39:AA:A5:F0:10:A8:92:CB:F0:37:1A:AE:01:30:41:6E:DB:37:53
```

Google Play controls this app-signing key. It signs APKs delivered for
`com.gchofficial.iptvs.player`; it is intentionally different from the upload
certificate above.

Permanent direct-distribution certificate SHA-256:

```text
6E:36:3B:97:B8:5A:D9:99:20:CC:56:0D:5D:BF:6E:CD:94:80:9E:3D:84:F4:F1:3A:65:5A:15:00:4A:50:D5:3B
```

### Submission records

One-time launch evidence — completed checklists, dated identity-verification
records, and the submitted Play Console state (listing copy, App content answers,
Data safety declarations, asset inventory) — is kept out of the repo in
`docs/private/store-launch-record.md` and
`docs/private/google-play-submission-record.md`. It is an audit trail for one
publisher account, not something another developer can act on.

The reusable per-release checks are in
[`google-play-submission.md`](google-play-submission.md).

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

The reserved Store name is **IPTVS Player** (`iptvs` itself was unavailable). Use
that customer-facing title on Google Play as well, and consistently in Store
artwork, the app title, support pages, and privacy policy. The repository name
remains `iptvs`; the Store title does not determine the executable name or the
Android application ID.

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
| Store deep link | `ms-windows-store://pdp/?productid=9P8KK9T379WN` |
| Web Store URL | `https://apps.microsoft.com/detail/9P8KK9T379WN` |

Whole table verified against Partner Center **Product management → Product
identity** on 2026-07-25.

The three values that appear in the shipped package —
`Package/Identity/Name`, `Package/Identity/Publisher` and
`Package/Properties/PublisherDisplayName` — are pinned by
`tool/verify_windows_msix.ps1`, so identity drift fails the build rather than the
submission. The remaining rows (PFN, Package SID, Store ID, the two URLs) are
Store-assigned and derived from the identity; they are recorded here for
reference and are not settable in the manifest.

### Required application changes

- Declare the Store-provided `Microsoft.VCLibs.140.00.UWPDesktop` framework in
  the MSIX manifest. Flutter's Windows runner and native playback libraries use
  the Visual C++ runtime; the Store installs the declared framework alongside
  the app.
- Keep the exact Visual C++ Redistributable disclosure within the first two
  lines of the Partner Center description. The canonical, copy-ready listing
  and reviewer notes live in `assets/store/microsoft-store/listing.md`.
- The manual **Microsoft Store MSIX** workflow builds an unsigned x64 package
  from the Flutter Release payload using the exact Partner Center identity.
  `tool/package_windows_msix.ps1` creates the manifest and required logo sizes;
  `tool/verify_windows_msix.ps1` unpacks the result and rejects identity,
  version, capability, executable, Flutter asset, or libmpv drift.
- Store workflow inputs are three-part versions such as `1.2.3`; the package
  identity is always emitted as `1.2.3.0`. Each component must be at most
  65535, the **major component cannot be zero**, and the fourth component is
  reserved as `0` for Store use. This is why the Store version scheme is
  deliberately independent of the app's `0.x` GitHub/Play versions — do not try
  to keep them in step.
- Declare the desktop full-trust entry point and only required capabilities.
- Verify all runtime writes use application-data/cache directories; the installed
  package directory is read-only.
- Compile Store builds with a `microsoftStore` distribution-channel flag.
- Hide/disable GitHub update checks and detached PowerShell replacement in Store
  builds; Store-managed updates own that lifecycle.
- Keep the GitHub ZIP/direct updater as a separate `githubDirect` channel.

The public Store support and privacy contact is `support@iptvs.click`, received
through Resend inbound on the domain's MX record. The served pages
(`panel/public/{privacy,support,delete-account}.html`) already use it.

**The Partner Center and Play Console contact fields are set separately and must
be changed there to match** — a listing still pointing at the old address is not
wrong, just stale, but the two should not drift. Do it with the next submission
rather than mid-review.

Resend inbound delivers to a **webhook**, not a mailbox: an address with nothing
consuming it accepts mail and drops it. Confirm forwarding or a handler is live
before relying on this as the public support contact — the failure mode is
silent, and this address is on a privacy policy.

### Build and submission procedure

Run **Microsoft Store MSIX** manually with the next monotonically increasing
three-part version. The Store tracks its own sequence: check the last
`microsoft-store-msix-<version>` workflow artifact for what was submitted last,
since the Store version does not follow the app's GitHub/Play version.

The workflow compiles with `DISTRIBUTION_CHANNEL=microsoftStore`, omits the
GitHub update key, packages the Release directory, verifies the package by
unpacking it, and uploads an unsigned
`iptvs-<version>-windows-store-x64.msix` CI artifact for Partner Center. The
Store signs the package during certification; do not attach this unsigned MSIX
to GitHub Releases or distribute it for ordinary sideloading.

Each submission:

1. Replace the Partner Center description with the exact copy in
   `assets/store/microsoft-store/listing.md`; do not place text before its
   dependency disclosure.
2. Download the workflow artifact and upload only the `.msix` to the
   **IPTVS Player** product in Partner Center.
3. After certification, install through Microsoft Store and verify the package
   identity and Microsoft signature with `Get-AppxPackage` and
   `Get-AuthenticodeSignature` before public rollout.

Re-run the Windows App Certification Kit (against a locally test-signed copy of
the same Release package — test signing must not alter the submitted artifact)
and the full device flight matrix only when something in the packaging surface
changes: manifest capabilities, the entry point, bundled native libraries such as
libmpv, or the minimum Windows version. A routine version bump with no packaging
change does not need them; `tool/verify_windows_msix.ps1` already fails the build
on identity, capability, executable, Flutter-asset or libmpv drift. The original
launch matrix and its evidence are in `docs/private/store-launch-record.md`.

## Release-channel invariant

```text
GitHub direct Android  -> signed APK, in-app authenticated updater
Google Play Android    -> signed AAB upload, Play-managed delivery
GitHub direct Windows  -> ZIP, authenticated in-app updater
GitHub direct Linux    -> x86-64 AppImage, authenticated in-app updater
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
on Windows/Linux, the portable distribution rather than Store/MSIX identity. Store
users remain on Store-managed production updates. This deliberately avoids an
unsafe app toggle between incompatible installer/signing authorities.

Microsoft documents the known-user workflow under
[Package flights](https://learn.microsoft.com/en-us/windows/apps/publish/package-flights).
