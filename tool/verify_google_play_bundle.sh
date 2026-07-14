#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <app-bundle.aab> <merged-manifest.xml>" >&2
  exit 2
fi

bundle=$1
manifest=$2
expected_fingerprint=${EXPECTED_CERT_SHA256:-}

for file in "$bundle" "$manifest"; do
  if [ ! -f "$file" ]; then
    echo "Required build output was not found: $file" >&2
    exit 1
  fi
done
if [ -z "$expected_fingerprint" ]; then
  echo "EXPECTED_CERT_SHA256 is not configured." >&2
  exit 1
fi

unzip -tq "$bundle" >/dev/null
jarsigner -verify "$bundle" >/dev/null

package_name=$(
  sed -n 's/^[[:space:]]*package="\([^"]*\)".*/\1/p' "$manifest" |
    head -n 1
)
if [ "$package_name" != 'com.gchofficial.iptvs.player' ]; then
  echo "Google Play package mismatch: expected com.gchofficial.iptvs.player, received ${package_name:-none}." >&2
  exit 1
fi
if grep -q 'android.permission.REQUEST_INSTALL_PACKAGES' "$manifest"; then
  echo "Google Play manifest contains REQUEST_INSTALL_PACKAGES." >&2
  exit 1
fi
if grep -q 'androidx.core.content.FileProvider' "$manifest"; then
  echo "Google Play manifest contains the GitHub updater FileProvider." >&2
  exit 1
fi

actual_fingerprint=$(
  keytool -printcert -jarfile "$bundle" |
    sed -n 's/^[[:space:]]*SHA256: //p' |
    head -n 1
)
normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]'
}
actual_normalized=$(normalize_fingerprint "$actual_fingerprint")
expected_normalized=$(normalize_fingerprint "$expected_fingerprint")
if [ -z "$actual_normalized" ] || [ "$actual_normalized" != "$expected_normalized" ]; then
  echo "Google Play upload certificate mismatch. Expected $expected_normalized, received ${actual_normalized:-none}." >&2
  exit 1
fi

echo "Verified Google Play AAB package, updater policy, archive signature, and upload certificate."
