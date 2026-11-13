#!/usr/bin/env bash
#
# Drive the TV-only Android flows over `adb` and fail on anything that looks
# like a crash.
#
# This is the owner's only way to exercise the D-pad/lifecycle paths that need
# a television: there is no Android TV box on hand, so the Android TV emulator
# on a KVM-accelerated Linux runner stands in for one
# (`.github/workflows/android-tv-emulator.yml`). It is deliberately runnable
# against *any* attached adb device as well — `--serial` picks one, `--apk`
# installs a build, everything else is the same.
#
# WHAT IT ACTUALLY VALIDATES
#   D-pad navigation, the first-run path to a playable catalogue, the live
#   preview → fullscreen handoff, the Back ladder out of the player, the live
#   latency "Go to live" chip and its focus hand-back, in-player zapping, and
#   process health across Home/relaunch and open/close cycles. Opt-in
#   (`--live-cut`): the Android "stitched handover" live splice against the
#   synthetic provider in `tool/live_cut_server.py` — see Scenario 4 below.
#
# WHAT IT CANNOT VALIDATE (see docs/validation-baseline.md)
#   An emulator has no hardware HEVC/DV decoders, no vendor codecs, no HDR
#   output path, no real memory pressure and no passthrough audio. Nothing
#   here says anything about decoder behaviour, dynamic-range signalling, or
#   the catch-up audibility checks.
#
# ASSERTION STRENGTH
#   Health checks (crash / ANR / native crash / process death / the app
#   reaching its channel list) always fail the run. The *behavioural* checks
#   additionally depend on the emulator reaching the public demo streams and
#   decoding them, which is outside this repo's control, so by default they
#   report loudly and set the exit status only under `--strict`
#   (IPTVS_TVEMU_STRICT=1). Flip the workflow to strict once a first green run
#   has shown the mechanisms work on the hosted runner.
#
# HOW IT KNOWS WHAT THE APP IS DOING
#   logcat, exclusively. The app already prints these lines in a debug build:
#     [iptvs.library] device class television=<bool>   (data/device_class.dart)
#     [iptvs.library] renderer=<impeller|skia-gl> reason=<why>
#                                                      (data/renderer_class.dart)
#     [iptvs.library] layout window=WxH dpr=.. wide=<bool> tv=<bool>
#     [iptvs.library] preview live source=.. channel=.. id=..
#     [iptvs.library] preview native engine open
#     [iptvs.player]  native live latency behind drift=..ms delay=..ms ..
#     [iptvs.player]  native live latency reset reason=golive drift=..ms ..
#     [iptvs.player]  zap play source=.. channel=.. id=..
#     iptvs.shared: fullscreen adopted the shared preview engine
#     iptvs.focus:  overlay focus=<control name>      (debug-only, Compose)
#     [iptvs.player] native live handover link=.. mechanism=splice|fallback ..
#                                                      (--live-cut only)
#     [iptvs.player] native live reconnect ..           (--live-cut only)
#   None of them carries a URL, header or credential.

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

PKG="com.gchofficial.iptvs.player.dev"      # development flavour, debug build
ACTIVITY="com.gchofficial.iptvs.MainActivity"
PLAYER_ACTIVITY="com.gchofficial.iptvs.HdrPlayerActivity"
SERIAL="${ANDROID_SERIAL:-}"
APK=""
OUT="${PWD}/tv-emulator-artifacts"
LABEL="${IPTVS_TVEMU_LABEL:-local}"
PAUSE_SECONDS="${IPTVS_TVEMU_PAUSE_SECONDS:-35}"
CYCLES="${IPTVS_TVEMU_CYCLES:-5}"
STRICT="${IPTVS_TVEMU_STRICT:-0}"
KEEP_INSTALLED=0
# Launch the app with the debug-only force-Skia-GL extra, and assert it took.
# Debug builds only by construction: `MainActivity.forceSkiaGlRequested` is
# gated on BuildConfig.DEBUG, so on a release APK this flag silently does
# nothing — which is exactly what the assertion below would then catch.
FORCE_SKIA_GL="${IPTVS_TVEMU_FORCE_SKIA_GL:-0}"
# Opt-in: drive the synthetic "live cut" channels (tool/live_cut_server.py)
# and assert on the Android stitched-handover splice. Needs an APK built with
# --dart-define=IPTVS_LIVE_CUT_URL=... (lib/sources/demo_source.dart) and the
# server already listening at that URL — neither is this script's job; see
# .github/workflows/android-tv-emulator.yml's live-cut job.
LIVE_CUT="${IPTVS_TVEMU_LIVE_CUT:-0}"
LIVE_CUT_SECONDS="${IPTVS_TVEMU_LIVE_CUT_SECONDS:-180}"
LIVE_CUT_STABLE_SECONDS="${IPTVS_TVEMU_LIVE_CUT_STABLE_SECONDS:-90}"

