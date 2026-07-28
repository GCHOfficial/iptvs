# Android release verification

Per-release smoke tests for `com.gchofficial.iptvs.player` (Play) and
`com.gchofficial.iptvs.player.direct` (GitHub direct). Run these against a real
build before promoting it — an emulator does not reproduce every remote, decoder,
HDR, or device-lifecycle behaviour, which is why physical-TV testing stays on the
list rather than being assumed.

Copy the list per release; the boxes are a template, not a record.

> **Console state lives elsewhere.** Submitted listing copy, App content answers,
> Data safety declarations, the asset inventory, the Android TV opt-in record and
> the production-access gate are one publisher account's audit trail, so they are
> kept in a gitignored `docs/private/google-play-submission-record.md` rather than
> in the repo. Re-audit the Data safety answers there before shipping anything
> that changes what the cloud service stores.

## Android phone

- [ ] Clean install; verify package name and the expected signing certificate
  (Play-managed for Play, the direct-distribution cert for GitHub direct).
- [ ] Add the Demo source; browse Live, Movies, and Series; start and stop
  playback.
- [ ] Exercise Back, rotation, background/resume, PiP, favourites, and Continue
  Watching.
- [ ] Pair cloud sync, push/pull a test profile, then unpair.
- [ ] Play build only: confirm there is no GitHub update UI and no
  package-install permission. This is a policy requirement, not a preference —
  Play prohibits `REQUEST_INSTALL_PACKAGES` for self-updates, and the
  `googlePlay` flavor omits it at build time.
- [ ] Confirm privacy, support, and account-deletion links open.

## Android TV

- [ ] Install from the Play TV track, not by sideloading the direct APK.
- [ ] Complete every primary path using only D-pad, Select, and Back.
- [ ] Verify focus restoration after dialogs, search, playback, and route
  returns.
- [ ] Verify no keyboard/touchscreen requirement and no focus trap.
- [ ] Test native fullscreen controls, reconnect, subtitles/tracks, and app exit.

## Cloud account deletion

Only needs re-running when the cloud schema changes what an account owns — but
then it must be re-run, because the claim on the Play listing and the privacy
policy is that deletion is complete.

1. [ ] Create a disposable panel account and pair a disposable app installation.
2. [ ] Add one profile, every source kind with fake credentials, metadata
   settings, a favourite, and a device label. Enable end-to-end encryption so the
   secret tables are populated too.
3. [ ] Delete the account from the panel and confirm the session is signed out.
4. [ ] Confirm the same magic link no longer exposes the old rows.
5. [ ] Confirm the paired device can no longer pull or push.
6. [ ] Query the database privately and confirm account-owned rows and paired
   anonymous auth users are gone.
7. [ ] Confirm an anonymous device cannot call `delete_account`, and that
   account A cannot delete or affect account B.

### Deletion coverage (verified 2026-07-25)

The E2EE work added five tables that can hold credential or key material, so the
"deletion is complete" claim now depends on more than the original owner
cascades. Current coverage:

| Table | Removed by |
|---|---|
| `source_secrets` | `owner → auth.users` cascade |
| `metadata_secrets` | `owner → auth.users` cascade |
| `profile_crypto` | `owner → auth.users` cascade |
| `device_ck` | cascades twice — via `devices.device_uid` *and* `profiles.id`, both of which cascade from `auth.users` |
| `push_rate` | explicit `delete` in `delete_account` (no owner column) |

`device_ck` and `push_rate` have no direct `auth.users` foreign key, so neither is
covered by the obvious "owner cascade" reasoning — check this table, not the
assumption, if the schema grows another secret-bearing table.
