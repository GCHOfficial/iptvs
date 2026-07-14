#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <apk> <development|githubDirect|googlePlay>" >&2
  exit 2
fi

apk=$1
channel=$2
if [ ! -f "$apk" ]; then
  echo "APK not found: $apk" >&2
  exit 1
fi
if [ -z "${ANDROID_HOME:-}" ]; then
  echo "ANDROID_HOME is not configured." >&2
  exit 1
fi
aapt=$(find "$ANDROID_HOME/build-tools" -type f -name aapt -print | sort -V | tail -n 1)
if [ -z "$aapt" ]; then
  echo "aapt was not found in the Android SDK." >&2
  exit 1
fi

permissions=$($aapt dump permissions "$apk")
manifest=$($aapt dump xmltree "$apk" AndroidManifest.xml)
badging=$($aapt dump badging "$apk")
package_name=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "$badging" | head -n 1)
has_install_permission=false
has_update_provider=false
if grep -q 'android.permission.REQUEST_INSTALL_PACKAGES' <<< "$permissions"; then
  has_install_permission=true
fi
if grep -q 'androidx.core.content.FileProvider' <<< "$manifest"; then
  has_update_provider=true
fi

case "$channel" in
  githubDirect)
    expected_package='com.gchofficial.iptvs.player.direct'
    if [ "$has_install_permission" != true ] || [ "$has_update_provider" != true ]; then
      echo "GitHub-direct APK is missing its user-driven updater manifest entries." >&2
      exit 1
    fi
    ;;
  development|googlePlay)
    if [ "$channel" = development ]; then
      expected_package='com.gchofficial.iptvs.player.dev'
    else
      expected_package='com.gchofficial.iptvs.player'
    fi
    if [ "$has_install_permission" = true ] || [ "$has_update_provider" = true ]; then
      echo "$channel APK contains GitHub self-updater manifest entries." >&2
      exit 1
    fi
    ;;
  *)
    echo "Unknown Android distribution channel: $channel" >&2
    exit 2
    ;;
esac

if [ "$package_name" != "$expected_package" ]; then
  echo "$channel APK package mismatch: expected $expected_package, received ${package_name:-none}." >&2
  exit 1
fi

echo "Verified Android manifest policy and package identity for $channel."
