import Glibc
import InzoneCore

/// Interactive children need terminal ownership even when their standard input is inherited.
final class ForegroundTerminal {
    private let descriptor: Int32
    private let originalGroup: pid_t
    private var originalAttributes: termios
    private var transferred = false

    init?() throws {
        let descriptor = Glibc.open("/dev/tty", O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ENXIO || code == ENODEV || code == ENOTTY { return nil }
            throw Self.failure("Open controlling terminal", code)
        }
        let group = tcgetpgrp(descriptor)
        guard group >= 0 else {
            let code = errno
            Glibc.close(descriptor)
            throw Self.failure("Read terminal foreground group", code)
        }
        guard group == getpgrp() else {
            Glibc.close(descriptor)
            throw InzoneError.message("Run the installation in the foreground to enter an administrator password.")
        }
        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else {
            let code = errno
            Glibc.close(descriptor)
            throw Self.failure("Read terminal input settings", code)
        }
        self.descriptor = descriptor
        originalGroup = group
        originalAttributes = attributes
    }

    deinit {
        try? restore()
        Glibc.close(descriptor)
    }

    func transfer(to process: pid_t) throws {
        transferred = true
        let group = getpgid(process)
        if group < 0 && errno == ESRCH { return }
        if group == originalGroup { return }
        guard group == process else {
            throw InzoneError.message("The interactive command has no independent process group.")
        }
        try withTerminalSignalsBlocked {
            guard tcsetpgrp(descriptor, group) == 0 else {
                let code = errno
                // The process group can disappear between lookup and terminal ownership transfer.
                if getpgid(process) < 0 && errno == ESRCH { return }
                throw Self.failure("Give command terminal ownership", code)
            }
            // A fast child may have stopped on terminal input before the handoff completed.
            if Glibc.kill(-group, SIGCONT) != 0 && errno != ESRCH {
                throw Self.failure("Resume interactive command", errno)
            }
        }
    }

    func restore() throws {
        guard transferred else { return }
        try withTerminalSignalsBlocked {
            guard tcsetpgrp(descriptor, originalGroup) == 0 else {
                throw Self.failure("Restore terminal ownership", errno)
            }
            // A timed-out password reader may exit before it restores echo and canonical input.
            guard tcsetattr(descriptor, TCSANOW, &originalAttributes) == 0 else {
                throw Self.failure("Restore terminal input settings", errno)
            }
            transferred = false
        }
    }

    private func withTerminalSignalsBlocked(_ operation: () throws -> Void) throws {
        var blocked = sigset_t()
        var previous = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGTTOU)
        let result = pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        guard result == 0 else { throw Self.failure("Protect terminal ownership change", result) }
        defer { _ = pthread_sigmask(SIG_SETMASK, &previous, nil) }
        try operation()
    }

    private static func failure(_ operation: String, _ code: Int32) -> InzoneError {
        .message("\(operation): \(String(cString: strerror(code))).")
    }
}
