# Novie

A macOS 26+ desktop app (Apple silicon) that runs an Alpine Linux XFCE desktop in a VM and hands
its mouse and keyboard to another agent over MCP. The app shows the VM's screen, plays lists of
mouse, keyboard and wait actions into it and answers each list with a screenshot, and lets you take
over the VM's mouse and keyboard yourself.

The guest is aarch64, so QEMU runs it on `-accel hvf` — Hypervisor.framework, the same hardware
virtualization Apple's Virtualization.framework is built on. The guest's own instructions execute
on the Mac's cores instead of being emulated, which is why the desktop boots in seconds.

Nothing of ours drives the VM from inside it. Actions go in through QEMU's VNC server as events
from the emulated tablet and keyboard, and screenshots come out of the framebuffer the window is
already drawing, so there is no agent, no Python and no listening port in the guest. The only
things of ours running in there are two small shell scripts that keep the guest's idea of the
time honest (see *Time* below).

## Build and run

To build you need an Apple silicon Mac on macOS 26 or later with:

- the Xcode command line tools (`xcode-select --install`): `swiftc`, `codesign`, `install_name_tool`
  and `python3`
- [Homebrew](https://brew.sh), then `brew install qemu`
- internet access on the first build, for the ISO and the guest's packages

```sh
brew install qemu
./build.sh                      # builds the guest image on the first run (several minutes)
open "build/Novie.app"
```

The first build downloads the Alpine Linux 3.24.3 aarch64 ISO (about 90 MB) into `guest/iso/` and
checks its SHA-256 (`guest/fetch_iso.sh`), then installs Alpine and XFCE onto a disk image
(`guest/build_image.sh`, see *The guest image* below). The image is cached in `guest/image/`, so
only the first build pays for it; `./build.sh --force-image` builds it again.

1. Turn on **Novie → Allow MCP Connections** (it's off until you do) and point an agent at the
   app's own binary with `--mcp` (see *Letting other agents use Novie* below).
2. The desktop appears in about 20 seconds. Input works from the first frame — it goes to
   emulated hardware, so the boot screens can be driven too.
3. **Take Control** (⇧⌘K) forwards your mouse and keyboard to the VM (orange border) and locks
   MCP clients out, screenshots included. Click it again to hand control back. ⌘ shortcuts stay
   with macOS; use Control for shortcuts inside the VM.
4. **Restart VM** boots it fresh.
5. **Hide Novie** (⌘H) gets the window out of the way while an agent keeps working in it.

The guest logs in as root with no prompt (`agetty --autologin`) and the root password is `novie`,
which only matters for polkit prompts and `su` inside the desktop: there is no network path into
the VM to use it from.

## Rebuilding after a change

Run `./build.sh` again. It rebuilds the app in about half a minute and reuses the cached guest
image unless something it is built from changed:

1. `guest/build_image.sh` compares a hash of `guest/provision.sh`, `guest/provision.py` and
   `guest/overlay/` against `guest/image/*.stamp`, and reinstalls the guest only on a mismatch.
2. The Swift sources in `app/src/` are compiled with `swiftc`.
3. The app bundle is assembled with the guest image.
4. `bundle_qemu.sh` copies Homebrew's `qemu-system-aarch64` and `qemu-img` into
   `Contents/MacOS/`, their non-system libraries into `Contents/Frameworks/` (references
   rewritten to `@loader_path`), and the firmware/keymap files the VM uses into
   `Contents/Resources/qemu/` (passed with `-L`). Then everything is ad-hoc signed, with
   `qemu-system-aarch64` keeping its hypervisor entitlement.

Then quit the app (⌘Q, which also shuts down the VM) and reopen it. A rebuild invalidates the
saved VM state (see *Suspend and resume*), so the VM boots fresh.

## Sharing the app

The built app bundles QEMU, so the Macs that run it need nothing installed. They do need Apple
silicon and at least the macOS version of the Mac that built it: Homebrew's QEMU targets the macOS
it was installed on, so build on macOS 26 for the app to run on 26 and later. Copies sent by AirDrop
or download are quarantined (the app is only ad-hoc signed): right-click → Open, or
`xattr -dr com.apple.quarantine "Novie.app"`.

## Letting other agents use Novie (MCP)

```sh
claude mcp add --scope user novie -- "/path/to/Novie.app/Contents/MacOS/NovieMCP" --mcp
```

There is one tool, `computer`. It takes a list of actions, plays them into the VM in order, and
always answers with a screenshot — an empty list is how a client just looks at the screen. The
action vocabulary is the one the computer-use tool uses, so a model already knows it: `key`,
`type`, `mouse_move`, `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click`,
`left_click_drag`, `left_mouse_down`, `left_mouse_up`, `scroll`, `hold_key`, `wait` and
`screenshot` (which does nothing, since a screenshot always comes back anyway). Coordinates are
pixels in the screenshot.

```json
{"actions": [{"action": "left_click", "coordinate": [640, 400]},
             {"action": "type", "text": "hello"},
             {"action": "key", "text": "Return"},
             {"action": "wait", "duration": 3}]}
```

One call may spend up to ten minutes playing its actions (`MCPServer.callBudget`). The first thing
a call checks is whether the person has taken control: if they have, it answers "cannot proceed"
and returns **no screenshot**, since the screen is theirs while they hold it. The same check runs
between actions, so taking control stops a list part-way.

## How it works

- **VM**: `qemu-system-aarch64 -M virt -accel hvf -cpu host`. `-cpu host` is the only model HVF
  offers, and `-accel hvf` needs the `com.apple.security.hypervisor` entitlement that
  `bundle_qemu.sh` preserves on the bundled binary. `QEMU_PATH` and `QEMU_IMG_PATH` override the
  bundled copies; if they're missing, the app falls back to `/opt/homebrew/bin`. The VM boots UEFI
  (`edk2-aarch64-code.fd`) into the guest's own GRUB. User-mode NAT gives the VM internet access,
  and nothing is forwarded the other way: there is no port into the guest at all.
- **Ephemeral disk**: the image in the app bundle is never written to. `VMManager.prepareDisks()`
  gives QEMU a qcow2 overlay in the run directory backed by it, plus a blank 64 MiB UEFI variable
  store, and recreates both on every fresh boot — that is what wipes the VM. A resume keeps them,
  because the restored RAM expects the disk exactly as it was.
- **Display and input**: QEMU serves VNC on a Unix socket in
  `~/Library/Application Support/Novie/`. `RFBClient` is the app's own small VNC client; it
  holds the framebuffer every screenshot is copied from and sends the two RFB input messages
  (`sendPointer`, `sendKey`). `VMDisplayView` uses them for Take Control, and `ActionRunner` uses
  them for MCP — one connection, two callers, so a connected agent can't do anything a person at
  the window couldn't. The screen is 1280x800 because that is the EDID `virtio-gpu-pci` reports.
  The window is held at that ratio: `MainWindowController.windowWillResize` snaps every resize so
  the display view stays at the guest's aspect ratio, which means the VM's screen is scaled by the
  same factor in both directions and is never letterboxed, whichever edge is dragged. The ratio
  comes from the framebuffer (`RFBClient.onResize`), so a guest that changes resolution takes the
  window with it.
- **Actions**: `ActionRunner` (in `ComputerActions.swift`) turns one action list into RFB events.
  It keeps the pointer position, so actions without a coordinate act where the pointer already is;
  it sleeps between events because the emulated USB keyboard and tablet drop input sent faster; it
  steps a drag through intermediate positions so apps see the pointer travel; and it releases
  everything still held when the list ends, so a stuck button or modifier is never left for whoever
  takes control next. It asks between actions whether input is still allowed, which is how Take
  Control stops it. Key names are X11 keysyms (`Return`, `ctrl+s`, `F5`); QEMU maps them to
  scancodes with the `keymaps/en-us` file in `Contents/Resources/qemu`.
- **MCP layer**: `MCPServer` listens on `mcp.sock` in the run directory and calls through
  `MCPHost`, which `MainWindowController` implements in three methods: where input may go right
  now, a screenshot, and a line for the window's status. The same binary run as
  `NovieMCP --mcp` (`MCPBridge`) is the stdio MCP server that forwards to it, which is why
  clients need nothing installed; the bridge answers `initialize` and `tools/list` itself, so the
  server still starts when the app is closed and tool calls explain why they can't run. It's off
  until **Novie → Allow MCP Connections** (`allowMCPConnections` in UserDefaults). One call plays
  at a time (`MCPServer.claim()`), so two clients can't fight over the pointer.
- **Suspend and resume**: on quit, `VMManager.suspend()` uses QEMU's QMP socket (`qmp.sock` in the
  run directory) to `stop` the VM and `migrate` it to `file:…/vmstate` (RAM + device state, so its
  size follows what the guest is actually using: ~850 MB and ~8 s for an idle desktop, ~1.9 GB and
  ~16 s with Firefox open), then quits QEMU. The next launch passes `-incoming file:…/vmstate`, sends `cont` once it has loaded (a
  VM saved while stopped comes back paused), and deletes the file, so a crash later means a clean
  boot rather than resuming an old state. `vmstate.json` holds a fingerprint of the QEMU binary,
  guest image, firmware (path, size, mtime) and the QEMU arguments; on a mismatch (any rebuild, or
  moving the app) the state is discarded and the VM boots. If QEMU fails to load the state it
  exits, and the app deletes the file and boots fresh. MCP stops taking calls before the save, so
  an action list isn't left half-played into a VM being written out.
- **Time**: the guest's clock runs in UTC, read from the emulated RTC at boot (`-rtc base=utc`
  plus `hwclock`) and kept right by `chronyd` while the VM runs. A suspended VM's clocks are all
  frozen, so it resumes as far behind as the app spent closed, and chronyd cannot be the thing
  that repairs that: after a jump that size its samples straddle the gap and it rejects every
  source it has, so it makes no clock update at all (measured: still 249s behind five minutes
  after a resume, syslog full of `exceeds maxjitter`/`exceeds maxdistance`). The RTC *is* right
  the moment the VM comes back, so `/usr/local/bin/novie-clock` — an openrc service in the
  overlay — compares `/sys/class/rtc/rtc0/since_epoch` against the system clock every 20s and
  runs `hwclock --hctosys` when they differ by more than 3s, then restarts chronyd so it drops
  the samples that span the gap. That needs no network. `provision.sh` also rewrites Alpine's
  `makestep 1.0 3` to `makestep 1.0 -1` so chronyd may still step a badly wrong clock at any
  time, sets `maxpoll 6` so it measures within a minute, and turns `rtcsync` off so the guest
  can never write its stale time into the RTC that novie-clock reads.
  So that the desktop still shows the time on the Mac beside it, `VMManager` writes the
  host's time zone name into the run directory and passes it with `-fw_cfg`; the guest's
  `/etc/local.d/novie-timezone.start` reads it back out of sysfs and points `/etc/localtime` at it.
  fw_cfg is read-only from the guest's side and carries nothing else.

