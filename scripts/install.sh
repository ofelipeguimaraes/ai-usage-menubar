#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(dirname "$script_directory")"
# The .noindex suffix keeps the build product out of Spotlight, so only the
# installed copy shows up there.
derived_data_directory="$repository_directory/DerivedData-Install.noindex"
install_directory="${AI_USAGE_INSTALL_DIR:-${HOME}/Applications}"
built_application="$derived_data_directory/Build/Products/Release/AI Usage.app"
installed_application="$install_directory/AI Usage.app"

if ! command -v xcodebuild >/dev/null 2>&1; then
    printf 'AI Usage requires Xcode 27 or newer.\n' >&2
    exit 1
fi

printf 'Building AI Usage…\n'
xcodebuild \
    -quiet \
    -project "$repository_directory/AIUsage.xcodeproj" \
    -scheme AIUsage \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data_directory" \
    ENABLE_HARDENED_RUNTIME=NO \
    build

mkdir -p "$install_directory"
# ditto merges: drop leftovers (e.g. an interrupted codesign's .cstemp) that
# would otherwise invalidate the fresh signature.
if [[ -d "$installed_application" ]]; then
    /bin/rm -rf "$installed_application"
fi
/usr/bin/ditto "$built_application" "$installed_application"

# Stable local identity keeps TCC grants alive across rebuilds (macOS 27
# flips the App Data switches back off for ad-hoc/CDHash-churning builds).
if [[ -f "$HOME/.config/aiusage-sign/keychain-pass" ]]; then
    bash "$script_directory/sign-local.sh" "$installed_application"
fi

if [[ "${AI_USAGE_SKIP_OPEN:-0}" != "1" ]]; then
    open "$installed_application"
fi

printf 'Installed AI Usage at %s\n' "$installed_application"
