#!/usr/bin/env bash
# TEMPORARY (Flutter 3.50.1 PR): proves, from the engine's own logcat, which
# renderer a release-mode APK started. Reverted with the workflow that runs it.
#   usage: renderer_release_proof.sh <apk> <control|soc|forced> <outdir>
set -u
APK=$1; MODE=$2; OUT=$3
PKG=com.gchofficial.iptvs.player.dev
mkdir -p "$OUT"
adb install -r "$APK" || exit 1
SOC=$(adb shell getprop ro.soc.model | tr -d '\r')
echo "mode=$MODE ro.soc.model='$SOC'" | tee "$OUT/summary.txt"
if [ "$MODE" = soc ] && [ "$SOC" != RTD2875P ]; then
  echo "::warning::soc leg UNPROVEN: the emulator did not take ro.soc.model=RTD2875P (got '$SOC')" | tee -a "$OUT/summary.txt"
  exit 0
fi
adb logcat -c
EXTRAS=()
[ "$MODE" = forced ] && EXTRAS=(--ez iptvsForceSkiaGl true)
adb shell am start -W -n "$PKG/com.gchofficial.iptvs.MainActivity" "${EXTRAS[@]}"
sleep 30
adb logcat -d > "$OUT/logcat.txt"
IMP=$(grep -c 'Using the Impeller rendering backend' "$OUT/logcat.txt")
OPT=$(grep -c 'Impeller opt-out deprecated' "$OUT/logcat.txt")
grep -E 'Impeller rendering backend|Impeller opt-out|FATAL|AndroidRuntime' "$OUT/logcat.txt" | head -20 | tee -a "$OUT/summary.txt"
echo "impeller_lines=$IMP optout_lines=$OPT" | tee -a "$OUT/summary.txt"
if [ "$MODE" = control ]; then
  [ "$IMP" -gt 0 ] && [ "$OPT" -eq 0 ] && { echo "PASS control: engine started Impeller"; exit 0; }
else
  [ "$OPT" -gt 0 ] && [ "$IMP" -eq 0 ] && { echo "PASS $MODE: engine honoured --enable-impeller=false"; exit 0; }
fi
echo "::error::$MODE leg failed (impeller_lines=$IMP optout_lines=$OPT)"; exit 1