## The guest image

`guest/build_image.sh` produces `guest/image/alpine-xfce-aarch64.qcow2`, the read-only disk the app
boots. There is no way to run `apk` on macOS, so the install happens in a throwaway VM:

1. The Alpine aarch64 ISO's kernel and initramfs are pulled out with `bsdtar` and booted directly
   (no firmware, no bootloader) with a blank qcow2 attached as `/dev/vda`.
2. `guest/provision.py` drives that VM's serial console from the host: it waits for the live
   image's login prompt, logs in as root, and types one line that unpacks a tarball of `guest/` out
   of QEMU's `fw_cfg` device and runs `provision.sh` from it.
3. `guest/provision.sh` partitions the disk, installs Alpine and XFCE into it with
   `apk add --root`, copies `guest/overlay/` over the result, and configures it in a `chroot`
   (openrc runlevels, udev for Xorg's input devices, `mkinitfs`, and GRUB on the EFI system
   partition).
4. The image is compacted with `qemu-img convert` and stamped with a hash of everything it was
   built from, so later builds reuse it.

The desktop it produces is XFCE with xfce4-terminal, Thunar and Firefox, logged in as root with
no prompt. Everything in the guest is configured at this point; at runtime the only things of ours
in it are the overlay's two clock scripts -- `local.d/novie-timezone.start`, which sets the time
zone once at boot, and `novie-clock`, which watches the RTC so a resumed VM's clock is put right.

