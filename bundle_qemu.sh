#!/bin/zsh
# Copies Homebrew's QEMU into an app bundle so users don't need to install QEMU:
#   Contents/MacOS/qemu-system-aarch64  the hypervisor
#   Contents/MacOS/qemu-img             creates the disk overlay the guest writes to
#   Contents/Frameworks/*.dylib         every non-system library they load (recursively)
#   Contents/Resources/qemu/            the firmware/keymap files our VM config loads (with -L)
# Library references are rewritten to @loader_path and everything is ad-hoc re-signed.
# qemu-system-aarch64 keeps its com.apple.security.hypervisor entitlement, without which
# -accel hvf cannot open Hypervisor.framework and the VM falls back to nothing at all.
# Homebrew's bottles target the macOS they were built for, so the bundle needs that macOS or later.
#   usage: ./bundle_qemu.sh "path/to/App.app"
set -euo pipefail
app="${1:?usage: bundle_qemu.sh path/to/App.app}"
qemu_src="${QEMU_PATH:-$(command -v qemu-system-aarch64)}"
qemu_src="${qemu_src:A}"
qemu_img_src="${qemu_src:h}/qemu-img"
share="$(brew --prefix qemu)/share/qemu"
macos="$app/Contents/MacOS"
fw="$app/Contents/Frameworks"
roms="$app/Contents/Resources/qemu"
# What our VM (virt + UEFI, virtio-gpu, virtio-net, usb-kbd/tablet) loads at startup.
# edk2-aarch64-code.fd is the firmware the VM boots; keymaps/en-us is what turns the keysyms
# in VNC key events into scancodes, and -vnc will not even start without it.
# efi-virtio.rom is the NIC's PXE option ROM: QEMU loads it when it creates
# virtio-net-pci and refuses to start without it, even though nothing ever boots from it.
rom_files=(edk2-aarch64-code.fd efi-virtio.rom keymaps/en-us)

mkdir -p "$macos" "$fw" "$roms/keymaps"
qemu="$macos/qemu-system-aarch64"
qemu_img="$macos/qemu-img"
cp "$qemu_src" "$qemu"
cp "$qemu_img_src" "$qemu_img"
chmod u+w "$qemu" "$qemu_img"

# Resolves a load command path (absolute, @loader_path or @rpath) as seen from $2's original location
resolve() {
  local ref=$1 from=$2 dir=${2:h} rp p
  case $ref in
    @loader_path/*|@executable_path/*) p="$dir/${ref#*/}" ;;
    @rpath/*)
      for rp in $(otool -l "$from" | awk '/LC_RPATH/{getline; getline; print $2}'); do
        p="${rp/@loader_path/$dir}/${ref#@rpath/}"
        [[ -f $p ]] && break
      done ;;
    *) p=$ref ;;
  esac
  [[ -f $p ]] || { echo "can't resolve $ref from $from" >&2; return 1; }
  echo ${p:A}
}

# install_name_tool, minus its expected "will invalidate the code signature" warning
int() { xcrun install_name_tool "$@" 2> >(grep -v 'invalidate the code signature' >&2); }

# Non-system libraries $1 links against, one "<load command path> <resolved file>" per line
deps() {
  local f=$1 id ref
  id=$(otool -D "$f" | tail -n +2)
  otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r ref; do
    [[ $ref == /usr/lib/* || $ref == /System/* || $ref == "$id" ]] && continue
    echo "$ref $(resolve "$ref" "$f")"
  done
}

# Breadth-first copy of the dependency tree. orig[name] remembers where each copy came from,
# since @rpath/@loader_path in a library resolve relative to its original location.
typeset -A orig
queue=("$qemu:$qemu_src" "$qemu_img:$qemu_img_src")
while (( ${#queue} )); do
  item=${queue[1]}; queue=("${queue[@]:1}")
  file=${item%%:*} src=${item#*:}
  if [[ $file == "$macos"/* ]]; then prefix="@loader_path/../Frameworks"; else prefix="@loader_path"; fi
  deps "$src" | while read -r ref real; do
    name=${real:t}
    if [[ -z ${orig[$name]:-} ]]; then
      orig[$name]=$real
      cp "$real" "$fw/$name"
      chmod u+w "$fw/$name"
      int -id "@executable_path/../Frameworks/$name" "$fw/$name"
      queue+=("$fw/$name:$real")
    fi
    int -change "$ref" "$prefix/$name" "$file"
  done
done

# Anything still pointing into Homebrew would only work on machines that have it installed
for f in "$qemu" "$qemu_img" "$fw"/*.dylib; do
  if otool -L "$f" | tail -n +2 | grep -q '/opt/homebrew\|/usr/local/\|@rpath'; then
    echo "unbundled reference left in $f:"; otool -L "$f"; exit 1
  fi
done

for r in $rom_files; do cp "$share/$r" "$roms/$r"; done

# install_name_tool invalidates signatures; libraries first, then the binaries.
# --preserve-metadata=entitlements is what keeps qemu-system-aarch64's hypervisor
# entitlement: re-signing without it leaves a binary that cannot use -accel hvf.
codesign --force --sign - "$fw"/*.dylib 2> >(grep -v 'replacing existing signature' >&2)
for f in "$qemu" "$qemu_img"; do
  codesign --force --sign - --preserve-metadata=entitlements "$f" 2> >(grep -v 'replacing existing signature' >&2)
done
codesign -d --entitlements - "$qemu" 2>/dev/null | grep -q 'com.apple.security.hypervisor' || {
  echo "$qemu lost its hypervisor entitlement: the VM would not be able to use hvf"; exit 1
}
echo "bundled QEMU: $(ls "$fw" | wc -l | tr -d ' ') libraries, $(du -sh "$fw" | cut -f1) + $(du -ch "$qemu" "$qemu_img" | tail -1 | cut -f1) binaries"
