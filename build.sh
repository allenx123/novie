#!/bin/zsh
# Builds build/Novie.app: the Swift desktop app plus the VM payload (the Alpine Linux + XFCE
# disk image) and a bundled copy of Homebrew's QEMU.
#   usage: ./build.sh [--force-image]
# The guest image is built once by guest/build_image.sh and cached in guest/image/; pass
# --force-image to build it again even when nothing it depends on has changed.
set -euo pipefail
here="${0:a:h}"
build="$here/build"
app="$build/Novie.app"
image="$here/guest/image/alpine-xfce-aarch64.qcow2"

for tool in qemu-system-aarch64 qemu-img; do
  command -v $tool >/dev/null || { echo "missing $tool: brew install qemu"; exit 1; }
done

force=()
case "${1:-}" in
  "") ;;
  --force-image) force=(--force) ;;
  *) echo "unknown option: $1 (usage: ./build.sh [--force-image])"; exit 1 ;;
esac

echo "==> guest image"
"$here/guest/build_image.sh" "${force[@]}"
[[ -f "$image" ]] || { echo "guest image not found: $image"; exit 1; }

echo "==> app"
# Plain swiftc: no build-system state to go wrong; app/Package.swift is there for Xcode
bin="$build/NovieMCP"
swiftc -O -target arm64-apple-macos26.0 -o "$bin" "$here"/app/src/*.swift

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$here/bundle/Info.plist" "$app/Contents/Info.plist"
cp "$here/bundle/Novie.icns" "$app/Contents/Resources/"
cp "$bin" "$app/Contents/MacOS/NovieMCP"
# APFS clone: no extra disk space for the guest image, which the VM only ever reads
cp -c "$image" "$app/Contents/Resources/" 2>/dev/null || cp "$image" "$app/Contents/Resources/"
echo "==> qemu"
# Homebrew's QEMU + its libraries + firmware, so users don't need QEMU installed
"$here/bundle_qemu.sh" "$app"
codesign --force --sign - "$app"
# Signing the bundle must not have taken the hypervisor entitlement off the nested QEMU,
# which is the one thing -accel hvf cannot do without
codesign -d --entitlements - "$app/Contents/MacOS/qemu-system-aarch64" 2>/dev/null \
  | grep -q 'com.apple.security.hypervisor' || {
  echo "the bundled qemu-system-aarch64 has no hypervisor entitlement; the VM could not use hvf"
  exit 1
}
echo "built: $app"