Logs: `~/Library/Application Support/Novie/serial.log` (guest console) and `qemu.log`.
In the app, use VM → Show VM Log. The install's own console log is `guest/image/provision.log`.
The window has one status line and no output pane, so the app's own messages go to the system
log — `log stream --predicate 'eventMessage CONTAINS "Novie:"'`, or Console.app.

## Project layout

| Path | What it is |
|---|---|
| `guest/fetch_iso.sh` | Downloads and verifies the Alpine aarch64 ISO into `guest/iso/` (not committed). |
| `guest/build_image.sh` | Builds and caches the guest disk image; the entry point for everything below. |
| `guest/provision.py` | Host side of the install: runs the throwaway QEMU VM and drives its serial console. |
| `guest/provision.sh` | Guest side of the install: partitions, installs Alpine + XFCE, configures and bootloads it. |
| `guest/overlay/` | Files copied into the guest's root filesystem: the inittab that autologins into X, `root/.xinitrc` (the XFCE session), per-user xfconf overrides, `etc/local.d/novie-timezone.start`, and `usr/local/bin/novie-clock` with the `etc/init.d/novie-clock` service that supervises it. |
| `app/src/` | The Swift app: `VMManager` (QEMU launch/args, the disk overlay, suspend/resume), `QMPClient` (QEMU control socket), `RFBClient` (VNC client: framebuffer + input), `ComputerActions` (`VMInput` and the `ActionRunner` that plays an action list), `VMDisplayView` (rendering + mouse/keyboard forwarding for take control), `MainWindowController` (the window and `MCPHost`), `MCPServer` (socket other agents drive the VM through) and `MCPBridge` (the `--mcp` stdio MCP server). |
| `app/Package.swift` | For opening the sources in Xcode only; `build.sh` uses `swiftc`. |
| `bundle/Info.plist` | The app bundle's Info.plist. |
| `bundle/Novie.icns` | The app icon|
| `bundle_qemu.sh` | Copies QEMU, `qemu-img`, their dylibs and firmware into the app bundle. |

