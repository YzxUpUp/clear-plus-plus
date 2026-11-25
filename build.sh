#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h}"
build_dir="$PWD/.build"
output="$PWD/dist/Clear++.app"
staging="$(mktemp -d "${TMPDIR:-/tmp}/clear-build.XXXXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
app="$staging/Clear++.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_dir" "$PWD/dist"

host_arch="$(uname -m)"
case "${1:-}" in
    "") architectures=("$host_arch") ;;
    --universal) architectures=(arm64 x86_64) ;;
    *) printf '用法\n  %s [--universal]\n' "$0" >&2; exit 2 ;;
esac

binaries=()
for architecture in "${architectures[@]}"; do
    binary="$staging/Clear-$architecture"
    xcrun swiftc -O -target "${architecture}-apple-macosx14.0" Sources/*.swift -o "$binary"
    binaries+=("$binary")
done
xcrun lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Clear"
cp Info.plist "$app/Contents/Info.plist"
xcrun swift -target "${host_arch}-apple-macosx14.0" scripts/MakeIcon.swift "$staging"
iconutil -c icns "$staging/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto "$app" "$output"
printf '%s\n' "$output"
