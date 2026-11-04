#!/usr/bin/env bash
#
# Proves what the Sentry CI token can actually do, instead of assuming it.
# Runs the two real release steps (release registration, Flutter engine
# symbols), then reads back from the API whether the release and the debug
# files really exist. Prints HTTP statuses and counts only, never the token or
# a response body that could carry one.
#
# Usage: tool/sentry_pipeline_check.sh <version>   (e.g. 0.1.76)
# Env:   SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT, SENTRY_URL
#
# Unlike the release steps, this one exits non-zero when something does not
# work: it is a check, and its job is to be red when the pipeline would
# silently degrade.

set -uo pipefail
version="${1:?version}"
: "${SENTRY_AUTH_TOKEN:?}" "${SENTRY_ORG:?}" "${SENTRY_PROJECT:?}" "${SENTRY_URL:?}"
base="${SENTRY_URL%/}"
release="iptvs@${version}"
fail=0

api() { # method path -> prints HTTP status; body to $tmp
  curl -sS -o "$tmp" -w '%{http_code}' -X "$1" "${base}/api/0/$2" \
    -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" --max-time 60 2>/dev/null || echo 000
}
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

echo "== 1. release registration (the real release step)"
./tool/sentry_register_release.sh "$version"

echo "== 2. engine symbols (the real release step)"
./tool/sentry_upload_engine_symbols.sh

echo "== 3. read-back"
st=$(api GET "organizations/${SENTRY_ORG}/releases/${release}/")
echo "release ${release}: HTTP ${st}"
[ "$st" = 200 ] || { echo "::error::release ${release} is not readable/present (HTTP ${st})"; fail=1; }

st=$(api GET "projects/${SENTRY_ORG}/${SENTRY_PROJECT}/files/dsyms/?per_page=100")
if [ "$st" = 200 ]; then
  n=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d)); [print(" ", x.get("objectName"), x.get("cpuName"), x.get("symbolType")) for x in d if "flutter" in (x.get("objectName") or "")]' "$tmp")
  echo "debug files listed: $n"
  printf '%s\n' "$n" | head -1 | grep -qv '^0$' || { echo "::error::no debug files present after upload"; fail=1; }
else
  echo "::error::cannot list debug files (HTTP ${st})"; fail=1
fi
exit $fail
