#!/bin/sh
# Installs Alpine Linux + XFCE onto the blank disk attached to the provisioning VM. Runs
# inside Alpine's live image, driven by guest/provision.py over the serial console; the disk
# it writes becomes the read-only base image the app boots (see VMManager).
#
# Must stay non-interactive and fail loudly: provision.py only knows this worked because it
# exits 0, so every step is checked and `set -e` is on.
set -eu

. /seed/config.env   # ALPINE_VERSION, ALPINE_MIRROR, TARGET_DISK

step() { echo; echo "### novie: $*"; }

# Everything the guest needs. Kept in one apk call so a missing name fails before any of the
# slow work: the base system and bootloader, then X, then XFCE itself.
#
# This list is expanded unquoted below, so it is words and nothing else -- a comment inside it
# would be handed to apk as package names.
#
# chromium is in community, and brings both /usr/bin/chromium and /usr/bin/chromium-browser
# with it, so nothing here has to make the second name. It is deliberately not pinned to a
# version: v3.24's community repo serves one chromium at a time (156.0.8078.79-r0 as this was
# written) and replaces it with every security release, so a pin is a build that breaks on
# Alpine's schedule rather than ours. font-freefont is what Alpine now calls ttf-freefont,
# which it still answers to as a `provides` alias; the real name is used, like font-dejavu.
#
# libreoffice-{writer,calc,impress} are in community too, on top of the 325 MB
# libreoffice-common they all depend on. libreoffice-gtk has to be named: it is an install_if
# package, keyed on the `libreoffice` meta-package nothing here installs, so without it the
# suite falls back to its own plain-X11 VCL plugin and its own file dialog instead of looking
# like the rest of the XFCE desktop. font-liberation is what LibreOffice's default styles ask
# for, and what it substitutes metric-for-metric for Times New Roman, Arial and Courier New,
# so a .docx written elsewhere lays out the way it did there; hunspell-en-us is the
# dictionary its spellchecker looks for in /usr/share/hunspell.
PACKAGES="
alpine-base linux-virt
grub grub-efi
eudev udev-init-scripts udev-init-scripts-openrc
e2fsprogs dosfstools
dhcpcd chrony
agetty tzdata
xorg-server xinit xf86-input-libinput xkeyboard-config setxkbmap xrandr xset xsetroot
mesa-dri-gallium mesa-gl
dbus dbus-x11 elogind polkit-elogind
xfce4 xfce4-terminal xfce4-screenshooter
adwaita-icon-theme font-dejavu font-freefont
firefox chromium
libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-gtk
font-liberation hunspell-en-us
nano
"

step "checking $TARGET_DISK is the blank target disk"
# The install ISO is attached to this VM too; writing a partition table over it would wipe
# the system running this script.
if blkid "$TARGET_DISK" 2>/dev/null | grep -q iso9660; then
    echo "$TARGET_DISK is the install ISO, not the target disk" >&2
    exit 1
fi

step "bringing up the network"
ip link set eth0 up
udhcpc -i eth0 -n -q -t 15 || true
grep -q nameserver /etc/resolv.conf 2>/dev/null || echo "nameserver 1.1.1.1" > /etc/resolv.conf

step "pointing the live system at $ALPINE_MIRROR"
cat > /etc/apk/repositories <<EOF
$ALPINE_MIRROR/v$ALPINE_VERSION/main
$ALPINE_MIRROR/v$ALPINE_VERSION/community
EOF
tries=0
until apk update; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || { echo "no route to the Alpine mirror" >&2; exit 1; }
    sleep 3
done
apk add --no-cache --no-progress sfdisk e2fsprogs dosfstools

step "partitioning $TARGET_DISK"
# GPT: an EFI system partition for the bootloader, the rest for the root filesystem.
# "U" and "L" are sfdisk's shorthand for those two partition types.
sfdisk --wipe always --wipe-partitions always "$TARGET_DISK" <<'EOF'
label: gpt
,512M,U
,,L
EOF
mdev -s 2>/dev/null || true
# Labels rather than UUIDs throughout (fstab, the kernel's root=, GRUB's search), so nothing
# has to read an identifier back out of the disk and the image is reproducible.
mkfs.vfat -F32 -n NOVIE-EFI "${TARGET_DISK}1"
mkfs.ext4 -q -F -L novie-root "${TARGET_DISK}2"

step "mounting the new system at /mnt"
mkdir -p /mnt
mount -t ext4 "${TARGET_DISK}2" /mnt
mkdir -p /mnt/boot/efi
mount -t vfat "${TARGET_DISK}1" /mnt/boot/efi

