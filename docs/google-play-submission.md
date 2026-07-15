# Google Play submission — IPTVS Player

This is the working checklist for `com.gchofficial.iptvs.player`. Keep the
answers aligned with the shipped code and update this document whenever data
handling changes.

## Current internal test

- [x] Upload version `0.1.31` (`versionCode` 1) as an Android App Bundle.
- [x] Enrol in Play App Signing using the Play-managed app-signing key.
- [x] Create an internal release and add testers.
- [ ] Confirm the tester opt-in link installs on a physical phone.
- [ ] Record the installed APK's Play app-signing certificate fingerprint.
- [ ] Run the phone smoke test below.

For a new internal release, the opt-in and download links can take several
hours to become available. A temporary package-name listing can remain visible
for up to 48 hours. The app-setup forms do not block internal testing. If the
download link still returns a Google 404 after 24 hours:

1. Open **Test and release → Testing → Internal testing → Testers** and copy the
   current opt-in link again.
2. Confirm the phone's Play Store uses the same Google account that opted in.
3. Open the link in that account's browser, leave and rejoin the test, then open
   **View on Google Play**.
4. Confirm the release says **Available to internal testers**, the tester list
   is attached, and the tester's country is included under availability.
5. Clear only the Play Store app cache or try the link on mobile data. Do not
   upload a new version solely to fix propagation.

## Main store listing

Open **Grow users → Store presence → Main store listing**.

| Field | Submission value |
|---|---|
| App name | `IPTVS Player` |
| Short description | `Play IPTV sources you are authorised to access on phone and Android TV.` |
| App category | **App → Video Players & Editors** |
| Developer website | `https://gchofficial.github.io/iptvs/` |
| Privacy policy | `https://gchofficial.github.io/iptvs/privacy.html` |
| Support | `https://gchofficial.github.io/iptvs/support.html` |
| Contact email | `gchofficial@gmail.com` |

Suggested full description:

> IPTVS Player is a media player for IPTV services and playlists you already
> have permission to access.
>
> Add a Stalker portal, Xtream account, or M3U playlist and browse live TV,
> movies, and series in one interface. Provider support determines which
> channels, programmes, catch-up streams, and media details are available.
>
> Features include programme-guide browsing, catch-up playback, favourites,
> local profiles, Continue Watching, picture-in-picture on supported Android
> devices, and D-pad navigation designed for Android TV. Optional cloud sync
> lets you manage profiles and source configurations from a web panel and pair
> devices without typing an account password on a TV.
>
> IPTV subscriptions, channels, playlists, and media are not included. You must
> provide your own lawful source. IPTVS Player is not affiliated with or
> endorsed by IPTV providers, broadcasters, or content owners.

Do not add keywords implying that the app supplies free channels or copyrighted
content. Do not use provider logos or screenshots containing content for which
the publisher lacks promotional rights.

### Graphic assets

- [x] 512 × 512 32-bit PNG app icon at
  `assets/store/google-play/icon-512.png` (opaque alpha, under 1 MB).
- [x] 1024 × 500 24-bit PNG feature graphic at
  `assets/store/google-play/feature-graphic.png`; editable source is the SVG
  beside it.
- [x] Five real 1440 × 2921 phone screenshots in
  `assets/store/google-play/androidphone*.jpg`, with device EXIF removed.
  Prefer screenshots 2, 3, and 5 in that order. Recapture screenshot 1 after
  the phone-specific profile hint fix; screenshot 4 is valid but is a less
  compelling credential-form view.
- [x] Two real 3840 × 2160 Android TV screenshots in
  `assets/store/google-play/androidtv*.png`. Screenshot 1 should be recaptured
  after the compact 960 × 540 live-layout fix; screenshot 2 remains suitable
  for the native player-controls listing image.
- [x] 1280 × 720 Android TV banner at
  `assets/store/google-play/tv-banner.png`; editable source is the SVG beside
  it. This is separate from the launcher banner in the Android manifest.
- [ ] Add screenshot alt text where the Console offers it.

Capture only the bundled Demo source or media for which you own promotional
rights. Recommended screens: source picker with Demo, Live/EPG browsing,
fullscreen controls, favourites, and the cloud pairing screen. Never capture
real portal URLs, usernames, passwords, MAC addresses, API keys, or pairing
codes.

## App content answers

Open **Policy and programs → App content**. Wording and ordering in Console can
change; use the facts below rather than guessing from a differently worded
question.

### Privacy policy

- URL: `https://gchofficial.github.io/iptvs/privacy.html`
- The same policy is reachable inside the app from **Sources → info icon →
  Privacy policy**.
- Public privacy contact: `gchofficial@gmail.com`.
- Submit only after the page is deployed without authentication or geographic
  restrictions and its URL returns HTTP 200.

### App access / sign-in details

Select **All functionality is available without special access**. Reviewer
instructions:

> No login or paid IPTV credentials are required for review. Launch the app,
> create or select a local profile, choose Add source, select Demo, and save.
> The bundled Demo source exercises browsing and playback. Cloud sync is an
> optional feature and is not required to use the app.

If Play later requires testing the web panel, provide a dedicated reviewer
email flow through the Console's private instructions. Never put credentials in
the public store description.

### Ads

Select **No, my app does not contain ads**. Revisit this answer before adding
any advertising or sponsored-content SDK.

### Target audience and content

Recommended audience: **18 and over**, with **No, the app is not designed for
children**. The app is a general media player, but it accepts user-selected
services whose content the publisher does not control. Do not use child-directed
artwork or marketing.

Complete the IARC content-rating questionnaire using these invariants:

- It is an app, not a game.
- It does not bundle or sell media content.
- It does not contain ads, gambling, purchases, social sharing, chat, or
  user-to-user content publication.
