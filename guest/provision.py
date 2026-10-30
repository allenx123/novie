#!/usr/bin/env python3
"""Drives an Alpine install inside QEMU from the host, over the guest's serial console.

Boots the Alpine aarch64 ISO under HVF with a blank disk attached, logs in on the serial
console (the live image gives a root shell with no password), hands the guest a tarball of
guest/ through QEMU's fw_cfg device, and runs the provisioning script inside it. Everything
the console prints is mirrored to a log, so a failed build can be read afterwards.

Nothing here is interactive: the script in the guest ends by printing a sentinel and powering
off, and this exits non-zero if that sentinel never arrives.

  usage: provision.py --iso ISO --disk DISK.qcow2 --seed SEED.tar.gz --log LOG [--probe CMD]
"""
import argparse
import os
import re
import selectors
import subprocess
import sys
import time

# How the guest reports an exit status back. The console echoes every command typed into it,
# so the sentinel is assembled in the guest ("$s") and only ever matches real output.
RESULT = re.compile(rb"NOVIE-RESULT:(\d+)")
REPORT = '; s=$?; echo; echo "NOVIE-RESULT:$s"'

# "localhost:~#", with whatever escape sequences busybox's ash puts around it: colour codes,
# and the cursor-position query (ESC[6n) it writes right after the prompt to find the window
# width. That query has to be allowed for, not just colours -- it arrives in the same read as
# the prompt often enough, and a prompt that doesn't match is a build that waits out its
# timeout against a console with nothing left to say.
PROMPT = re.compile(rb"[-\w.]+:[^\n]{0,40}# (?:\x1b\[[\d;]*[A-Za-z])*$")


class Console:
    """Reads and writes the guest's serial console, mirroring everything to a log."""

    def __init__(self, proc, log):
        self.proc, self.log = proc, log
        self.buf = b""
        self.sel = selectors.DefaultSelector()
        self.sel.register(proc.stdout, selectors.EVENT_READ)

    def pump(self, timeout):
        """Reads whatever is available; returns False once the console is closed."""
        if not self.sel.select(timeout):
            return True
        chunk = os.read(self.proc.stdout.fileno(), 65536)
        if not chunk:
            return False
        # Only the tail is ever matched against, and a desktop install prints a lot
        self.buf = (self.buf + chunk)[-65536:]
        self.log.write(chunk)
        self.log.flush()
        return True

    def wait_for(self, pattern, timeout, what):
        """Waits for a regex (or a literal) to show up in the console output."""
        rx = pattern if hasattr(pattern, "search") else re.compile(re.escape(pattern.encode()))
        deadline = time.monotonic() + timeout
        while True:
            m = rx.search(self.buf[-8192:])
            if m:
                self.buf = b""
                return m
            if time.monotonic() > deadline:
                raise TimeoutError(f"timed out after {timeout}s waiting for {what}")
            if not self.pump(1.0):
                raise EOFError(f"the VM's console closed while waiting for {what}")

    def send(self, line):
        self.proc.stdin.write(line.encode() + b"\n")
        self.proc.stdin.flush()


def qemu_args(a):
    cpus = max(2, min(4, (os.cpu_count() or 4) // 2))
    args = [
        a.qemu, "-M", "virt", "-accel", "hvf", "-cpu", "host",
        "-smp", str(cpus), "-m", "4096",
        # Direct kernel boot with the ISO's own command line (no firmware, no bootloader):
        # the installed system gets UEFI + GRUB, but provisioning does not need them.
        "-kernel", a.kernel, "-initrd", a.initramfs,
        "-append", "modules=loop,squashfs,sd-mod,usb-storage quiet console=ttyAMA0",
        # The target disk first, so it is /dev/vda inside the guest (virtio disks are
        # numbered in the order they are declared), then the ISO as a read-only disk --
        # Alpine's initramfs finds its live media by scanning, so it needs no bus of its own.
        "-drive", f"file={a.disk},if=virtio,format=qcow2,cache=writeback",
        "-drive", f"file={a.iso},if=virtio,format=raw,readonly=on,file.locking=off",
        # How guest/ reaches the guest: no network service, no filesystem to build on macOS
        "-fw_cfg", f"name=opt/novie/seed.tar.gz,file={a.seed}",
        "-nic", "user,model=virtio-net-pci",
        "-display", "none", "-vga", "none",
        "-serial", "stdio",
        "-no-reboot",
    ]
    if a.data_dir:
        args = [a.qemu, "-L", a.data_dir] + args[1:]
    return args


def main():
    p = argparse.ArgumentParser()
    for name in ("qemu", "iso", "kernel", "initramfs", "disk", "seed", "log"):
        p.add_argument(f"--{name}", required=True)
    p.add_argument("--data-dir")
    p.add_argument("--timeout", type=float, default=2700)
    p.add_argument("--probe", help="run this command instead of provisioning, then stop")
    a = p.parse_args()

    log = open(a.log, "wb")
    args = qemu_args(a)
    log.write(b"+ " + " ".join(args).encode() + b"\n")
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    console = Console(proc, log)
    started = time.monotonic()

    def left():
        return max(30.0, a.timeout - (time.monotonic() - started))

    try:
        console.wait_for("login:", 180, "the Alpine live image to boot")
        console.send("root")
        console.wait_for(PROMPT, 60, "a root shell")
        if a.probe:
            console.send(a.probe + REPORT)
            console.wait_for(RESULT, 300, "the probe command")
            return 0
        # Unpack guest/ out of fw_cfg and hand over. One typed line, so nothing depends on
        # the console's line editing; the script itself arrives as bytes.
        console.send(
            "modprobe qemu_fw_cfg 2>/dev/null; mkdir -p /seed && "
            "tar xzf /sys/firmware/qemu_fw_cfg/by_name/opt/novie/seed.tar.gz/raw -C /seed && "
            "sh /seed/provision.sh" + REPORT
        )
        status = int(console.wait_for(RESULT, left(), "provisioning to finish").group(1))
        if status != 0:
            print(f"provisioning failed in the guest (exit {status}); see {a.log}", file=sys.stderr)
            return 1
        # provision.sh leaves the disk unmounted but the VM running, so the shutdown is
        # ordered from here: QEMU flushes the image as it exits.
        console.send("poweroff")
        return 0
    except (TimeoutError, EOFError) as e:
        print(f"{e}\nsee {a.log}", file=sys.stderr)
        return 1
    finally:
        # The guest powers itself off at the end; make sure QEMU is gone either way
        try:
            proc.wait(timeout=120)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        log.close()


if __name__ == "__main__":
    sys.exit(main())