step "installing the base system and XFCE (this is the slow part)"
mkdir -p /mnt/etc/apk/keys
cp /etc/apk/repositories /mnt/etc/apk/repositories
cp /etc/apk/keys/* /mnt/etc/apk/keys/   # so the new root can verify packages itself
cp /etc/resolv.conf /mnt/etc/resolv.conf
# --no-progress because this all goes through a serial console and into provision.log
apk add --root /mnt --initdb --no-cache --no-progress $PACKAGES

step "copying the guest overlay in"
# guest/overlay in the repo: the inittab that autologins into X, the desktop user's X session
# and XFCE settings, the startup scripts that take the host's time zone out of fw_cfg and
# make the session's runtime directory, and the browser and LibreOffice settings that keep a
# first-run dialog from being the first thing an MCP client sees.
cp -a /seed/overlay/. /mnt/
# The overlay is packed on a Mac, so without this every path it adds arrives owned by whoever
# ran the build (uid 501, typically). Everything in it is root's except the desktop user's
# home directory, which is handed to novie in the chroot below once that user exists.
(cd /seed/overlay && find . -mindepth 1) | sed 's|^\./||' | while IFS= read -r path; do
    chown root:root "/mnt/$path"
done
chmod +x /mnt/home/novie/.xinitrc /mnt/etc/local.d/*.start \
         /mnt/etc/init.d/novie-clock /mnt/usr/local/bin/novie-clock
# The LibreOffice defaults in the overlay are a layer over the registry the packages ship,
# dropped in beside main.xcd. If that directory ever moves, `cp -a` above would quietly
# create an empty one and the modal first-run dialogs would be back, with nothing to say so.
[ -f /mnt/usr/lib/libreoffice/share/registry/main.xcd ] || {
    echo "LibreOffice's registry is not where the overlay puts zz-novie.xcd" >&2
    exit 1
}

step "configuring the installed system"
cat > /mnt/etc/fstab <<'EOF'
LABEL=novie-root  /          ext4  rw,relatime             0 1
LABEL=NOVIE-EFI   /boot/efi  vfat  rw,relatime,umask=0077  0 2
EOF
echo novie > /mnt/etc/hostname
mount -t proc  none /mnt/proc
mount -t sysfs none /mnt/sys
mount -o bind  /dev /mnt/dev

chroot /mnt /bin/sh -eu <<'CHROOT'
echo "### novie: openrc runlevels"
# A root made with `apk --initdb` has empty runlevels; this is Alpine's own list for a manual
# install, plus the services the desktop needs.
#
# udev rather than the mdev alpine-base sets up, because Xorg finds its keyboard and mouse
# through udev's device properties and shows an unclickable desktop without it. These are the
# same packages and runlevel entries `setup-devd udev` would add, minus its `rc-service start`
# calls: there is no openrc running in here to start anything, and trying fails the build.
for s in devfs dmesg udev udev-trigger udev-settle; do rc-update add $s sysinit; done
for s in modules sysctl hostname bootmisc syslog hwclock localmount; do rc-update add $s boot; done
for s in killprocs mount-ro savecache; do rc-update add $s shutdown; done
for s in dhcpcd chronyd dbus elogind local udev-postmount novie-clock; do rc-update add $s default; done
# polkitd is dbus-activated, so the desktop works without this; starting it with everything
# else just means the first thing to ask is not waiting on an activation.
if [ -f /etc/init.d/polkit ]; then rc-update add polkit default; fi

echo "### novie: the desktop user"
# The desktop runs as an ordinary user, not root, so that the programs in it behave the way
# they do on any other Linux desktop: Firefox refuses to run as root at all unless $HOME is
# root's too, and plenty of other software either warns, writes its files somewhere else, or
# quietly skips a safety check when it finds itself with uid 0.
#
# -H, not adduser's own mkdir: /home/novie already exists, because the overlay's dotfiles were
# copied into it above. busybox adduser only warns when its mkdir fails and then skips the
# chown it would have done next, which would leave the home directory owned by root -- the
# exact thing Firefox refuses to start in. So the home directory is handed over here instead.
adduser -D -H -h /home/novie -s /bin/sh -g "Novie desktop" novie
chown -R novie:novie /home/novie
chmod 755 /home/novie
# What a seat needs: the framebuffer and the evdev devices Xorg opens, and the sound and
# network groups a desktop expects to be in. Checked rather than assumed -- addgroup would
# happily create a group of its own name here, and the desktop would come up without the
# device access it was supposed to get.
for g in video input audio netdev; do
    grep -q "^$g:" /etc/group || { echo "no $g group in the guest" >&2; exit 1; }
    addgroup novie "$g"
done

echo "### novie: passwords"
# The VM has no network path into it (user-mode NAT, nothing forwarded), and tty1 logs in
# without one. These are only so that `su` in a terminal inside the desktop works, and so
# that anything that does still ask (pkexec, say) has an answer. The desktop's own power
# actions do not: /etc/polkit-1/rules.d/50-novie.rules grants those to novie outright.
echo 'root:novie' | chpasswd
echo 'novie:novie' | chpasswd

echo "### novie: clock"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
# The app saves the VM to a file on quit and resumes it later, so the guest comes back with a
# clock that stopped when it was suspended. /usr/local/bin/novie-clock is what repairs that,
# from the RTC; chronyd keeps the clock right the rest of the time, and these two edits are so
# that it cannot make either job harder.
#
# Alpine's chrony.conf lets chronyd *step* the clock only during its first three updates
# ("makestep 1.0 3"), and every session spends those in its first minutes; after that it
# corrects by slewing, which is capped at a few percent, so minutes of offset would take hours
# to walk off. The stock line is rewritten in place rather than overridden from elsewhere in
# the file: with two makestep lines chronyd kept the first one, measured on a resumed VM that
# stayed 250s behind. One line, no ambiguity.
sed -i 's/^makestep 1\.0 3$/makestep 1.0 -1/' /etc/chrony/chrony.conf
# rtcsync hands the system clock to the kernel to write into the RTC every 11 minutes. The RTC
# here is QEMU's, which already follows the Mac, and novie-clock reads it to repair the system
# clock after a resume -- so letting a just-resumed guest write its stale time back into the
# RTC would poison the only source either of them can trust.
sed -i 's/^rtcsync$/# rtcsync -- off: novie-clock reads the RTC, see provision.sh/' /etc/chrony/chrony.conf
# ...and make chronyd notice sooner: the default maxpoll of 10 leaves up to 1024s between
# measurements, and a suspended VM's clocks are all frozen, so that whole interval still has
# to pass after a resume before the offset is even measured. 6 is 64s, the fastest rate
# pool.ntp.org asks clients to keep to.
sed -i 's/^pool pool\.ntp\.org iburst$/pool pool.ntp.org iburst maxpoll 6/' /etc/chrony/chrony.conf
# All checked: a silent no-match here means a guest that never fixes its clock, takes a quarter
# of an hour to notice what time it is, or overwrites the RTC novie-clock reads -- and none of
# that shows up until someone suspends a VM and resumes it later.
grep -q '^makestep 1\.0 -1$' /etc/chrony/chrony.conf
grep -q '^pool pool\.ntp\.org iburst maxpoll 6$' /etc/chrony/chrony.conf
[ "$(grep -c '^makestep' /etc/chrony/chrony.conf)" = 1 ]
! grep -q '^rtcsync$' /etc/chrony/chrony.conf

echo "### novie: initramfs"
# virtio for the disk, ext4 for the root filesystem, kms so the virtio-gpu console comes up
cat > /etc/mkinitfs/mkinitfs.conf <<'EOF'
features="base virtio ext4 keymap kms"
EOF
kver=$(ls /lib/modules | head -1)
mkinitfs -o /boot/initramfs-virt "$kver"

echo "### novie: bootloader"
# --removable puts GRUB at the EFI default path (EFI/BOOT/BOOTAA64.EFI) and skips NVRAM, so
# the image boots on firmware that has never seen it — which is every launch, because the
# app gives QEMU a fresh variable store each time.
grub-install --target=arm64-efi --efi-directory=/boot/efi --removable --no-nvram
cat > /boot/grub/grub.cfg <<'EOF'
set timeout=0
set default=0
insmod part_gpt
insmod ext2
search --no-floppy --label --set=root novie-root
menuentry 'Novie (Alpine Linux)' {
    linux /boot/vmlinuz-virt root=LABEL=novie-root rootfstype=ext4 modules=virtio_blk,ext4 console=tty0 console=ttyAMA0,115200 quiet
    initrd /boot/initramfs-virt
}
EOF
CHROOT

step "unmounting"
umount /mnt/dev /mnt/sys /mnt/proc /mnt/boot/efi
umount /mnt
sync
step "done"
