#!/usr/bin/env bash
#
# Registers one app version as a Sentry release, so the dashboard can group
# issues by release and show "first seen in".
#
# Usage: tool/sentry_register_release.sh <version>      # e.g. 0.1.74
#
# Environment (all optional; a missing one makes this a no-op):
#   SENTRY_AUTH_TOKEN  environment secret (release / google-play /
#                      microsoft-store), passed through `env:` and never
#                      interpolated into a `run:` block
#   SENTRY_ORG         organisation slug
#   SENTRY_PROJECT     project slug
#   SENTRY_URL         region host, e.g. https://de.sentry.io/
#
# **This script must never fail a release.** Sentry being down, a rotated
# token, or a fork with no secrets configured are all reasons to ship anyway,
# so every path exits 0 and failures are surfaced as workflow warnings. The
# release object is a convenience: Sentry creates one implicitly from the first
# event that carries the tag, so skipping this costs commit association, not
# crash reporting.
#
# Our own debug info isn't uploaded (no `--split-debug-info`, so Dart frames
# keep their names; our native libraries are third-party and stripped). The
# Flutter **engine's** symbols are uploaded separately by
# tool/sentry_upload_engine_symbols.sh. See docs/updates.md "Crash reporting
# (Sentry)".

set -uo pipefail

version="${1:-}"
if [ -z "$version" ]; then
  echo "::warning::sentry_register_release.sh: no version given; skipping."
  exit 0
fi

: "${SENTRY_AUTH_TOKEN:=}"
: "${SENTRY_ORG:=}"
: "${SENTRY_PROJECT:=}"
: "${SENTRY_URL:=https://sentry.io/}"

if [ -z "$SENTRY_AUTH_TOKEN" ] || [ -z "$SENTRY_ORG" ] || [ -z "$SENTRY_PROJECT" ]; then
  echo "Sentry release registration is not configured; skipping."
  exit 0
fi

base="${SENTRY_URL%/}"
release="iptvs@${version}"

# `curl --fail` would hide the body; capture the status instead so a warning
# can say what happened without echoing the token.
status=$(
  curl -sS -o /tmp/sentry-release.json -w '%{http_code}' \
    -X POST "${base}/api/0/organizations/${SENTRY_ORG}/releases/" \
    -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
    -H 'Content-Type: application/json' \
    --max-time 60 \
    -d "{\"version\":\"${release}\",\"projects\":[\"${SENTRY_PROJECT}\"]}" \
    2>/dev/null
) || status=000

case "$status" in
  200|201|208)
    echo "Sentry release ${release} registered (HTTP ${status})."
    ;;
  400)
    # Sentry answers 400 for "release already exists", which a re-run of the
    # release workflow hits every time. Not a problem.
    echo "Sentry release ${release} already exists."
    ;;
  *)
    echo "::warning::Could not register Sentry release ${release} (HTTP ${status}). Shipping anyway."
    exit 0
    ;;
esac

status=$(
  curl -sS -o /dev/null -w '%{http_code}' \
    -X PUT "${base}/api/0/organizations/${SENTRY_ORG}/releases/${release}/" \
    -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
    -H 'Content-Type: application/json' \
    --max-time 60 \
    -d "{\"dateReleased\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    2>/dev/null
) || status=000

if [ "$status" != "200" ]; then
  echo "::warning::Could not finalize Sentry release ${release} (HTTP ${status})."
fi
exit 0
