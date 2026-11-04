#!/usr/bin/env bash
#
# Proves what the Sentry CI token can actually do, instead of assuming it.
# Runs the three real release steps (release registration, Flutter engine
# symbols, the R8 mapping upload), then reads back from the API whether the
# release and the debug files really exist. Prints HTTP statuses and counts
# only, never the token or a response body that could carry one.
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

echo "== 0. token identity and scopes (names only, never the token)"
st=$(api GET "")
if [ "$st" != 200 ]; then
  # /api/0/ is served by Sentry's control silo, so a regional host (de.sentry.io)
  # answers 404; ask the control silo instead (same vendor, same token).
  echo "API root on ${base}: HTTP ${st}; asking https://sentry.io"
  st=$(curl -sS -o "$tmp" -w '%{http_code}' "https://sentry.io/api/0/" \
    -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" --max-time 60 2>/dev/null || echo 000)
fi
if [ "$st" = 200 ]; then
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); a=d.get("auth") or {}; u=d.get("user") or {}; print("token kind:", "user" if u else "organization/unknown"); print("scopes:", " ".join(sorted(a.get("scopes") or [])) or "(not reported)")' "$tmp"
else
  echo "API root: HTTP ${st}"
fi

echo "== 1. release registration (the real release step)"
./tool/sentry_register_release.sh "$version"

echo "== 2. engine symbols (the real release step)"
out=$(./tool/sentry_upload_engine_symbols.sh 2>&1); echo "$out"
ids=$(printf '%s\n' "$out" | sed -n 's/.*UPLOADED \([0-9a-f-]\{36\}\).*/\1/p; s/.*OK \([0-9a-f-]\{36\}\).*/\1/p' | sort -u)

echo "== 3. read-back"
st=$(api GET "organizations/${SENTRY_ORG}/releases/${release}/")
echo "release ${release}: HTTP ${st}"
[ "$st" = 200 ] || { echo "::error::release ${release} is not readable/present (HTTP ${st})"; fail=1; }

# Debug files are assembled and processed asynchronously after upload, so a
# listing taken at once can be empty. Look each one up by its debug id and
# give processing a few minutes.
# Also look up the engine symbols already uploaded for this engine revision
# (2026-11-04), so a run that uploads nothing still tests read access.
ids="$ids ${KNOWN_DEBUG_IDS:-}"
ids=$(printf '%s\n' $ids | sort -u)
if [ -z "$ids" ]; then
  echo "(no new uploads this run; relying on the re-upload check below)"
fi
for id in $ids; do
  seen=0
  for _ in $(seq 1 18); do
    st=$(api GET "projects/${SENTRY_ORG}/${SENTRY_PROJECT}/files/dsyms/?debug_id=${id}")
    if [ "$st" = 200 ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) else 1)' "$tmp"; then seen=1; break; fi
    sleep 10
  done
  echo "debug file ${id}: listed=${seen} (last HTTP ${st})"
done

# Decisive regardless of what the listing endpoint shows this token: the
# upload asks the server which files it is missing, so a second run that
# uploads nothing means the server already holds all of them.
echo "== 4. re-upload (expect nothing missing)"
out2=$(./tool/sentry_upload_engine_symbols.sh 2>&1); echo "$out2"
if printf '%s\n' "$out2" | grep -q 'UPLOADED '; then
  echo "::error::second upload still uploaded files: the server did not keep the first upload"; fail=1
else
  echo "server already holds the engine symbols (nothing re-uploaded)"
fi

# The R8 mapping upload needs a different scope from the debug-file upload
# above, and a release-time failure is invisible (the script warns and exits
# 0), so prove it here with a synthetic two-line mapping under a throwaway
# UUID. That does leave ~70 bytes of junk mapping in the project per run, which
# is the price of knowing the real upload works before a release depends on it.
# **"No warning" is not proof here.** Sentry dedupes debug files by checksum,
# so an upload of bytes it already holds answers "Nothing to upload" and
# attaches the asserted UUID to nothing -- silently, and with a zero exit. Two
# consecutive runs of this script caught exactly that before the release script
# learned to stamp each copy with its own UUID. So this step demands both
# halves: the CLI must say it UPLOADED *this* uuid, and the server must then
# hand it back by debug id.
echo "== 5. R8 mapping upload (the real release step, synthetic mapping)"
probe_dir=$(mktemp -d); trap 'rm -f "$tmp"; rm -rf "$probe_dir"' EXIT
probe_uuid=$(python3 -I -c 'import uuid; print(uuid.uuid4())')
printf 'com.gchofficial.iptvs.PipelineCheck -> a:\n    1:1:void probe() -> a\n' \
  > "$probe_dir/mapping.txt"
out3=$(./tool/sentry_upload_proguard_mapping.sh "$probe_dir/mapping.txt" "$probe_uuid" 2>&1)
echo "$out3"
if printf '%s\n' "$out3" | grep -q '::warning::'; then
  echo "::error::the R8 mapping upload would not work at release time"; fail=1
elif ! printf '%s\n' "$out3" | grep -q "UPLOADED ${probe_uuid}"; then
  echo "::error::sentry-cli did not report uploading ${probe_uuid}; the mapping is not attached to it"
  fail=1
else
  seen=0
  for _ in $(seq 1 18); do
    st=$(api GET "projects/${SENTRY_ORG}/${SENTRY_PROJECT}/files/dsyms/?debug_id=${probe_uuid}")
    if [ "$st" = 200 ] && python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) else 1)' "$tmp"; then seen=1; break; fi
    sleep 10
  done
  echo "mapping ${probe_uuid}: listed=${seen} (last HTTP ${st})"
  if [ "$seen" != 1 ]; then
    echo "::error::the uploaded mapping is not readable back under ${probe_uuid}"; fail=1
  fi
fi

exit $fail