usage() {
  cat <<'EOF'
Usage: tool/android_tv_emulator_check.sh [options]

  --serial <id>        adb device serial (default: $ANDROID_SERIAL, else the
                       only attached device)
  --apk <path>         install this APK first (uninstalls any previous copy so
                       the first-run flow is reproducible)
  --package <id>       application id (default com.gchofficial.iptvs.player.dev)
  --out <dir>          artifact directory (logcat, screenshots, summary)
  --label <name>       artifact/summary label, e.g. "api28-google_apis"
  --cycles <n>         repeat count for the lifecycle loops (default 5)
  --pause-seconds <n>  how long to leave the player paused (default 35; must be
                       > 30 or the "Go to live" chip will not arm)
  --keep-installed     do not uninstall before installing (skips the first-run
                       flow; only useful for re-running against a warm device)
  --strict             make the behavioural checks fail the run too
  --force-skia-gl      launch with the debug-only renderer override so the
                       whole run exercises Flutter's Skia OpenGL renderer, and
                       assert the app reports it (debug builds only)
  --live-cut           also drive the synthetic "live cut" channels and
                       assert on the stitched-handover splice (needs an APK
                       built with --dart-define=IPTVS_LIVE_CUT_URL=... and
                       tool/live_cut_server.py already listening there)
  -h, --help           this text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --apk) APK="$2"; shift 2 ;;
    --package) PKG="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --cycles) CYCLES="$2"; shift 2 ;;
    --pause-seconds) PAUSE_SECONDS="$2"; shift 2 ;;
    --keep-installed) KEEP_INSTALLED=1; shift ;;
    --strict) STRICT=1; shift ;;
    --force-skia-gl) FORCE_SKIA_GL=1; shift ;;
    --live-cut) LIVE_CUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

ADB=(adb)
[ -n "$SERIAL" ] && ADB+=(-s "$SERIAL")

mkdir -p "$OUT"
LOG="$OUT/logcat.txt"
SUMMARY="$OUT/summary.md"
: >"$SUMMARY"

SHOT_N=0
FAILURES=0
SOFT_FAILURES=0

# ── Reporting ────────────────────────────────────────────────────────────────

note()  { printf '  %s\n' "$*"; }
step()  { printf '\n=== %s\n' "$*"; printf '\n### %s\n' "$*" >>"$SUMMARY"; }
pass()  { printf '  PASS  %s\n' "$*"; printf -- '- PASS %s\n' "$*" >>"$SUMMARY"; }

fail() {
  printf '  FAIL  %s\n' "$*" >&2
  printf -- '- **FAIL** %s\n' "$*" >>"$SUMMARY"
  FAILURES=$((FAILURES + 1))
}

# A check that depends on the emulator actually reaching and decoding the
# public demo streams. Reported either way; fatal only under --strict.
soft_fail() {
  if [ "$STRICT" = "1" ]; then
    fail "$*"
  else
    printf '  WARN  %s\n' "$*" >&2
    printf -- '- WARN (non-strict) %s\n' "$*" >>"$SUMMARY"
    SOFT_FAILURES=$((SOFT_FAILURES + 1))
  fi
}

# ── adb helpers ──────────────────────────────────────────────────────────────

shot() {
  SHOT_N=$((SHOT_N + 1))
  local name
  name=$(printf '%02d-%s.png' "$SHOT_N" "$1")
  "${ADB[@]}" exec-out screencap -p >"$OUT/$name" 2>/dev/null || true
}

key() {
  "${ADB[@]}" shell input keyevent "$1" >/dev/null 2>&1 || true
  sleep "${2:-0.6}"
}

# Empty when the app is not running. Never fails, so `set -e` cannot abort a
# run on a perfectly ordinary "not started yet".
app_pid() {
  "${ADB[@]}" shell pidof "$PKG" 2>/dev/null | tr -d '\r\n' | awk '{print $1}' || true
}

# The resumed component, across the two spellings Android has used for it.
top_component() {
  "${ADB[@]}" shell dumpsys activity activities 2>/dev/null \
    | grep -m1 -E 'mResumedActivity|ResumedActivity' || true
  "${ADB[@]}" shell dumpsys window 2>/dev/null | grep -m1 -E 'mCurrentFocus' || true
}

in_player() { top_component | grep -q "$PLAYER_ACTIVITY"; }

# ── logcat window helpers ────────────────────────────────────────────────────
#
# Everything is asserted against a byte offset into the captured logcat, so a
# check only ever sees output produced after the keypress it is about.

mark() { wc -c <"$LOG" 2>/dev/null | tr -d ' ' || echo 0; }

since() { tail -c "+$(( ${1} + 1 ))" "$LOG" 2>/dev/null || true; }

count_since() { since "$1" | grep -c -E -- "$2" || true; }

