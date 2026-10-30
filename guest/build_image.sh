#!/bin/zsh
# Builds the guest payload: a qcow2 disk with Alpine Linux and XFCE installed on it, which
# the app boots read-only behind a throwaway overlay (see VMManager). The install runs in a
# throwaway QEMU VM driven over its serial console by provision.py.
#
# The result is cached in guest/image/ and only rebuilt when the ISO, provision.sh or the
# overlay change, because it takes several minutes and downloads most of a desktop.
#   usage: build_image.sh [--force]
set -euo pipefail
here="${0:a:h}"
version=3.24
mirror=https://dl-cdn.alpinelinux.org/alpine
iso="$here/iso/alpine-virt-3.24.3-aarch64.iso"
out="$here/image/alpine-xfce-aarch64.qcow2"
stamp="$here/image/alpine-xfce-aarch64.stamp"
work="$here/image/work"
force=${1:-}

qemu=${QEMU_PATH:-$(command -v qemu-system-aarch64)}
qemu_img=${qemu:h}/qemu-img
for tool in "$qemu" "$qemu_img" bsdtar python3; do
  command -v "$tool" >/dev/null || { echo "missing $tool: brew install qemu"; exit 1; }
done

"$here/fetch_iso.sh"

# Anything that changes what ends up in the image: rebuild when any of it changes
recipe=$(shasum -a 256 "$here/provision.sh" "$here/provision.py" $(find "$here/overlay" -type f | sort) \
         | shasum -a 256 | cut -d' ' -f1)
recipe="$recipe ${iso:t} $version"
if [[ -z "$force" && -f "$out" && -f "$stamp" ]] && [[ "$(<"$stamp")" == "$recipe" ]]; then
  echo "guest image up to date: $out"
  exit 0
fi

echo "==> building the guest image (several minutes: it installs a desktop from $mirror)"
rm -rf "$work"
mkdir -p "$work" "${out:h}"
bsdtar -xf "$iso" -C "$work" boot/vmlinuz-virt boot/initramfs-virt

# What provision.sh reads; everything else it needs is in the repo and goes in the tarball
cat > "$work/config.env" <<EOF
ALPINE_VERSION=$version
ALPINE_MIRROR=$mirror
TARGET_DISK=/dev/vda
EOF
cp "$here/provision.sh" "$work/provision.sh"
cp -R "$here/overlay" "$work/overlay"
# The guest reads this out of QEMU's fw_cfg device: no network service and no filesystem
# image to build on macOS just to hand a few files over
# --uid/--gid 0: the overlay is copied straight into the guest's root filesystem, and
# without this everything in it arrives owned by whichever Mac user ran the build
tar czf "$work/seed.tar.gz" --uid 0 --gid 0 -C "$work" config.env provision.sh overlay

rm -f "$out.tmp" "$stamp"
"$qemu_img" create -f qcow2 "$out.tmp" 8G >/dev/null
python3 -I "$here/provision.py" \
  --qemu "$qemu" --iso "$iso" \
  --kernel "$work/boot/vmlinuz-virt" --initramfs "$work/boot/initramfs-virt" \
  --disk "$out.tmp" --seed "$work/seed.tar.gz" --log "$here/image/provision.log"

# Rewrite the image so the clusters freed during the install don't ship with the app
echo "==> compacting"
"$qemu_img" convert -O qcow2 "$out.tmp" "$out.new"
mv "$out.new" "$out"
rm -f "$out.tmp"
rm -rf "$work"
print -r -- "$recipe" > "$stamp"
echo "guest image: $out ($(du -h "$out" | cut -f1))"
