import Foundation

func vmManagerTests(_ t: TestRunner) {

    t.suite("VMManager: the run directory defaults to Application Support/Novie") {
        let vm = VMManager()
        t.equal(vm.runDir.lastPathComponent, "Novie", "the directory is named after the app")
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        t.equal(vm.runDir.deletingLastPathComponent().path, support.path,
                "and sits in Application Support")
    }

    t.suite("VMManager: every runtime file sits in the run directory") {
        let dir = TempDir("vm")
        defer { dir.cleanup() }
        let vm = VMManager(runDir: dir.url)
        t.equal(vm.vncSocketPath, dir.path("vnc.sock"), "the VNC socket the display uses")
        t.equal(vm.qmpSocketPath, dir.path("qmp.sock"), "QEMU's control socket")
        t.equal(vm.serialLogURL.path, dir.path("serial.log"), "the guest console log")
        t.equal(vm.qemuLogURL.path, dir.path("qemu.log"), "QEMU's own log")
        t.equal(vm.stateURL.path, dir.path("vmstate"), "the suspended VM state")
    }

    t.suite("VMManager: a fresh manager isn't running and isn't resuming") {
        let dir = TempDir("vm")
        defer { dir.cleanup() }
        let vm = VMManager(runDir: dir.url)
        t.equal(vm.isRunning, false, "nothing has been started")
        t.equal(vm.resuming, false, "and nothing is being resumed")
    }

    t.suite("VMManager: hasSavedState follows the state file") {
        let dir = TempDir("vm")
        defer { dir.cleanup() }
        let vm = VMManager(runDir: dir.url)
        t.equal(vm.hasSavedState, false, "an empty run directory has no saved state")
        FileManager.default.createFile(atPath: dir.path("vmstate"), contents: Data("ram".utf8))
        t.equal(vm.hasSavedState, true, "once the file is there, there is state to resume")
    }

    t.suite("VMManager: discarding the saved state leaves the disk overlay alone") {
        // Restart VM and a rebuild throw the state away, but the overlay is a separate
        // decision: deleting it here would wipe a VM that was only meant to boot fresh.
        let dir = TempDir("vm")
        defer { dir.cleanup() }
        let vm = VMManager(runDir: dir.url)
        let fm = FileManager.default
        for name in ["vmstate", "vmstate.tmp", "vmstate.json", "disk.qcow2", "efivars.fd"] {
            fm.createFile(atPath: dir.path(name), contents: Data("x".utf8))
        }
        vm.discardSavedState()
        t.equal(fm.fileExists(atPath: dir.path("vmstate")), false, "the state file goes")
        t.equal(fm.fileExists(atPath: dir.path("vmstate.tmp")), false, "the half-written one too")
        t.equal(fm.fileExists(atPath: dir.path("vmstate.json")), false, "and its fingerprint")
        t.equal(fm.fileExists(atPath: dir.path("disk.qcow2")), true, "the disk overlay stays")
        t.equal(fm.fileExists(atPath: dir.path("efivars.fd")), true, "and so does the UEFI store")
        t.equal(vm.hasSavedState, false, "and there is no saved state left")
    }

    t.suite("VMManager: discarding state that isn't there is harmless") {
        let dir = TempDir("vm")
        defer { dir.cleanup() }
        let vm = VMManager(runDir: dir.url)
        vm.discardSavedState()
        vm.discardSavedState()
        t.equal(vm.hasSavedState, false, "calling it twice on nothing should be a no-op")
    }

    t.suite("VMManager: suspending a VM that isn't running says so") {
        let dir = TempDir("vm")
        defer { dir.cleanup() }
        let vm = VMManager(runDir: dir.url)
        let answer = Mailbox<String?>()
        vm.suspend(timeout: 1) { answer.put($0) }
        t.expect(answer.wait(5), "the completion should be called")
        t.equal(answer.value ?? nil, "The VM isn't running",
                "and explain there was nothing to save")
        t.equal(FileManager.default.fileExists(atPath: dir.path("vmstate")), false,
                "with no state file written")
    }

    t.suite("VMManager: stopping a VM that isn't running is harmless") {
        let dir = TempDir("vm")
        defer { dir.cleanup() }
        let vm = VMManager(runDir: dir.url)
        vm.stop()
        vm.stop()
        t.equal(vm.isRunning, false, "stopping nothing shouldn't crash or start anything")
    }

    t.suite("VMManager: a missing-file error describes what's missing") {
        let error = VMManager.VMError.missing("QEMU not found. Rebuild the app with build.sh")
        t.equal(error.errorDescription, "QEMU not found. Rebuild the app with build.sh",
                "the message is the description")
        t.equal(error.localizedDescription, "QEMU not found. Rebuild the app with build.sh",
                "and the localized one")
    }

    t.suite("VMManager: QEMU is looked up by the override, then the bundle, then Homebrew") {
        let dir = TempDir("qe")
        defer { dir.cleanup() }
        // An executable file at the override path wins over everything else
        let fake = dir.path("qemu-system-aarch64")
        FileManager.default.createFile(atPath: fake, contents: Data("#!/bin/sh\n".utf8),
                                      attributes: [.posixPermissions: 0o755])
        setenv("QEMU_PATH", fake, 1)
        defer { unsetenv("QEMU_PATH") }
        t.equal(VMManager.findQEMU(), fake, "QEMU_PATH should be preferred")

        // A path that isn't executable is skipped, so the search falls through
        let notExecutable = dir.path("not-executable")
        FileManager.default.createFile(atPath: notExecutable, contents: Data(),
                                      attributes: [.posixPermissions: 0o644])
        setenv("QEMU_PATH", notExecutable, 1)
        let found = VMManager.findQEMU()
        t.expect(found != notExecutable,
                 "a non-executable override should be skipped, got \(String(describing: found))")
    }

    t.suite("VMManager: qemu-img is looked up the same way") {
        let dir = TempDir("qi")
        defer { dir.cleanup() }
        let fake = dir.path("qemu-img")
        FileManager.default.createFile(atPath: fake, contents: Data("#!/bin/sh\n".utf8),
                                      attributes: [.posixPermissions: 0o755])
        setenv("QEMU_IMG_PATH", fake, 1)
        defer { unsetenv("QEMU_IMG_PATH") }
        t.equal(VMManager.findQEMUImg(), fake, "QEMU_IMG_PATH should be preferred")
    }

    t.suite("VMManager: with no override, the search finds whatever is installed or nothing") {
        unsetenv("QEMU_PATH")
        unsetenv("QEMU_IMG_PATH")
        // The test binary has no app bundle, so this is Homebrew's copy or nil. Either is
        // correct; what matters is that it only ever returns something runnable.
        if let qemu = VMManager.findQEMU() {
            t.expect(FileManager.default.isExecutableFile(atPath: qemu),
                     "a returned path must be executable, got \(qemu)")
        } else {
            t.expect(true, "nothing installed is a valid answer")
        }
        if let img = VMManager.findQEMUImg() {
            t.expect(FileManager.default.isExecutableFile(atPath: img),
                     "a returned path must be executable, got \(img)")
        } else {
            t.expect(true, "nothing installed is a valid answer")
        }
    }
}

/// A one-shot slot for a value delivered from another queue, so a test can wait for a
/// completion handler without blocking the queue that calls it.
final class Mailbox<T> {
    private var stored: T?
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    func put(_ value: T) {
        lock.lock(); stored = value; lock.unlock()
        gate.signal()
    }

    @discardableResult
    func wait(_ timeout: TimeInterval) -> Bool {
        gate.wait(timeout: .now() + timeout) == .success
    }

    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}