## Gotchas found while building this

- **Virtualization.framework can't be used for this app, even though the guest is now aarch64.**
  It has no API to read the guest's framebuffer or to inject synthetic input: `VZVirtualMachineView`
  only renders into a window and only accepts real AppKit events. Screenshots would have to come
  from ScreenCaptureKit (Screen Recording permission, and the window has to be visible, so Hide
  Novie would stop working) and MCP input from synthesized `NSEvent`s, which Apple doesn't support.
  QEMU on `-accel hvf` uses the same Hypervisor.framework underneath and keeps the VNC socket that
  the screenshots and the input both depend on.
- **`-accel hvf` needs the `com.apple.security.hypervisor` entitlement.** Homebrew's QEMU ships
  with it; `install_name_tool` invalidates the signature, so `bundle_qemu.sh` re-signs with
  `--preserve-metadata=entitlements` and then checks the entitlement survived. `build.sh` checks
  again after signing the bundle. Lose it and QEMU exits saying HVF is unavailable.
- **The `virt` machine has no PS/2 controller**, so a VM with no `-device usb-kbd` has no keyboard
  at all. On x86 the `q35` machine's built-in PS/2 keyboard made that easy to miss: only the
  tablet had to be added.
- **GRUB is installed with `--removable`, on purpose.** That puts it at the EFI default path
  (`EFI/BOOT/BOOTAA64.EFI`) and skips writing UEFI NVRAM variables, which is what makes the image
  bootable from the blank variable store the app hands QEMU on every fresh boot. A normal
  `grub-install` records a boot entry in NVRAM, and that store is thrown away with the disk
  overlay.