# wait_log <offset> <regex> <timeout-seconds>
wait_log() {
  local off="$1" re="$2" timeout="$3" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if since "$off" | grep -q -E -- "$re"; then return 0; fi
    sleep 0.5
  done
  return 1
}

first_match() { since "$1" | grep -m1 -E -- "$2" || true; }

# ── Crash detection ──────────────────────────────────────────────────────────

scan_health() {
  local off="$1" ctx="$2" allow_background_death="${3:-0}" w found=0
  # Spooled to a file rather than a shell variable: the teardown pass scans the
  # whole run, and a long emulator session produces tens of MB of logcat.
  w="$OUT/.window.$$"
  since "$off" >"$w"

  if grep -E -A6 'FATAL EXCEPTION' "$w" | grep -q "Process: ${PKG}"; then
    fail "$ctx: FATAL EXCEPTION in $PKG"
    grep -E -A20 'FATAL EXCEPTION' "$w" | head -40 >>"$OUT/crashes.txt" || true
    found=1
  fi
  if grep -q "ANR in ${PKG}" "$w"; then
    fail "$ctx: ANR in $PKG"
    grep -E -A20 "ANR in ${PKG}" "$w" | head -40 >>"$OUT/crashes.txt" || true
    # logcat carries the ANR's reason and load, not its thread stacks. A
    # bugreport includes /data/anr without root, so the main-thread stack
    # comes back with the failure. Once per run: it takes a minute.
    if [[ -z "${ANR_BUGREPORT_TAKEN:-}" ]]; then
      ANR_BUGREPORT_TAKEN=1
      timeout 180 "${ADB[@]}" bugreport "$OUT/anr-bugreport.zip" >/dev/null 2>&1 || true
    fi
    found=1
  fi
  # A tombstone names its process in the `>>> pkg <<<` header line; `Fatal
  # signal` alone could belong to any process on the device.
  if grep -q ">>> ${PKG} <<<" "$w"; then
    fail "$ctx: native crash (tombstone) in $PKG"
    grep -E -B4 -A30 ">>> ${PKG} <<<" "$w" | head -60 >>"$OUT/crashes.txt" || true
    found=1
  fi
  if grep -E -q "am_proc_died.*${PKG}|Process ${PKG}.*has died" "$w"; then
    # A process killed while *backgrounded* on a 2 GiB AVD is the low-memory
    # killer doing its job, not a defect, so the Home/relaunch window passes
    # `allow_background_death`. Anywhere else, a death with no crash log is
    # exactly the silent failure this job exists to catch.
    if [ "$allow_background_death" = "1" ]; then
      note "$ctx: app process died while backgrounded (LMK; expected on a small AVD)"
    else
      fail "$ctx: app process died"
      found=1
    fi
  fi
  rm -f "$w"
  return $found
}

# A pid that changed where it should not have is a process death the log may
# have described in words this script does not know. Absent is always fatal; a
# *changed* pid is reported as a behavioural miss, since a backgrounded kill
# and a silent crash look identical from here.
assert_same_pid() {
  local expected="$1" ctx="$2" now
  now=$(app_pid)
  if [ -z "$now" ]; then
    fail "$ctx: $PKG is not running any more"
    return 1
  fi
  if [ -n "$expected" ] && [ "$now" != "$expected" ]; then
    soft_fail "$ctx: app pid changed $expected -> $now (process restarted)"
    return 1
  fi
  return 0
}

# ── Device bring-up ──────────────────────────────────────────────────────────

step "Device"
"${ADB[@]}" wait-for-device
"${ADB[@]}" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
"${ADB[@]}" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
"${ADB[@]}" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
{
  echo '```'
  "${ADB[@]}" shell getprop ro.build.version.sdk
  "${ADB[@]}" shell getprop ro.build.characteristics
  "${ADB[@]}" shell getprop ro.product.model
  "${ADB[@]}" shell wm size
  "${ADB[@]}" shell wm density
  "${ADB[@]}" shell pm list features 2>/dev/null | grep -E 'leanback|type.television' || echo '(no leanback/television feature)'
  echo '```'
} >>"$SUMMARY" 2>&1 || true
note "device: API $("${ADB[@]}" shell getprop ro.build.version.sdk | tr -d '\r')"

if [ -n "$APK" ]; then
  step "Install"
  if [ "$KEEP_INSTALLED" = "0" ]; then
    # A clean slate is what makes the first-run key sequence below
    # deterministic: zero profiles, no configured source.
    "${ADB[@]}" uninstall "$PKG" >/dev/null 2>&1 || true
  fi
  "${ADB[@]}" install -r -g "$APK"
  pass "installed $(basename "$APK")"
fi

