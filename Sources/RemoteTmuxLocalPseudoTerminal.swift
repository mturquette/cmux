import Darwin
import Foundation

/// A pseudo-terminal that cmux allocates itself for a local `tmux -CC` control client.
///
/// tmux control mode needs a terminal on stdin: on a plain pipe the client exits with
/// `tcgetattr failed: Inappropriate ioctl for device`. The ssh and et transports get one from the
/// far side or from `/usr/bin/script`. A local client is spawned directly on this pty's slave
/// instead, for one measured reason: when cmux dies (a crash or a force-quit), the kernel closes
/// the master, the client reads end-of-file at once and tmux drops it. Under `script(1)` the
/// client stayed attached until its pane next printed, and while it is attached its size claims
/// limit every other client of that session.
///
/// The child gets the slave as stdin and stdout. stderr stays a separate pipe, so the existing
/// classification of tmux's error messages keeps working. The slave is put in raw mode before
/// launch, so nothing cmux writes is echoed back into the parser and `\n` is never rewritten as
/// `\r\n`.
///
/// Every descriptor is close-on-exec from the moment it exists, so no other child cmux spawns can
/// inherit one and hold the pty open after the client exits. Foundation `Process` duplicates the
/// slave onto the child's stdin and stdout itself, which clears the flag on those copies only.
///
/// Allocation and raw-mode setup are adapted from the local pty in PR #8421 by naveengovind.
struct RemoteTmuxLocalPseudoTerminal {
    /// Which system call failed while the pty was being set up.
    enum SetupStep: String, Sendable, Equatable {
        case openpty
        case closeOnExec
        case getAttributes
        case setAttributes
        case duplicateMaster
    }

    /// A pty that could not be set up. Every descriptor opened before the failure is closed.
    struct SetupError: Error, Sendable, Equatable, CustomStringConvertible {
        /// The call that failed.
        let step: SetupStep
        /// The `errno` it reported.
        let code: Int32

        var description: String {
            "\(step.rawValue): \(String(cString: strerror(code)))"
        }
    }

    /// Reads the client's output. Owns the master descriptor.
    let masterReadHandle: FileHandle

    /// Writes commands to the client. Owns a duplicate of the master, so the reader and the writer
    /// can each close their own descriptor without closing the other's.
    let masterWriteHandle: FileHandle

    /// The child's stdin and stdout. The caller closes it right after launch, so that the master
    /// sees end-of-file as soon as the child exits.
    let slaveHandle: FileHandle

    /// Opens a raw-mode pty of the given size.
    ///
    /// - Throws: ``SetupError`` naming the failed call, after closing every descriptor it opened.
    init(columns: UInt16 = 80, rows: UInt16 = 24) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        // The size goes in with the allocation, so there is no separate TIOCSWINSZ to check.
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw SetupError(step: .openpty, code: errno)
        }
        var opened = [master, slave]
        func failure(_ step: SetupStep) -> SetupError {
            let code = errno
            for descriptor in opened { Darwin.close(descriptor) }
            return SetupError(step: step, code: code)
        }

        // Unavoidable window: between openpty returning and these two calls, a child spawned by
        // another thread can inherit both descriptors. The leak tests (T16, A6) cover it.
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(slave, F_SETFD, FD_CLOEXEC) == 0
        else { throw failure(.closeOnExec) }

        var attributes = termios()
        guard tcgetattr(slave, &attributes) == 0 else { throw failure(.getAttributes) }
        cfmakeraw(&attributes)
        guard tcsetattr(slave, TCSANOW, &attributes) == 0 else { throw failure(.setAttributes) }

        // F_DUPFD_CLOEXEC sets the flag in the same call, so the duplicate has no window at all.
        let writeDescriptor = fcntl(master, F_DUPFD_CLOEXEC, 0)
        guard writeDescriptor >= 0 else { throw failure(.duplicateMaster) }
        opened.append(writeDescriptor)

        masterReadHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        masterWriteHandle = FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: true)
        slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    }
}
