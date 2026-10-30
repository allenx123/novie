#!/bin/zsh
# Downloads the Alpine Linux aarch64 ISO into guest/iso/ and checks it against the
# published SHA-256. The ISO is only used by guest/build_image.sh, which installs Alpine
# onto the disk image the app actually boots; it is not shipped in the app bundle.
#   usage: guest/fetch_iso.sh
set -euo pipefail
here="${0:a:h}"
name=alpine-virt-3.24.3-aarch64.iso
url="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/$name"
sha256=e34603080e942e9ebc670689eee77dd7a6551c823a6ff5a299e308ded268098f
dest="$here/iso/$name"

mkdir -p "$here/iso"
if [[ -f "$dest" ]] && echo "$sha256  $dest" | shasum -a 256 -c -s; then
  echo "already have $dest"; exit 0
fi
echo "downloading $name (about 70 MB)"
# .part so an interrupted download is resumed (-C -) rather than mistaken for the ISO
curl -fL -C - --retry 3 -o "$dest.part" "$url"
echo "$sha256  $dest.part" | shasum -a 256 -c -s || {
  echo "checksum mismatch for $name; deleting the download"; rm -f "$dest.part"; exit 1
}
mv "$dest.part" "$dest"
echo "saved $dest"
