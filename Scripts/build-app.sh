#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path="$project_root/.build/Lector MD.app"
contents_path="$app_path/Contents"

swift build --package-path "$project_root" --configuration release

/bin/rm -rf "$app_path"
/bin/mkdir -p "$contents_path/MacOS"
/bin/cp "$project_root/.build/release/LectorMD" "$contents_path/MacOS/LectorMD"
/bin/cp "$project_root/Resources/Info.plist" "$contents_path/Info.plist"
/usr/bin/printf 'APPL????' > "$contents_path/PkgInfo"
/usr/bin/codesign --force --deep --sign - "$app_path"

printf '%s\n' "$app_path"
