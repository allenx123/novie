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
adwaita-icon-theme font-dejavu
firefox
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
# guest/overlay in the repo: the inittab that autologins into X, the X session, and the
# startup script that takes the host's time zone out of fw_cfg.
cp -a /seed/overlay/. /mnt/
# The overlay is packed on a Mac, so make sure every path it adds belongs to root once it is
# in the guest. Firefox is the one that notices: it refuses to start as root unless $HOME is
# owned by root too ("Running Firefox as root in a regular user's session is not supported").
(cd /seed/overlay && find . -mindepth 1) | sed 's|^\./||' | while IFS= read -r path; do
    chown root:root "/mnt/$path"
done
chmod +x /mnt/root/.xinitrc /mnt/etc/local.d/*.start \
         /mnt/etc/init.d/novie-clock /mnt/usr/local/bin/novie-clock

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

echo "### novie: root password"
# The VM has no network path into it (user-mode NAT, nothing forwarded), and tty1 logs in
# without a password. This is only so polkit and `su` inside the desktop have something.
echo 'root:novie' | chpasswd

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
