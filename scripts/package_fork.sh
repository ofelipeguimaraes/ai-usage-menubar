#!/bin/bash
# Package an existing fork version without Sparkle or upstream signing keys.
set -euo pipefail
if [[ $# -ne 1 || ! "${1#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Usage: %s <existing-semver>\n' "$0" >&2
    exit 1
fi
version="${1#v}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(dirname "$script_directory")"
project_path="$repository_directory/AIUsage.xcodeproj"
configured_version="$(xcodebuild -project "$project_path" -scheme AIUsage -configuration Release -showBuildSettings | awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { if (!seen++) print $2 }')"
if [[ "$configured_version" != "$version" ]]; then
    printf 'Requested version %s differs from project version %s.\n' "$version" "$configured_version" >&2
    exit 1
fi
derived_data_directory="$repository_directory/DerivedData-Release"
artifact_directory="$repository_directory/dist/v$version"
built_application="$derived_data_directory/Build/Products/Release/AI Usage.app"
xcodebuild -project "$project_path" -scheme AIUsage -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived_data_directory" \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
/usr/bin/codesign --force --sign - "$built_application"
/usr/bin/codesign --verify --deep --strict "$built_application"
/usr/bin/lipo -verify_arch arm64 x86_64 "$built_application/Contents/MacOS/AI Usage"
mkdir -p "$artifact_directory"
staging_directory="$(mktemp -d)"
trap 'rm -rf "$staging_directory"' EXIT
/usr/bin/ditto "$built_application" "$staging_directory/AI Usage.app"
ln -s /Applications "$staging_directory/Applications"
/usr/bin/hdiutil create -volname 'AI Usage' -srcfolder "$staging_directory" -ov -format UDZO "$artifact_directory/AI-Usage.dmg"
(cd "$artifact_directory" && /usr/bin/shasum -a 256 AI-Usage.dmg > AI-Usage.dmg.sha256)
printf 'Packaged local fork build: %s/AI-Usage.dmg (ad-hoc signed, not notarized).\n' "$artifact_directory"
