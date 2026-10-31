import Foundation

/// Runs the Alpine Linux + XFCE guest in QEMU: an aarch64 VM on `-accel hvf`, so the guest's
/// own instructions run on the Mac's cores through Hypervisor.framework rather than being
/// emulated. The display is exported over a VNC Unix socket that only this user can reach,
/// which is also how the VM is driven, so nothing is forwarded into the guest.
///
/// The disk in the app bundle is never written to. QEMU gets a qcow2 overlay in the run
/// directory that is backed by it and recreated on every fresh boot, which is what makes the
/// VM ephemeral: anything the guest writes lives in that overlay and goes away with it.
///
/// On quit the VM can be suspended: QEMU writes its whole state (RAM + devices) to a file
/// with a migration to `file:`, and the next launch resumes it with `-incoming`. The overlay
/// and the UEFI variable store are kept across that pair, since the restored RAM expects the
/// disk exactly as it was, and are only thrown away when the VM next boots for real.
final class VMManager {
    enum VMError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self { case .missing(let what): return what }
        }
    }

    let runDir: URL
    private var process: Process?
    var onExit: ((Int32) -> Void)?
    /// Resuming a saved state finished and the VM is running again
    var onResumed: (() -> Void)?
    /// QEMU couldn't load the saved state (it has been deleted); start() again to boot fresh
    var onRestoreFailed: ((String) -> Void)?

    /// This launch is resuming a saved state rather than booting
    private(set) var resuming = false
    private var restoreConfirmed = false
    /// Identifies the QEMU binary, guest payload and VM config; a saved state only loads into the same
    private var fingerprint = ""

    private struct SavedStateInfo: Codable {
        var fingerprint: String
        var savedAt: Date
    }

    var vncSocketPath: String { runDir.appendingPathComponent("vnc.sock").path }
    /// Backed by the read-only image in the bundle; holds everything the guest writes
    private var overlayURL: URL { runDir.appendingPathComponent("disk.qcow2") }
    /// UEFI's variable store. QEMU needs a writable one, and the guest's bootloader is
    /// installed at the EFI default path so it boots even when this is blank.
    private var efiVarsURL: URL { runDir.appendingPathComponent("efivars.fd") }
    /// Read by the guest out of fw_cfg, so the desktop shows the time on this Mac
    private var timeZoneURL: URL { runDir.appendingPathComponent("timezone") }
    var serialLogURL: URL { runDir.appendingPathComponent("serial.log") }
    var qemuLogURL: URL { runDir.appendingPathComponent("qemu.log") }
    var qmpSocketPath: String { runDir.appendingPathComponent("qmp.sock").path }
    var stateURL: URL { runDir.appendingPathComponent("vmstate") }
    private var stateTmpURL: URL { runDir.appendingPathComponent("vmstate.tmp") }
    private var stateInfoURL: URL { runDir.appendingPathComponent("vmstate.json") }
    var hasSavedState: Bool { FileManager.default.fileExists(atPath: stateURL.path) }
    var isRunning: Bool { process?.isRunning ?? false }

    /// `runDir` is only passed in by tests, so they can exercise the state files without
    /// touching the real run directory (and the VM the person may have suspended in it).
    init(runDir: URL? = nil) {
        if let runDir {
            self.runDir = runDir
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.runDir = support.appendingPathComponent("Novie", isDirectory: true)
    }

    /// QEMU_PATH if set, else the copy build.sh bundles in Contents/MacOS, else Homebrew's
    static func findQEMU() -> String? { find("qemu-system-aarch64", override: "QEMU_PATH") }

    /// qemu-img, which is what creates the overlay the guest writes to
    static func findQEMUImg() -> String? { find("qemu-img", override: "QEMU_IMG_PATH") }

    private static func find(_ tool: String, override: String) -> String? {
        var candidates = [String]()
        if let env = ProcessInfo.processInfo.environment[override] { candidates.append(env) }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: tool) { candidates.append(bundled.path) }
        candidates += ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A file in Contents/Resources, by relative path (so "qemu/edk2-aarch64-code.fd" works)
    private func resource(_ name: String) throws -> String {
        let url = Bundle.main.resourceURL!.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        throw VMError.missing("\(name) is missing from the app bundle. Rebuild with build.sh.")
    }

    func start() throws {
        guard let qemu = Self.findQEMU() else {
            throw VMError.missing("QEMU not found. Rebuild the app with build.sh, or install it with: brew install qemu")
        }
        let disk = try resource("alpine-xfce-aarch64.qcow2")
        let firmware = try resource("qemu/edk2-aarch64-code.fd")

        let fm = FileManager.default
        try fm.createDirectory(at: runDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(atPath: vncSocketPath)
        try? fm.removeItem(atPath: qmpSocketPath)
        // The guest reads this back out of fw_cfg to set its own time zone, since its clock
        // runs in UTC (see guest/overlay/etc/local.d/novie-timezone.start)
        try? Data(TimeZone.current.identifier.utf8).write(to: timeZoneURL)

        // Hardware virtualization, so the cap is the Mac's cores rather than how much
        // emulation it can afford
        let cpus = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
        // The bundled QEMU's firmware/keymaps (Homebrew's QEMU finds its own without -L)
        let dataDir = Bundle.main.resourceURL!.appendingPathComponent("qemu").path
        let arguments = (fm.fileExists(atPath: dataDir) ? ["-L", dataDir] : []) + [
            "-name", "Novie",
            "-machine", "virt",
            // Hypervisor.framework: the aarch64 guest runs on the Mac's own cores. This is
            // the whole reason the guest is aarch64 -- an x86_64 one would be back on TCG.
            "-accel", "hvf",
            "-cpu", "host",  // the only CPU model hvf offers, and the fastest
            "-smp", "\(cpus)",
            "-m", "4096",
            // UEFI: unit 0 is the firmware, unit 1 the variable store it needs to write
            "-drive", "if=pflash,format=raw,unit=0,file=\(firmware),readonly=on",
            "-drive", "if=pflash,format=raw,unit=1,file=\(efiVarsURL.path)",
            // The overlay, not the image in the bundle: see prepareDisks()
            "-drive", "file=\(overlayURL.path),if=virtio,format=qcow2,discard=unmap",
            // The guest's screen. xres/yres become the EDID it reads, which is how Xorg
            // comes up at this size without anything telling it to.
            "-device", "virtio-gpu-pci,xres=1280,yres=800",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",     // the virt machine has no PS/2 keyboard to fall back on
            "-device", "usb-tablet",  // absolute pointer, so host and guest cursors line up
            // User-mode NAT gives the VM internet access. Nothing is forwarded the other
            // way: the VM is driven through QEMU's VNC socket, not over the network.
            "-nic", "user,model=virtio-net-pci",
            // Read-only, and all it carries is the name of a time zone
            "-fw_cfg", "name=opt/novie/timezone,file=\(timeZoneURL.path)",
            "-display", "none",
            "-vnc", "unix:\(vncSocketPath)",
            "-serial", "file:\(serialLogURL.path)",
            // Kept in UTC, which the guest reads at boot with hwclock and chronyd then
            // corrects -- that is also how a resumed VM recovers from its saved clock
            "-rtc", "base=utc",
            // Control socket, used to suspend the VM to a file on quit
            "-qmp", "unix:\(qmpSocketPath),server=on,wait=off",
        ]
        // A saved state only loads into the same binary, image and VM config
        fingerprint = ([qemu, disk, firmware].map(Self.fileStamp) + arguments).joined(separator: "\n")

        // Resume the saved state if it was made by this exact build and config, and the disk
        // overlay it was saved against is still there
        var incoming = [String]()
        resuming = false
        restoreConfirmed = false
        if hasSavedState, fm.fileExists(atPath: overlayURL.path), fm.fileExists(atPath: efiVarsURL.path),
           let data = try? Data(contentsOf: stateInfoURL),
           let info = try? JSONDecoder().decode(SavedStateInfo.self, from: data), info.fingerprint == fingerprint {
            incoming = ["-incoming", "file:\(stateURL.path)"]
            resuming = true
        } else {
            discardSavedState()
        }
        try prepareDisks(base: disk, fresh: !resuming)

        fm.createFile(atPath: qemuLogURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: qemuLogURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: qemu)
        p.arguments = arguments + incoming
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                if self.resuming && !self.restoreConfirmed {
                    // QEMU exits if the state doesn't load (corrupt, incompatible); boot fresh instead
                    self.resuming = false
                    self.process = nil
                    self.discardSavedState()
                    let log = (try? String(contentsOf: self.qemuLogURL, encoding: .utf8)) ?? ""
                    self.onRestoreFailed?(log.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    self.onExit?(proc.terminationStatus)
                }
            }
        }
        try p.run()
        process = p
        if resuming { finishResume(p) }
    }

    /// Gives QEMU the two files it writes: a qcow2 overlay backed by the read-only image in
    /// the app bundle, and a blank UEFI variable store. On a fresh boot both are recreated,
    /// which is what wipes the VM; on a resume both are left exactly as the saved RAM
    /// expects to find them.
    private func prepareDisks(base: String, fresh: Bool) throws {
        let fm = FileManager.default
        guard fresh else { return }
        for url in [overlayURL, efiVarsURL] { try? fm.removeItem(at: url) }

        guard let qemuImg = Self.findQEMUImg() else {
            throw VMError.missing("qemu-img not found. Rebuild the app with build.sh, or install it with: brew install qemu")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: qemuImg)
        p.arguments = ["create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", base, overlayURL.path]
        let errors = Pipe()
        p.standardError = errors
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw VMError.missing("Could not create the VM's disk overlay: "
                + (message.isEmpty ? "qemu-img exited with \(p.terminationStatus)" : message))
        }
        // Whatever the guest writes ends up in the overlay, so keep it to this user
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overlayURL.path)

        // UEFI expects a variable store the same size as the firmware itself (64 MiB), and
        // a blank one is fine: the guest's bootloader sits at the EFI default path.
        guard fm.createFile(atPath: efiVarsURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VMError.missing("Could not create \(efiVarsURL.lastPathComponent) in \(runDir.path)")
        }
        let handle = try FileHandle(forWritingTo: efiVarsURL)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()
    }

    /// A restored VM comes back paused (it was stopped before saving): wait for the state to
    /// load, start it, then delete the file so a crash later means a clean boot, not a stale resume.
    private func finishResume(_ p: Process) {
        let qmpPath = qmpSocketPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(300)
            var resumed = false
            while !resumed, p.isRunning, Date() < deadline {
                guard let qmp = try? QMPClient(path: qmpPath, timeout: 120) else {
                    usleep(200_000)
                    continue
                }
                while p.isRunning, Date() < deadline {
                    guard let status = (try? qmp.execute("query-status"))?["status"] as? String else { break }
                    if status == "running" { resumed = true; break }
                    if status == "paused" || status == "postmigrate" {
                        resumed = (try? qmp.execute("cont")) != nil
                        break
                    }
                    usleep(200_000)  // "inmigrate": still loading
                }
            }
            DispatchQueue.main.async {
                guard let self, resumed, self.process === p else { return }
                self.restoreConfirmed = true
                self.discardSavedState()
                self.onResumed?()
            }
        }
    }

    func discardSavedState() {
        for url in [stateURL, stateTmpURL, stateInfoURL] { try? FileManager.default.removeItem(at: url) }
    }

    /// Saves the VM's state to a file and quits QEMU, so the next start() resumes it.
    /// Falls back to a plain stop if saving fails. `completion` (main queue) gets nil on
    /// success or an error message.
    func suspend(timeout: TimeInterval = 120, completion: @escaping (String?) -> Void) {
        guard let p = process, p.isRunning else {
            completion("The VM isn't running")
            return
        }
        if resuming && !restoreConfirmed {
            // Still loading the previous save: that file is still the latest state, keep it
            stop()
            completion(nil)
            return
        }
        p.terminationHandler = nil
        let info = SavedStateInfo(fingerprint: fingerprint, savedAt: Date())
        let (qmpPath, tmpURL, stateURL, infoURL) = (qmpSocketPath, stateTmpURL, self.stateURL, stateInfoURL)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fm = FileManager.default
            var failure: String?
            do {
                let qmp = try QMPClient(path: qmpPath, timeout: timeout)
                try? fm.removeItem(at: tmpURL)
                try qmp.execute("stop")  // a single consistent pass instead of chasing dirty pages
                try qmp.execute("migrate", ["uri": "file:\(tmpURL.path)"])
                let deadline = Date().addingTimeInterval(timeout)
                while true {
                    let r = try qmp.execute("query-migrate")
                    let status = r["status"] as? String ?? ""
                    if status == "completed" { break }
                    if status == "failed" || status == "cancelled" {
                        throw QMPClient.QMPError(r["error-desc"] as? String ?? "migration \(status)")
                    }
                    if Date() > deadline { throw QMPClient.QMPError("saving the VM timed out") }
                    usleep(100_000)
                }
                // Guest RAM is whatever the person was doing in the VM: keep it to this user
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
                let data = try JSONEncoder().encode(info)
                guard fm.createFile(atPath: infoURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw QMPClient.QMPError("could not write \(infoURL.lastPathComponent)")
                }
                try? fm.removeItem(at: stateURL)
                try fm.moveItem(at: tmpURL, to: stateURL)
                _ = try? qmp.execute("quit")
            } catch {
                failure = error.localizedDescription
                for url in [tmpURL, stateURL, infoURL] { try? fm.removeItem(at: url) }
            }
            Self.terminate(p, signal: failure == nil ? nil : SIGTERM)
            DispatchQueue.main.async {
                if self?.process === p { self?.process = nil }
                completion(failure)
            }
        }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminationHandler = nil
        Self.terminate(p, signal: SIGTERM)  // QEMU exits cleanly on SIGTERM
        process = nil
    }

    /// Sends `signal` (if any), waits up to 5 seconds for the process to exit, then kills it.
    private static func terminate(_ p: Process, signal: Int32?) {
        if let signal, p.isRunning { kill(p.processIdentifier, signal) }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Path, size and modification time: changes whenever build.sh replaces the file
    private static func fileStamp(_ path: String) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path) \(size) \(mtime)"
    }

}