# Every buffer, not just `main`: `am_proc_died` / `am_anr` are event-log tags,
# and a tombstone is written to `crash`.
"${ADB[@]}" logcat -b all -G 16M >/dev/null 2>&1 || true
"${ADB[@]}" logcat -b all -c >/dev/null 2>&1 || "${ADB[@]}" logcat -c >/dev/null 2>&1 || true
"${ADB[@]}" logcat -b all -v time >"$LOG" 2>&1 &
LOGCAT_PID=$!
cleanup() {
  kill "$LOGCAT_PID" >/dev/null 2>&1 || true
  wait "$LOGCAT_PID" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

# ── Navigation primitives ────────────────────────────────────────────────────

# Every launch in the run carries the same extras, so the relaunch cycles stay
# on the renderer the run is about. The extra is read in
# `MainActivity.getFlutterShellArgs`, i.e. before the Flutter engine exists —
# but `FlutterLoader` is only initialised once per process, so it only has an
# effect on a launch that starts a *new* process. That is what the uninstall
# above and the Home/relaunch cycles' process checks already guarantee.
LAUNCH_EXTRAS=()
if [ "$FORCE_SKIA_GL" = "1" ]; then
  LAUNCH_EXTRAS=(--ez iptvsForceSkiaGl true)
fi

launch() {
  # `${a[@]+"${a[@]}"}`, not a bare `"${a[@]}"`: an empty array under `set -u`
  # is an unbound variable on bash before 4.4, and this script is meant to be
  # runnable against a local device too.
  "${ADB[@]}" shell am start -n "$PKG/$ACTIVITY" \
    ${LAUNCH_EXTRAS[@]+"${LAUNCH_EXTRAS[@]}"} >/dev/null 2>&1 || true
}

# The channel list is the only screen that prints `layout window=`, so that one
# line is both "we got there" and the geometry the layout decision was made
# from.
wait_for_channel_list() {
  local off="$1" timeout="${2:-60}"
  wait_log "$off" '\[iptvs\.library\] layout window=' "$timeout"
}

# Boot path on a fresh install: the profile picker ("Who's watching?") always
# appears because the install has zero profiles, and `auto` shows the picker
# for any count that is not exactly one. The "+" tile autofocuses; below the
# grid sit an optional "Link to cloud account" row and "Skip". Two Downs reach
# Skip from either layout (the second is a no-op when Skip is already the
# bottom row), so one sequence works configured or not.
skip_profile_picker() {
  key KEYCODE_DPAD_DOWN
  key KEYCODE_DPAD_DOWN
  key KEYCODE_DPAD_CENTER 1.5
}

# HomeShell's empty state: "Add a source" autofocuses, "Use demo streams" is
# directly below it. DemoSource needs no credentials and no provider, which is
# the whole reason the emulator can have a playable catalogue at all.
choose_demo_source() {
  key KEYCODE_DPAD_DOWN
  key KEYCODE_DPAD_CENTER 2
}

wait_until_player() {
  local timeout="$1" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if in_player; then return 0; fi
    sleep 1
  done
  return 1
}

# Get from the channel list into the fullscreen player.
#
# How many OK presses that takes depends on what the row is already doing, and
# both states occur in these loops: after a Home/relaunch the preview has been
# cleared (`lifecycle paused: preview stop`) so the first OK starts a preview
# and the second goes fullscreen, while returning from a previous fullscreen
# leaves the preview running on the same row, where the *first* OK already goes
# fullscreen (`decideChannelPlayAction`). Pressing a fixed number of times would
# either stall or land an extra OK on a focused player control.
open_fullscreen() {
  local off="$1"
  in_player && return 0
  key KEYCODE_DPAD_CENTER 1
  wait_until_player 6 && return 0
  wait_log "$off" '\[iptvs\.library\] preview live source=' 20 || true
  # Let the preview engine get a frame up before claiming its surface: this is
  # the handoff the job is here to exercise, not a race to be won.
  sleep 3
  in_player && return 0
  key KEYCODE_DPAD_CENTER 1.5
  wait_until_player 25
}

leave_player() {
  local _n
  for _n in 1 2 3 4; do
    in_player || return 0
    key KEYCODE_BACK 1
  done
  ! in_player
}

# Navigate the category sidebar to "Live cut test" (DemoSource adds it only
# when IPTVS_LIVE_CUT_URL was baked in) and apply it. Per docs/tv-navigation.md
# "Movement rules": Left peels the per-row favorite column back to the row
# body before a *second* Left actually crosses panes, so two Lefts cross
# whichever column the cursor was left on. Two Downs then reach the third
# category (index 2) — exact only from category index 0, which is where the
# sidebar cursor still sits here: nothing earlier in this script (Scenarios
# 1-3) ever touches the sidebar, only the channel pane. Applying the category
# (OK) lands on its first channel, "Live cut (rotating)" — channel number 201,
# listed before "Live cut (stable URL)" (202).
#
# Call this at most once per run. A second category re-navigation couldn't
# reuse this same fixed Down count without first knowing how many the
# previous call already consumed, so Scenario 4b deliberately does not call
# this again — it stays inside the category 4a already applied instead.
open_live_cut_category() {
  leave_player || true
  key KEYCODE_DPAD_LEFT
  key KEYCODE_DPAD_LEFT
  key KEYCODE_DPAD_DOWN
  key KEYCODE_DPAD_DOWN
  key KEYCODE_DPAD_CENTER 1
}

# ── Launch + first run ───────────────────────────────────────────────────────

step "Launch and reach the channel list"
M=$(mark)
launch
if ! wait_log "$M" '\[iptvs\.library\] device class television=' 90; then
  fail "the app never reported its device class (did it start?)"
  shot "launch-failed"
else
  DEVCLASS=$(first_match "$M" 'device class television=')
  pass "device class line: ${DEVCLASS##*] }"
fi
sleep 2
shot "profile-picker"

# Which Flutter renderer the engine started with, and why
# (`player/RendererPolicy.kt` -> `data/renderer_class.dart`). The line is
# printed by `addAndPrint`, so it only exists on a debug build — which this
# always is.
if wait_log "$M" '\[iptvs\.library\] renderer=' 30; then
  RENDERER=$(first_match "$M" '\[iptvs\.library\] renderer=')
  pass "renderer line: ${RENDERER##*] }"
  if [ "$FORCE_SKIA_GL" = "1" ]; then
    # A hard failure, not a soft one: this leg exists *only* to prove the
    # override works end to end. A run that silently fell back to Impeller
    # would otherwise report a green Skia GL leg that never ran Skia GL.
    if printf '%s' "$RENDERER" | grep -q 'renderer=skia-gl reason=forced-debug'; then
      pass "the debug renderer override took (Skia OpenGL)"
    else
      fail "--force-skia-gl was passed but the app reports: ${RENDERER##*] }"
    fi
  fi
elif [ "$FORCE_SKIA_GL" = "1" ]; then
  fail "the app never reported a renderer, so --force-skia-gl cannot be verified"
else
  note "no renderer line (an older build, or a non-Android target)"
fi

if ! wait_for_channel_list "$M" 10; then
  skip_profile_picker
  shot "after-skip"
  if ! wait_for_channel_list "$M" 10; then
    choose_demo_source
    shot "after-demo"
  fi
fi

if ! wait_for_channel_list "$M" 90; then
  fail "never reached the channel list (no 'layout window=' line)"
  shot "no-channel-list"
  scan_health "$M" "launch" || true
  echo "Collected: $OUT"
  exit 1
fi
LAYOUT=$(first_match "$M" 'layout window=')
pass "channel list reached: ${LAYOUT##*] }"
shot "channel-list"

# The TV flows only exist on the wide, two-pane layout — no category pane and
# no preview panel means no shared-engine preview path to test at all. Assert
# it rather than silently testing the handset layout.
if printf '%s' "$LAYOUT" | grep -q 'wide=true'; then
  pass "wide (two-pane) layout in use"
else
  fail "the app rendered the handset layout (wide=false) — the TV preview path is not reachable; give the AVD a TV screen profile"
fi
if printf '%s' "$LAYOUT" | grep -q 'tv=true'; then
  pass "isTelevision resolved true (real Android TV image)"
else
  note "isTelevision is false on this image — expected on a non-TV system image; the wide layout then comes from the window size"
fi
scan_health "$M" "launch" || true
BASE_PID=$(app_pid)

# ── Scenario 1a: OK starts a preview, then Home / relaunch ───────────────────

step "Scenario 1a: preview start, Home, relaunch (x$CYCLES)"
for i in $(seq 1 "$CYCLES"); do
  M=$(mark)
  # The channel list autofocuses with the cursor on row 0, so OK is the whole
  # gesture. Retry once: the catalogue may still be landing on the first pass.
  key KEYCODE_DPAD_CENTER 1
  if ! wait_log "$M" '\[iptvs\.library\] preview live source=' 25; then
    key KEYCODE_DPAD_CENTER 1
    if ! wait_log "$M" '\[iptvs\.library\] preview live source=' 25; then
      soft_fail "cycle $i: OK on a channel did not start a preview"
      shot "preview-$i-missing"
    fi
  fi
  if since "$M" | grep -q 'preview native engine open'; then
    note "cycle $i: native (shared) preview engine opened"
  fi
  shot "preview-$i"
  key KEYCODE_HOME 1.5
  scan_health "$M" "cycle $i (preview + Home)" 1 || true
  M2=$(mark)
  launch
  if ! wait_log "$M2" "ActivityManager|Displayed|${PKG}" 20; then
    note "cycle $i: no relaunch marker in logcat (harmless)"
  fi
  sleep 2
  assert_same_pid "$BASE_PID" "cycle $i (relaunch)" || BASE_PID=$(app_pid)
  scan_health "$M2" "cycle $i (relaunch)" 1 || true
done
pass "survived $CYCLES preview/Home/relaunch cycles"
shot "after-lifecycle-loop"

# ── Scenario 1b: preview -> fullscreen -> Back ───────────────────────────────

step "Scenario 1b: preview -> fullscreen -> Back (x$CYCLES)"
ADOPTIONS=0
for i in $(seq 1 "$CYCLES"); do
  M=$(mark)
  if open_fullscreen "$M"; then
    pass "cycle $i: fullscreen player opened"
  else
    soft_fail "cycle $i: fullscreen player never became the resumed activity"
    shot "fullscreen-$i-missing"
  fi
  # The invariant: a same-channel preview -> fullscreen must *adopt* the running
  # engine rather than open a second provider connection (CLAUDE.md "Player",
  # docs/player.md "Live preview + seamless handoff (Android)").
  if since "$M" | grep -q 'fullscreen adopted the shared preview engine'; then
    ADOPTIONS=$((ADOPTIONS + 1))
  fi
  shot "fullscreen-$i"
  if ! leave_player; then
    fail "cycle $i: four Back presses did not leave the player"
    shot "stuck-in-player-$i"
  fi
  sleep 1
  assert_same_pid "$BASE_PID" "cycle $i (fullscreen round trip)" || BASE_PID=$(app_pid)
  scan_health "$M" "cycle $i (fullscreen)" || true
done
if [ "$ADOPTIONS" -eq "$CYCLES" ]; then
  pass "shared-engine adoption on all $CYCLES handoffs"
else
  soft_fail "shared-engine adoption seen on $ADOPTIONS/$CYCLES handoffs (expected one per same-channel preview -> fullscreen)"
fi

# ── Scenario 2: live drift, the "Go to live" chip, and its focus hand-back ───

step "Scenario 2: pause ${PAUSE_SECONDS}s, resume, 'Go to live', focus lands on play/pause"
M=$(mark)
if ! open_fullscreen "$M"; then
  soft_fail "could not open the fullscreen player for the latency scenario"
else
  # The overlay opens with its chrome up (`controlsVisible` starts true) and
  # parks focus on play/pause, so no reveal press is needed — and must not be
  # sent, since OK on a *visible* control row activates whatever is focused.
  if wait_log "$M" 'overlay focus=Play/Pause' 10; then
    pass "player chrome up with focus on play/pause"
  else
    note "no overlay focus trace (release build?); continuing blind"
  fi
  shot "player-chrome"

  # The chrome auto-hides 4.5s after playback resumes, and with it hidden the
  # root key handler swallows the next press purely to reveal it again. Rather
  # than racing that, send the key and let the focus trace say which of the two
  # happened: a fresh `focus=Play/Pause` means the press was spent on the
  # reveal, so the pause still has to be sent.
  MP=$(mark)
  key KEYCODE_MEDIA_PLAY_PAUSE 1
  if since "$MP" | grep -q 'overlay focus=Play/Pause'; then
    note "that press only revealed the chrome; sending pause again"
    key KEYCODE_MEDIA_PLAY_PAUSE 1
  fi
  note "paused; holding ${PAUSE_SECONDS}s so drift passes the 30s threshold"
  sleep "$PAUSE_SECONDS"
  shot "player-paused"

  # Informational only, and read from the whole session rather than from the
  # pause: `logFor` prints this on the *first* crossing of LiveLatency.WARN_MS
  # and latches, and the demo channel is a VOD playlist served as live, so a
  # deep prefetched cushion can push `delay` past 30s before the pause even
  # starts. The chip itself latches on *drift*, which is what the two checks
  # below actually prove.
  if since "$M" | grep -q 'live latency behind'; then
    BEHIND=$(first_match "$M" 'live latency behind')
    note "live latency crossed the warn threshold: ${BEHIND##*] }"
  else
    note "no 'live latency behind' line yet"
  fi

  # Resume, then walk the control row immediately: every keypress re-arms the
  # auto-hide, so the row cannot vanish mid-walk, but a long wait between the
  # resume and the first arrow could let it — and a Right with the chrome down
  # is "previous channel", not a focus move.
  key KEYCODE_MEDIA_PLAY_PAUSE 1
  # Walk to the chip and press OK *at once*. The live chrome auto-hides 4.5 s
  # after the last key (PlayerControls HIDE_DELAY_LIVE). A screenshot between
  # focusing the chip and pressing OK took long enough on a slow emulator that
  # OK only re-revealed the chrome, whose default focus is play/pause, which
  # read as a passing focus hand-back with no go-live at all. So the
  # screenshot comes after the press, the go-live reload is what counts as the
  # press having happened, and the focus check is only meaningful after it.
  # One retry re-walks, since the first attempt may lose the race.
  MF=$(mark)
  FOUND_CHIP=0
  WENT_LIVE=0
  for attempt in 1 2; do
    MA=$(mark)
    for _ in $(seq 1 10); do
      key KEYCODE_DPAD_RIGHT 0.4
      if since "$MA" | grep -q 'overlay focus=Go to live'; then FOUND_CHIP=1; break; fi
    done
    [ "$FOUND_CHIP" = "1" ] || break
    MG=$(mark)
    key KEYCODE_DPAD_CENTER 0.2
    for _ in $(seq 1 20); do
      if since "$MG" | grep -q 'live latency reset reason=golive'; then WENT_LIVE=1; break; fi
      sleep 0.5
    done
    [ "$WENT_LIVE" = "1" ] && break
    note "go-live press $attempt did not reload (chrome probably hid first); re-walking"
  done
  shot "go-to-live"
  if [ "$FOUND_CHIP" != "1" ]; then
    soft_fail "'Go to live' never appeared/focused after a ${PAUSE_SECONDS}s pause"
    { echo "--- overlay focus trace while hunting the chip ---"; since "$MF" | grep 'overlay focus=' | tail -20; } >>"$OUT/crashes.txt" || true
  elif [ "$WENT_LIVE" != "1" ]; then
    pass "'Go to live' chip is present and focusable after the pause"
    soft_fail "pressing 'Go to live' never produced a go-live reload (2 attempts)"
  else
    pass "'Go to live' chip is present and focusable after the pause"
    RESET=$(first_match "$MG" 'live latency reset reason=golive')
    pass "go-live reload ran: ${RESET##*] }"
    DRIFT=$(printf '%s' "$RESET" | sed -n 's/.*drift=\([0-9]\{1,\}\)ms.*/\1/p')
    if [ -n "$DRIFT" ] && [ "$DRIFT" -ge 30000 ]; then
      pass "discarded drift was ${DRIFT}ms (>= the 30s threshold that armed the chip)"
    else
      soft_fail "go-live discarded drift=${DRIFT:-unknown}ms, expected >= 30000"
    fi
    # Only now does a play/pause focus line prove the hand-back rather than a
    # chrome reveal.
    if since "$MG" | grep -q 'overlay focus=Play/Pause'; then
      pass "focus landed on play/pause after activating 'Go to live'"
    else
      fail "'Go to live' reloaded but focus did not land on play/pause (D-pad stranding regression)"
      { echo "--- overlay focus trace after go-live ---"; since "$MG" | grep 'overlay focus=' | head -10; } >>"$OUT/crashes.txt" || true
    fi
  fi
  scan_health "$M" "latency scenario" || true
fi

# ── Scenario 3: in-player channel up/down ────────────────────────────────────

step "Scenario 3: channel up/down"
if ! in_player; then
  soft_fail "not in the player; skipping the zap scenario"
else
  M=$(mark)
  # CHANNEL_UP/CHANNEL_DOWN are unambiguous on every remote, so ZapKeyPolicy
  # claims them whatever the chrome is doing. Up then down keeps the cursor
  # between the two live demo channels (the catalogue's later rows are VOD,
  # where zapping is deliberately inert).
  for pair in 1 2; do
    key KEYCODE_CHANNEL_UP 2.5      # past the 600ms zap settle
    key KEYCODE_CHANNEL_DOWN 2.5
    note "zap pair $pair sent"
  done
  sleep 2
  shot "after-zap"
  ZAPS=$(count_since "$M" '\[iptvs\.player\] zap play ')
  if [ "$ZAPS" -ge 2 ]; then
    pass "$ZAPS settled zaps played"
  else
    soft_fail "only $ZAPS 'zap play' lines after four channel keys"
  fi
  scan_health "$M" "zap scenario" || true
fi

# ── Scenario 4: live-cut stitched handover (opt-in, --live-cut) ─────────────
#
# Needs an APK built with --dart-define=IPTVS_LIVE_CUT_URL=... and
# tool/live_cut_server.py already reachable there — neither is this script's
# job (see .github/workflows/android-tv-emulator.yml). Two parts: the
# rotating-URL channel, where the stitched handover should *splice* across
# every server-side cut with no visible reconnect; then the stable-URL
# control, which proves the splice never arms for a source whose URL never
# changes, even though the server still cuts its connection the same way.
if [ "$LIVE_CUT" = "1" ]; then
  step "Scenario 4a: live-cut splice (rotating URL, ${LIVE_CUT_SECONDS}s)"
  M=$(mark)
  open_live_cut_category
  if open_fullscreen "$M"; then
    pass "live-cut (rotating) fullscreen player opened"
    note "playing ${LIVE_CUT_SECONDS}s, watching for stitched handovers"
    sleep "$LIVE_CUT_SECONDS"
    shot "live-cut-rotating"

    WINDOW="$OUT/.live_cut_rotating_window"
    since "$M" >"$WINDOW"
    SPLICES=$(grep -c -E '\[iptvs\.player\] native live handover .*mechanism=splice' "$WINDOW" || true)
    if [ "$SPLICES" -ge 3 ]; then
      pass "$SPLICES splice handovers observed in ${LIVE_CUT_SECONDS}s"
    else
      soft_fail "only $SPLICES splice handovers observed in ${LIVE_CUT_SECONDS}s (expected >= 3)"
    fi

    BAD_REPEATED=$(grep -E '\[iptvs\.player\] native live handover' "$WINDOW" | grep -vc -E 'repeatedMs=0( |$)' || true)
    if [ "$BAD_REPEATED" -eq 0 ]; then
      pass "every handover line has repeatedMs=0"
    else
      soft_fail "$BAD_REPEATED handover line(s) have a nonzero repeatedMs"
    fi

    # Reconnect fallbacks are expected *before* the mechanism proves itself
    # out (no splice candidate yet, e.g. the very first cut), but once a
    # splice has been observed a later reconnect means the splice gave up and
    # fell back, which is the regression this run exists to catch.
    FIRST_SPLICE_LINE=$(grep -n -m1 -E 'mechanism=splice' "$WINDOW" | cut -d: -f1 || true)
    if [ -n "$FIRST_SPLICE_LINE" ]; then
      RECONNECTS_AFTER=$(tail -n "+$((FIRST_SPLICE_LINE + 1))" "$WINDOW" | grep -c -E '\[iptvs\.player\] native live reconnect ' || true)
      if [ "$RECONNECTS_AFTER" -eq 0 ]; then
        pass "no reconnect fallback after the first splice"
      else
        soft_fail "$RECONNECTS_AFTER 'native live reconnect' line(s) after the first splice (expected 0)"
      fi
    else
      note "no splice line to measure post-splice reconnects against"
    fi
    rm -f "$WINDOW"
  else
    soft_fail "could not open the fullscreen player for the live-cut (rotating) scenario"
  fi
  scan_health "$M" "live-cut rotating scenario" || true

  step "Scenario 4b: live-cut control (stable URL, ${LIVE_CUT_STABLE_SECONDS}s, must never splice)"
  M=$(mark)
  # No sidebar re-navigation here: 4a already applied "Live cut test" and
  # left the channel-pane cursor on its first row ("Live cut (rotating)"),
  # exactly as every other fullscreen round trip in this script assumes
  # Back restores the same category/row it came from (Scenario 1b above).
  # Re-deriving the category index here would have to know how many Downs
  # 4a already consumed from an unknown starting index — one Down within
  # the still-selected category's channel list is both simpler and exact.
  leave_player || true
  key KEYCODE_DPAD_DOWN     # from "Live cut (rotating)" to "Live cut (stable URL)"
  if open_fullscreen "$M"; then
    pass "live-cut (stable URL) fullscreen player opened"
    sleep "$LIVE_CUT_STABLE_SECONDS"
    shot "live-cut-stable"

    STABLE_SPLICES=$(count_since "$M" '\[iptvs\.player\] native live handover .*mechanism=splice')
    STABLE_RECONNECTS=$(count_since "$M" '\[iptvs\.player\] native live reconnect ')
    if [ "$STABLE_SPLICES" -eq 0 ]; then
      pass "no splice handovers for the stable-URL control"
    else
      soft_fail "$STABLE_SPLICES splice handover(s) armed for a source whose URL never changes (stable-URL control)"
    fi
    if [ "$STABLE_RECONNECTS" -ge 1 ]; then
      pass "$STABLE_RECONNECTS reconnect(s) observed for the stable-URL control (proves the cut itself still happened)"
    else
      soft_fail "no reconnect observed for the stable-URL control in ${LIVE_CUT_STABLE_SECONDS}s (expected the server's close to trigger one)"
    fi
  else
    soft_fail "could not open the fullscreen player for the live-cut (stable URL) control"
  fi
  scan_health "$M" "live-cut stable control scenario" || true
fi

# ── Teardown ─────────────────────────────────────────────────────────────────

step "Teardown"
leave_player || note "still in the player after four Back presses"
shot "final"
sleep 2
scan_health 0 "whole run" || true
assert_same_pid "$BASE_PID" "end of run" || true

# The in-memory diagnostics log is not a file, so there is nothing to pull for
# it; the app's data directory is still worth having on a debug build.
"${ADB[@]}" shell "run-as $PKG ls -R . 2>/dev/null | head -200" >"$OUT/app-data-listing.txt" 2>&1 || true
"${ADB[@]}" shell dumpsys meminfo "$PKG" >"$OUT/meminfo.txt" 2>&1 || true

{
  echo
  echo "### Result ($LABEL)"
  echo
  echo "- hard failures: $FAILURES"
  echo "- non-strict warnings: $SOFT_FAILURES"
} >>"$SUMMARY"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$SUMMARY" >>"$GITHUB_STEP_SUMMARY"
fi

printf '\nArtifacts: %s\n' "$OUT"
printf 'Hard failures: %s   Warnings: %s\n' "$FAILURES" "$SOFT_FAILURES"
[ "$FAILURES" -eq 0 ] || exit 1
exit 0
