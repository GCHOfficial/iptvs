#!/usr/bin/env bash

set -euo pipefail
umask 077

for command in openssl base64; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command was not found." >&2
    exit 1
  fi
done

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

private_key="$signing_dir/iptvs-update-manifest-ed25519.pem"
if [ -e "$private_key" ]; then
  echo "Refusing to overwrite existing key: $private_key" >&2
  exit 1
fi

while true; do
  read -r -s -p 'New private-key password (16+ characters): ' password
  printf '\n'
  if [ "${#password}" -lt 16 ]; then
    echo "Use at least 16 characters."
    continue
  fi
  read -r -s -p 'Confirm private-key password: ' confirmation
  printf '\n'
  if [ "$password" != "$confirmation" ]; then
    echo "Passwords did not match."
    continue
  fi
  break
done
unset confirmation

export IPTVS_UPDATE_KEY_PASSWORD="$password"
openssl genpkey -algorithm ED25519 -aes-256-cbc \
  -pass env:IPTVS_UPDATE_KEY_PASSWORD -out "$private_key"
public_key=$(
  openssl pkey -in "$private_key" -passin env:IPTVS_UPDATE_KEY_PASSWORD \
    -pubout -outform DER |
    tail -c 32 |
    base64 -w0
)

echo
echo "Created update-manifest signing key: $private_key"
echo "Public verification key (Base64): $public_key"
echo
echo "Back up this private key in at least two encrypted offline locations."
echo "Do not commit the private key or a base64 copy."

printf 'Configure the GitHub release environment now? [y/N]: '
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

    gh api --method PUT "repos/$github_repository/environments/release" >/dev/null
    base64 < "$private_key" | tr -d '\r\n' |
      gh secret set UPDATE_MANIFEST_PRIVATE_KEY_BASE64 \
        --repo "$github_repository" --env release
    printf '%s' "$password" |
      gh secret set UPDATE_MANIFEST_PRIVATE_KEY_PASSWORD \
        --repo "$github_repository" --env release
    gh variable set UPDATE_MANIFEST_PUBLIC_KEY \
      --repo "$github_repository" --body "$public_key"

    echo "Configured the private signing key in the protected release environment."
    echo "Configured the public verification key as a repository variable."
    ;;
  *)
    echo "GitHub was not changed. Configure the values before the next release."
    ;;
esac

unset IPTVS_UPDATE_KEY_PASSWORD password
