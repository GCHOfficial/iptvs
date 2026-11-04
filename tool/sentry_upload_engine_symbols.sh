#!/usr/bin/env bash
#
# Uploads the Flutter engine's own debug symbols for the engine revision this
# build used, so native frames inside `libflutter.so` (Impeller, Skia's text
# layout, the Dart VM) arrive in Sentry symbolicated rather than as raw
# addresses. Those are the frames the Play-vitals crash clusters were made of
# (e.g. the TCL G10's scudo aborts under ParagraphImpl::~ParagraphImpl).
#
# Google publishes them per engine revision and ABI:
#   https://storage.googleapis.com/flutter_infra_release/flutter/<rev>/android-<abi>-release/symbols.zip
# There are no equivalent archives for windows-x64 or linux-x64 at the current
# revision, so desktop engine frames stay unsymbolicated (docs/updates.md).
#
# Usage: tool/sentry_upload_engine_symbols.sh
#
# Environment (all optional; any missing one makes this a no-op):
#   SENTRY_AUTH_TOKEN  repo secret, via `env:` only
#   SENTRY_ORG / SENTRY_PROJECT / SENTRY_URL  repo variables
#
# **Never fails a release:** every path exits 0, problems become warnings.

set -uo pipefail

: "${SENTRY_AUTH_TOKEN:=}"
: "${SENTRY_ORG:=}"
: "${SENTRY_PROJECT:=}"
: "${SENTRY_URL:=https://sentry.io/}"

if [ -z "$SENTRY_AUTH_TOKEN" ] || [ -z "$SENTRY_ORG" ] || [ -z "$SENTRY_PROJECT" ]; then
  echo "Sentry engine-symbol upload is not configured; skipping."
  exit 0
fi

rev=$(flutter --version --machine 2>/dev/null | sed -n 's/.*"engineRevision"[^"]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
if [ -z "$rev" ]; then
  echo "::warning::Could not determine the Flutter engine revision; skipping engine-symbol upload."
  exit 0
fi
echo "Flutter engine revision: $rev"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
found=0
for abi in android-arm android-arm64 android-x64; do
  url="https://storage.googleapis.com/flutter_infra_release/flutter/${rev}/${abi}-release/symbols.zip"
  if curl -sSfL --max-time 300 -o "$work/${abi}.zip" "$url"; then
    mkdir -p "$work/$abi" && unzip -q -o "$work/${abi}.zip" -d "$work/$abi" && found=1
  else
    echo "::warning::No engine symbols at ${abi}-release for ${rev}."
  fi
done
if [ "$found" = 0 ]; then
  echo "::warning::No Flutter engine symbols downloaded; skipping upload."
  exit 0
fi

# Pinned sentry-cli (released 2026-09-16), run through npx so no new Action
# needs pinning. `--wait` is deliberately not used: processing happens
# server-side and must not hold the release job.
if ! SENTRY_URL="$SENTRY_URL" npx -y @sentry/cli@3.8.0 debug-files upload \
    --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$work"; then
  echo "::warning::Sentry engine-symbol upload failed; the release continues."
fi
exit 0
