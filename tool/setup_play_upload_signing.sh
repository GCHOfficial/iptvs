#!/usr/bin/env bash

set -euo pipefail
umask 077

if ! command -v keytool >/dev/null 2>&1; then
  echo "keytool was not found. Install/use the JDK configured for Android builds." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
default_dir="${XDG_DATA_HOME:-$HOME/.local/share}/iptvs/signing"

printf 'Signing directory [%s]: ' "$default_dir"
read -r signing_dir
signing_dir=${signing_dir:-$default_dir}
mkdir -p "$signing_dir"
signing_dir=$(cd "$signing_dir" && pwd -P)

case "$signing_dir/" in
  "$repo_root/"*)
    echo "Refusing to create a private key inside the repository." >&2
    exit 1
    ;;
esac

keystore="$signing_dir/iptvs-google-play-upload.p12"
if [ -e "$keystore" ]; then
  echo "Refusing to overwrite existing keystore: $keystore" >&2
  exit 1
fi

printf 'Key alias [iptvs-play-upload]: '
read -r key_alias
key_alias=${key_alias:-iptvs-play-upload}

default_certificate_dn='CN=IPTVS Player Play Upload, O=George-Cosmin Hanta, C=RO'
printf 'Certificate distinguished name [%s]: ' "$default_certificate_dn"
read -r certificate_dn
certificate_dn=${certificate_dn:-$default_certificate_dn}

while true; do
  read -r -s -p 'New upload-keystore password (16+ characters): ' password
  printf '\n'
  if [ "${#password}" -lt 16 ]; then
    echo "Use at least 16 characters."
    continue
  fi
  read -r -s -p 'Confirm upload-keystore password: ' confirmation
  printf '\n'
  if [ "$password" != "$confirmation" ]; then
    echo "Passwords did not match."
    continue
  fi
  break
done
unset confirmation

export IPTVS_PLAY_UPLOAD_PASSWORD="$password"
keytool -genkeypair -v \
  -keystore "$keystore" \
  -storetype PKCS12 \
  -storepass:env IPTVS_PLAY_UPLOAD_PASSWORD \
  -keypass:env IPTVS_PLAY_UPLOAD_PASSWORD \
  -alias "$key_alias" \
  -dname "$certificate_dn" \
  -keyalg RSA \
  -keysize 4096 \
  -sigalg SHA384withRSA \
  -validity 10000

fingerprint=$(
  keytool -list -v \
    -keystore "$keystore" \
    -storepass:env IPTVS_PLAY_UPLOAD_PASSWORD \
    -alias "$key_alias" |
    sed -n 's/^[[:space:]]*SHA256: //p' |
    head -n 1
)

if [ -z "$fingerprint" ]; then
  echo "Key was created, but its SHA-256 fingerprint could not be read." >&2
  exit 1
fi

certificate="$signing_dir/iptvs-google-play-upload-certificate.pem"
keytool -exportcert -rfc \
  -keystore "$keystore" \
  -storepass:env IPTVS_PLAY_UPLOAD_PASSWORD \
  -alias "$key_alias" \
  -file "$certificate" >/dev/null
unset IPTVS_PLAY_UPLOAD_PASSWORD

echo
echo "Created Google Play upload key: $keystore"
echo "Exported public upload certificate: $certificate"
echo "Alias: $key_alias"
echo "Upload certificate SHA-256: $fingerprint"
echo
echo "Back up the keystore and password in at least two encrypted offline locations."
echo "The PEM certificate is public and is the file Play Console may ask you to upload."
echo "Do not commit either file; keeping both outside the repository avoids mistakes."

printf 'Configure the GitHub google-play environment now? [y/N]: '
read -r configure_github
case "$configure_github" in
  y|Y|yes|YES)
    if ! command -v gh >/dev/null 2>&1; then
      echo "gh was not found; configure the GitHub values manually." >&2
      exit 1
    fi
    gh auth status >/dev/null
    printf 'GitHub repository [GCHOfficial/iptvs]: '
    read -r github_repository
    github_repository=${github_repository:-GCHOfficial/iptvs}

    gh api --method PUT "repos/$github_repository/environments/google-play" >/dev/null
    base64 < "$keystore" | tr -d '\r\n' |
      gh secret set PLAY_UPLOAD_KEYSTORE_BASE64 \
        --repo "$github_repository" --env google-play
    printf '%s' "$password" |
      gh secret set PLAY_UPLOAD_KEYSTORE_PASSWORD \
        --repo "$github_repository" --env google-play
    printf '%s' "$key_alias" |
      gh secret set PLAY_UPLOAD_KEY_ALIAS \
        --repo "$github_repository" --env google-play
    printf '%s' "$password" |
      gh secret set PLAY_UPLOAD_KEY_PASSWORD \
        --repo "$github_repository" --env google-play
    gh variable set PLAY_UPLOAD_CERT_SHA256 \
      --repo "$github_repository" --env google-play --body "$fingerprint"

    echo "Configured upload signing in the GitHub google-play environment."
    echo "Open Settings > Environments > google-play and add protection rules."
    ;;
  *)
    echo "GitHub was not changed. Follow docs/store-publishing.md when ready."
    ;;
esac

unset password
