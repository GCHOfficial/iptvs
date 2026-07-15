#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <apk> <expected-sha256>" >&2
  exit 2
fi

apk=$1
expected_fingerprint=$2

if [ ! -f "$apk" ]; then
  echo "APK was not found: $apk" >&2
  exit 1
fi
if [ -z "${ANDROID_HOME:-}" ]; then
  echo "ANDROID_HOME is not configured." >&2
  exit 1
fi

apksigner=$(find "$ANDROID_HOME/build-tools" -type f -name apksigner -print | sort -V | tail -n 1)
if [ -z "$apksigner" ]; then
  echo "apksigner was not found in the Android SDK." >&2
  exit 1
fi

# Android build-tools has used both `Signer #1 certificate...` and
# `V2 Signer: certificate...`. Match the stable digest label, not its prefix.
certificate_output=$("$apksigner" verify --verbose --print-certs "$apk")
actual_fingerprint=$(
  printf '%s\n' "$certificate_output" |
    awk -F 'digest:[[:space:]]*' '/certificate SHA-256 digest:/ { print $2; exit }'
)

normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]'
}

actual=$(normalize_fingerprint "$actual_fingerprint")
expected=$(normalize_fingerprint "$expected_fingerprint")
if [ -z "$actual" ] || [ "$actual" != "$expected" ]; then
  echo "Android signing certificate mismatch. Expected $expected, received ${actual:-none}." >&2
  printf '%s\n' "$certificate_output" >&2
  exit 1
fi

echo "Verified Android release certificate SHA-256: $actual"