- **Everything in `guest/overlay/` arrives owned by the Mac user who built the image** unless
  something stops it: the seed tarball is packed on macOS, so `cp -a` faithfully reproduces uid
  501 inside the guest. Firefox is what notices — it refuses to start as root unless `$HOME` is
  owned by root too, and dies with "Running Firefox as root in a regular user's session is not
  supported. ($HOME is /root which is owned by uid 501.)". `build_image.sh` packs the tarball with
  `--uid 0 --gid 0` and `provision.sh` chowns every path the overlay adds.
- **XFCE's panel launchers go through `exo-open --launch`, which needs a registered helper.**
  Installing Firefox is not enough: with no `~/.config/xfce4/helpers.rc` the panel's Web Browser
  button just says "Failed to execute default Web Browser. I/O error." The overlay ships that
  file, naming helpers from `/usr/share/xfce4/helpers`.
- **An xfconf file in `/etc/xdg` replaces the shipped one; it doesn't merge with it.** Dropping a
  two-property `xfce4-session.xml` there to turn session saving off took XFCE's Failsafe session
  definition with it, and the desktop came up as nothing but an "Unable to load a failsafe session"
  dialog. Per-user overrides go in `/root/.config/xfce4/xfconf/xfce-perchannel-xml/`, which xfconf
  merges over the system defaults, and that is where `guest/overlay` keeps them.
- **`chronyd` does not fix the clock of a resumed VM, and two separate things stop it.** The
  first is that Alpine's `chrony.conf` ships `makestep 1.0 3`, so chronyd may jump the clock only
  during its first three clock updates — every session spends those in its first minutes, and
  after that it may only slew, at a few percent. The second, which only showed up once the first
  was fixed and the VM was actually resumed, is that chronyd rejects its sources outright after a
  jump that large: the samples it holds straddle the suspend gap, so every one of them trips
  `exceeds maxjitter of 1.000 seconds` or `exceeds maxdistance of 3.000 seconds` and it makes no
  clock update at all. A VM resumed 250s behind sat there for the full five minutes it was
  watched, not even slewing. This is why the clock is recovered from the RTC by `novie-clock` and
  chronyd is only the backstop.
- **With two `makestep` lines in `chrony.conf`, chronyd keeps the first.** The fix was first
  written as an appended `makestep 1.0 -1`, on the assumption that the last value parsed wins.
  It does not: the rebuilt image still had the stock three-step limit in force. `provision.sh`
  rewrites the stock line in place instead and asserts there is exactly one `makestep` in the
  file. (A drop-in under `/etc/chrony/conf.d` is no good either, for the opposite reason: the
  `confdir` include sits on the file's *first* line, so a drop-in is parsed before the stock
  directive it is meant to replace.)
- **The emulated RTC is right the moment a VM resumes, even though the guest's clock isn't.**
  With `-rtc base=utc` the goldfish RTC follows the host across a `migrate`/`-incoming` pair, so
  it reads the Mac's time to the second while `date` in the guest is still minutes behind — that
  is what `novie-clock` is built on, and why recovery needs no network. It also means nothing in
  the guest may write to the RTC: `/etc/conf.d/hwclock` keeps `clock_systohc=NO` and
  `provision.sh` turns chrony's `rtcsync` off, or a just-resumed guest would hand its stale time
  to the kernel to store there and the one trustworthy source would be gone.
