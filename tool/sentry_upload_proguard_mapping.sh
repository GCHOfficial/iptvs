#!/usr/bin/env bash
#
# Uploads this build's R8 mapping file to Sentry under the UUID that was
# compiled into the APK/AAB manifest, so Kotlin/Java frames arrive
# deobfuscated instead of as `f5.run(r8-map-id-…:73)`.
#
# Flutter's Gradle plugin shrinks *and obfuscates* every `--release` build, and
# nothing else uploads a mapping: Play gets one from the AAB, Sentry does not.
# The two halves have to agree on one identifier, and the mapping file does not
# exist yet when the manifest is merged, so CI generates the UUID, passes it to
# Gradle as `IPTVS_SENTRY_PROGUARD_UUID` (written to the manifest as
# `io.sentry.proguard-uuid`, read by sentry-java's `ManifestMetadataReader` and
# attached to every event as the `proguard` debug image), and hands the same
# value to this script afterwards.
#
# This is deliberately **not** the Sentry Gradle plugin, which is banned
# (CLAUDE.md): it instruments bytecode, turning `android.util.Log` into
# breadcrumbs and auto-instrumenting HTTP, and our provider URLs carry
# credentials.
#
# Usage: tool/sentry_upload_proguard_mapping.sh <mapping.txt> <uuid>
#   e.g. tool/sentry_upload_proguard_mapping.sh \
#          build/app/outputs/mapping/githubDirectRelease/mapping.txt "$IPTVS_SENTRY_PROGUARD_UUID"
#
# Environment (all optional; any missing one makes this a no-op):
#   SENTRY_AUTH_TOKEN  environment secret (release / google-play), via `env:`
#                      only — never interpolated into a `run:` block
#   SENTRY_ORG / SENTRY_PROJECT / SENTRY_URL  repo variables
#
# **Never fails a release:** every path exits 0, problems become warnings. A
# failed upload costs that build's Kotlin/Java deobfuscation (Sentry does not
# reprocess events it has already handled), which is not a reason to withhold a
# release. Dart frames, engine frames and Play's own vitals are unaffected.

set -uo pipefail

mapping="${1:-}"
uuid="${2:-}"

: "${SENTRY_AUTH_TOKEN:=}"
: "${SENTRY_ORG:=}"
: "${SENTRY_PROJECT:=}"
: "${SENTRY_URL:=https://sentry.io/}"

if [ -z "$SENTRY_AUTH_TOKEN" ] || [ -z "$SENTRY_ORG" ] || [ -z "$SENTRY_PROJECT" ]; then
  echo "Sentry mapping upload is not configured; skipping."
  exit 0
fi

if [ -z "$uuid" ]; then
  echo "::warning::No R8 mapping UUID given; this build's Kotlin/Java frames will stay obfuscated."
  exit 0
fi
if ! printf '%s' "$uuid" | grep -Eq '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'; then
  # The manifest half would have failed the build on this, so reaching here
  # means the two halves were given different things.
  echo "::warning::R8 mapping UUID is not a UUID; skipping upload."
  exit 0
fi

if [ -z "$mapping" ] || [ ! -s "$mapping" ]; then
  # A wrong variant path is the silent-degradation case this guard exists for:
  # it would otherwise be discovered months later, by an unreadable crash. One
  # unambiguous mapping.txt under the Gradle output tree is still this build's.
  echo "::warning::No mapping file at '${mapping}'; looking for one under build/app/outputs/mapping/."
  found=$(find build/app/outputs/mapping -name mapping.txt -size +0 2>/dev/null)
  if [ "$(printf '%s\n' "$found" | grep -c .)" = 1 ]; then
    mapping="$found"
    echo "::warning::Using ${mapping} instead; fix the path in the workflow."
  else
    echo "::warning::No single mapping file found; this build's Kotlin/Java frames will stay obfuscated."
    exit 0
  fi
fi

# Pinned sentry-cli (released 2026-09-16), run through npx so no new Action
# needs pinning — the same arrangement as the engine-symbol upload beside it.
#
# `--uuid` is **hidden from `--help`** in 3.8.0 but present and honoured
# (verified against this exact pin: `--no-upload --write-properties` writes
# back the UUID given here rather than the content-derived one). It is what the
# Sentry Gradle plugin itself passes. The pin is what keeps that safe; re-check
# the flag before moving it.
#
# `--require-one` turns "nothing was uploaded" into a non-zero exit, so an
# empty or unreadable mapping becomes a visible warning instead of a green step
# that uploaded nothing.
echo "Uploading ${mapping} as ${uuid}"
if ! SENTRY_URL="$SENTRY_URL" npx -y @sentry/cli@3.8.0 upload-proguard \
    --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    --uuid "$uuid" --require-one "$mapping"; then
  echo "::warning::Sentry R8 mapping upload failed; the release continues (its Kotlin/Java frames stay obfuscated)."
fi
exit 0
