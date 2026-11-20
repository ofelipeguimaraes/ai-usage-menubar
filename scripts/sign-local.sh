#!/bin/bash
# Signs the installed app with a stable local identity so macOS TCC grants
# (App Data / Files & Folders) survive rebuilds. Ad-hoc builds are identified
# by CDHash: every rebuild orphans the grant, and macOS 27 refuses to persist
# the per-browser switches for them (they flip back off).
#
# First run creates a dedicated keychain with a random password stored in
# ~/.config/aiusage-sign/keychain-pass (600). No login-keychain password and
# no interactive prompt are needed afterwards; scripts/install.sh re-signs
# automatically once that file exists.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(dirname "$script_directory")"
config_directory="$HOME/.config/aiusage-sign"
keychain="$config_directory/signing.keychain-db"
pass_file="$config_directory/keychain-pass"
identity="AI Usage Local Sign"
target="${1:-$HOME/Applications/AI Usage.app}"

mkdir -p "$config_directory"
chmod 700 "$config_directory"

if [[ ! -f "$config_directory/cert.pem" || ! -f "$config_directory/key.pem" ]]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "$config_directory/key.pem" -out "$config_directory/cert.pem" \
        -subj "/CN=$identity/" \
        -addext "extendedKeyUsage=codeSigning" \
        -addext "keyUsage=digitalSignature" 2>/dev/null
    chmod 600 "$config_directory/key.pem"
fi

if [[ ! -f "$pass_file" ]]; then
    openssl rand -hex 16 > "$pass_file"
    chmod 600 "$pass_file"
fi
password="$(cat "$pass_file")"

if [[ ! -f "$keychain" ]]; then
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings "$keychain"
    security import "$config_directory/cert.pem" -k "$keychain" -T /usr/bin/codesign
    security import "$config_directory/key.pem" -k "$keychain" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain"
fi

security unlock-keychain -p "$password" "$keychain"
codesign --force --deep --keychain "$keychain" --sign "$identity" \
    --entitlements "$repository_directory/AIUsage/local-release.entitlements" \
    "$target"
codesign -vv "$target"
printf 'Signed %s with %s\n' "$target" "$identity"