- **The serial console echoes every command typed into it**, which quietly broke the provisioning
  driver: it waited for a sentinel that was also a literal in the command it had just sent, matched
  the echo instead of the output, and killed QEMU in the middle of the install. The sentinel is now
  assembled in the guest (`echo "NOVIE-RESULT:$s"`), so the echoed `$s` can't match.
- **Virtio disks are numbered in the order they're declared**, so the install ISO has to be
  declared *after* the blank target disk or the target isn't `/dev/vda`. `provision.sh` checks
  `blkid` for `iso9660` before writing a partition table, because getting this wrong means
  repartitioning the live system that is running the script.
- **`keymaps/en-us` is what makes VNC input work.** QEMU maps the keysyms in RFB key events to
  scancodes through that file (without it `-vnc` won't even start), which is why `bundle_qemu.sh`
  copies it. It is also why only characters the keymap knows can be typed, and why there is no path
  for arbitrary Unicode. The guest clipboard isn't one either — QEMU only forwards VNC clipboard to
  a guest running spice-vdagent, which this image doesn't.
- **QEMU's VNC server handles shift for letters and for punctuation in opposite ways**, which is
  the single most confusing thing here. Sending a second VNC client straight at `vnc.sock` (see
  Debugging) settles what it does:

  | sent | arrives as | |
  |---|---|---|
  | bare keysym `A` | `A` | QEMU derives the case from the keysym |
  | keysym `a` with Shift_L held | `a` | the client's shift is *overridden* |
  | bare keysym `%` | `5` | the keymap's `percent 0x06 shift` flag is ignored |
  | keysym `5` with Shift_L held | `%` | the client's shift is obeyed |

  So a letter must carry its case in the keysym and must *not* be sent with shift (that suppresses
  the capital), while every other shifted character must be sent as shift held over the key it
  sits on. `ActionRunner.key(for:)` and `shiftedCharacters` do exactly that. Get it wrong and
  `echo "Novie: 100%"` reaches the guest as `echo 'Novie; 1005'` — `"`→`'`, `:`→`;`, `%`→`5`,
  `(`→`9`, `!`→`1`, `#`→`3`, `|`→`\`. The human path through `VMDisplayView` never hit this: it
  sends `charactersIgnoringModifiers` plus the real modifier state from `flagsChanged`, which is
  the base key plus a real shift — the same thing `ActionRunner` now does for punctuation.
- **The guest still drops input sent at full speed**, even on hardware virtualization: the USB
  keyboard and tablet are emulated devices with a finite queue, and an app that is still laying
  itself out loses characters typed into it. `ActionRunner` leaves a gap between events
  (`keyGap`, `clickGap`).
- **Xorg finds its keyboard and mouse through udev**, so the guest runs udev rather than the mdev
  that `alpine-base` sets up: Xorg's udev backend looks for `ID_INPUT_KEYBOARD`/`ID_INPUT_MOUSE`
  properties, which only exist once udevd has populated them, so with mdev it starts and shows a
  desktop that ignores every click. Alpine's own `setup-devd udev` can't be used to make the swap,
  because it finishes by starting the services it just enabled and there is no openrc running
  inside the chroot to start them in — it fails with "udev: failed to acquire lock: Bad file
  descriptor" and takes the build down with it. `provision.sh` does the same `apk add` and
  `rc-update add` calls and stops there.
- **Don't keep the ISO mounted with `hdiutil`** while QEMU runs it. Use
  `bsdtar -xf <iso> <file>` to pull files out of the ISO instead, which is also how
  `build_image.sh` gets the kernel it boots.
- **SwiftPM's default build system fails on this machine** ("Unknown error parsing property list"),
  hence plain `swiftc` in `build.sh`.
- **Testing the bundled QEMU on a Mac with Homebrew can hide missing files**: QEMU falls back to
  its compiled-in Homebrew data directory when a file isn't in `-L`. Block `/opt/homebrew` with
  `sandbox-exec` (see Known limitations) to test it properly. That's how the missing VNC keymap was
  found.

## Debugging

- **Guest output**: `~/Library/Application Support/Novie/serial.log` has the kernel log and
  everything openrc prints, and the guest's own X log is `/tmp/startx.log` inside the VM.
  QEMU's errors go to `qemu.log` in the same directory.
- **Shell in the VM**: Take Control, then open Terminal from the XFCE panel or applications menu.
  The disk overlay is thrown away on the next fresh boot, so ad-hoc changes there don't last.
- **Ground truth about input**: a second VNC client can connect to `vnc.sock` alongside the app
  (QEMU allows it, and the app asks for a shared session), do the RFB 3.8 handshake with security
  type None, and send raw KeyEvent/PointerEvent messages. That is how the shift behaviour above was
  pinned down without the app in the way.
- **Talking to the MCP layer**: turn on Novie → Allow MCP Connections, then pipe JSON-RPC into the
  app's own binary, which is the stdio MCP server:
  ```sh
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"computer","arguments":{"actions":[]}}}' \
    | build/Novie.app/Contents/MacOS/NovieMCP --mcp
  ```
  An empty action list is the cheapest call: it answers with a screenshot and touches nothing. To
  exercise `MCPServer` without booting a VM, compile it with a stub `MCPHost` into a small
  command-line binary and point the bridge at that.
- **Driving QEMU directly**: QEMU's QMP socket is `~/Library/Application Support/Novie/qmp.sock`
  (`screendump`, `send-key`, `input-send-event`, `query-status`, ...), e.g.
  `nc -U ~/Library/Application\ Support/Novie/qmp.sock` then `{"execute": "qmp_capabilities"}`.
- **A guest image that won't boot**: `guest/image/provision.log` is the whole install, serial
  console and all. To watch a build go wrong live, `tail -f` it. `provision.py --probe '<command>'`
  boots the live ISO, runs one command and reports its exit status, which is how to check something
  about the guest environment without a full install.

## Known limitations / ideas

- Only ASCII-ish text can be typed, for the keymap reason above. Text with other characters has to
  get in some other way.
- A `computer` call returns one screenshot, at the end. A long list is therefore played blind:
  the client should send a few actions, look, and send a few more, rather than guessing far ahead.
- There's no way to follow a call that is still playing — the next one is refused until it ends
  (ten minutes at most).
- Nothing reads the guest's own state (window list, files, clipboard, whether a program is
  actually running); a client only has pixels to go on.
- The person at the Mac and a connected agent share one pointer. Take Control is the only
  arbitration: while it's on, MCP gets nothing, and while it's off, the agent may click at any time.
- Persistence is only by suspend/resume. Everything the guest writes lives in a disk overlay that
  Restart VM, a rebuild, and a crash or force quit of the app all throw away (the state is only
  saved on a normal quit).
- The saved state holds guest RAM unencrypted (0600, in the 0700 run directory), and so does the
  disk overlay.
- ⌘ key combos aren't forwarded to the VM (they stay with macOS). Over MCP, `super` is, since it
  goes in as a keysym rather than through AppKit.
- The guest's software rendering is llvmpipe, so there's no GPU acceleration in the VM. QEMU can
  pass virgl through, but not with its VNC server as the display.
- The window has one status line and no history; details go to the system log.
- The bundled QEMU is a full Homebrew build (~50 MB with libraries); most of its features and
  libraries (gnutls, libssh, libusb, ...) are unused here.
- If the VM config changes (other devices, a different NIC model), the firmware it loads may need
  adding to `rom_files` in `bundle_qemu.sh`. Test with Homebrew hidden:
  `sandbox-exec -p '(version 1)(allow default)(deny file-read* (subpath "/opt/homebrew"))' <app>/Contents/MacOS/qemu-system-aarch64 -L <app>/Contents/Resources/qemu ...`
- The app can't run two VMs at once (one shared run directory), so two builds of it can't run side
  by side either.
- Building the guest image needs the network and takes several minutes; there is no prebuilt image
  to download.
- **MCP** needs the app open: there's no headless mode, and the bridge won't launch the app for you.
