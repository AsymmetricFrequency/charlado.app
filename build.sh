#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/Charlado.app"
destination="${1:-$HOME/Applications/Charlado.app}"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_dir/Charlado.iconset" "$(dirname "$destination")"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
MACOSX_DEPLOYMENT_TARGET=26.0 swiftc -swift-version 5 -O "$source_dir/main.swift" "$source_dir/Appearance.swift" "$source_dir/Features.swift" "$source_dir/MeetingMCP.swift" "$source_dir/CallAudio.swift" "$source_dir/MeetingDraft.swift" \
    -o "$app/Contents/MacOS/Charlado"
"$app/Contents/MacOS/Charlado" --check
"$app/Contents/MacOS/Charlado" --iconset "$build_dir/Charlado.iconset"
iconutil -c icns "$build_dir/Charlado.iconset" -o "$app/Contents/Resources/Charlado.icns"
codesign --force --sign "${CHARLADO_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
ditto "$app" "$destination"
printf '%s\n' "$destination"