- It can display third-party media selected by the user. If the questionnaire
  asks whether unrestricted external/user-provided content can be shown, answer
  **Yes** and use the explanation above.

Save a screenshot/PDF of the final questionnaire answers and generated rating
in the private release records; the exact questions vary by region and Console
version.

### Other declarations

| Declaration | Answer |
|---|---|
| Government app | **No** |
| Financial features | **None** |
| Health features | **None** |
| News app | **No** if asked |
| Advertising ID | **No**; the app does not use it |

### Data safety

Internal-only testing is exempt from displaying a Data safety section, but the
form is required before closed/production publication. Answer **Yes** to
collection because optional cloud sync transmits data to the developer's
Supabase project. The app remains usable without cloud sync, so every listed
type is **optional**.

Top-level answers after account deletion is deployed and verified:

- Data collected or shared: **Yes**.
- All collected data encrypted in transit: **Yes** for data collected by the
  developer cloud service (HTTPS/TLS).
- Users can request deletion: **Yes**.
- Data shared with third parties: **No**. Supabase and its email delivery
  subprocessors act as service providers. Requests sent directly to a
  user-selected IPTV or metadata provider are user-initiated and are not sent
  to the developer.

Declare these optional, collected, not-shared data types:

| Play data type | Examples in IPTVS Player | Purpose |
|---|---|---|
| Personal info → Email address | Magic-link panel account | Account management; app functionality |
| Personal info → User IDs | Supabase account ID | Account management; app functionality |
| Device or other IDs | App-generated anonymous paired-device identity | App functionality; fraud prevention/security |
| App activity → Other user-generated content | Profile/device labels, source configurations and credentials, metadata settings | App functionality |
| App activity → Other actions | Cloud-synchronised favourites | App functionality |

For each type: data is retained rather than processed ephemerally, collection
is optional, and it is not used for analytics, advertising, marketing, or sale.
Playback history, Continue Watching, EPG/cache rows, and diagnostics remain
local and are not developer-collected. If any telemetry, crash reporting, or
new SDK is added, re-audit the form before shipping.

The encryption answer does not claim that every user-configured IPTV endpoint
uses TLS: the app permits HTTP because some local/legacy services require it.
The privacy policy explicitly places that transport choice outside the
developer cloud service.

### Account deletion

- In app: **Sources → info icon → Delete cloud account**.
- Public web resource:
  `https://gchofficial.github.io/iptvs/delete-account.html`.
- Signed-in panel path: **Account → Delete cloud account**, then type `DELETE`.
- The deletion RPC removes the account, profiles, source/metadata credentials,
  favourites, pairings, and paired anonymous cloud identities immediately.
- It does not delete local data on disconnected devices; users can clear that
  by uninstalling the app or clearing its storage.
- A support request path remains necessary for users who cannot access their
  account.

Do not mark deletion complete until the Supabase migration is applied and the
end-to-end test has proved the deleted session cannot read data again.

## Android TV opt-in

The current AAB declares a Leanback launcher, a TV banner, and no touchscreen
requirement. Android TV was enabled in Play Console after having been tested
alongside Android phone and Windows throughout development.

The completed Console path was:

1. Open **Test and release → Advanced settings → Form factors**.
2. Choose **Add form factor → Android TV**.
3. Upload at least one Android TV screenshot to every active listing.
4. Ensure the description explicitly mentions **Android TV**.
5. Opt in and accept the Android TV review policy.
6. Use an internal TV release to verify install, launch, D-pad focus,
   Back behavior, text entry, playback controls, PiP behavior where applicable,
   and clean exit on a real TV device.

An emulator screenshot is acceptable listing evidence when it shows the real
app UI without cosmetic fabrication. Keep physical-TV testing in the release
checklist because an emulator does not reproduce every remote, decoder, HDR, or
device-lifecycle behaviour.

## New personal-account production gate

- [ ] Finish all App content and store-listing sections.
- [ ] Create a closed test.
- [ ] Recruit at least 12 testers who remain opted in continuously for 14 days.
- [ ] Collect actionable phone and TV feedback and record fixes.
- [ ] Apply for production access after the Console makes the application
  available.
- [ ] Complete production countries/regions and free-app pricing deliberately.
- [ ] Submit production only after policy pages, account deletion, screenshots,
  pre-launch report, and device smoke tests pass.

## Release smoke tests

### Android phone

- Clean install from Play; verify package name and Play signing certificate.
- Add Demo source; browse Live, Movies, and Series; start and stop playback.
- Exercise Back, rotation, background/resume, PiP, favourites, and Continue
  Watching.
- Pair cloud sync, push/pull a test profile, then unpair.
- Confirm there is no GitHub update UI or package-install permission.
- Confirm privacy/support/deletion links open.

### Android TV

- Install from the Play TV track, not by sideloading the direct APK.
- Complete every primary path using only D-pad, Select, and Back.
- Verify focus restoration after dialogs, search, playback, and route returns.
- Verify no keyboard/touchscreen requirement and no focus trap.
- Test native fullscreen controls, reconnect, subtitles/tracks, and app exit.

### Cloud account deletion

1. Create a disposable panel account and pair a disposable app installation.
2. Add one profile, every source kind with fake credentials, metadata settings,
   a favourite, and a device label.
3. Delete the account from the panel and confirm the session is signed out.
4. Confirm the same magic link no longer exposes the old rows.
5. Confirm the paired device can no longer pull or push.
6. Query the Supabase dashboard privately and confirm account-owned rows and
   paired anonymous auth users are gone.
7. Confirm an anonymous device cannot call `delete_account`, and Account A
   cannot delete or affect Account B.
