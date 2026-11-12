import Darwin
import Foundation

/// Bounded off-main writer for the SSH control client's stdin pipe.
///
/// `RemoteTmuxControlConnection` records command FIFO entries on the main actor
/// before this writer can emit bytes, so tmux `%begin`/`%end` replies cannot
/// outrun their local correlation slot. The write itself may block on a stalled
/// SSH pipe; keeping it on this serial queue prevents that from freezing UI.
@MainActor
final class RemoteTmuxControlPipeWriter {
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let maxPendingBytes: Int
    private let onFailure: @MainActor @Sendable () -> Void
    private var closed = false
    private var pendingBytes = 0

    init(
        handle: FileHandle,
        label: String,
        maxPendingBytes: Int,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        self.handle = handle
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
        self.maxPendingBytes = maxPendingBytes
        self.onFailure = onFailure
    }

    func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard !closed,
              data.count <= maxPendingBytes - pendingBytes else {
            return false
        }
        pendingBytes += data.count

        queue.async { [weak self, handle, data] in
            let didFail = !Self.writeAll(data, to: handle.fileDescriptor)
            Task { @MainActor [weak self] in
                self?.finishWrite(byteCount: data.count, didFail: didFail)
            }
        }
        return true
    }

    /// Writes every byte of `data`, or reports failure.
    ///
    /// A descriptor can be non-blocking without this writer choosing it: a local pty's write side
    /// is a duplicate of the master, and the output reader puts the master's shared file
    /// description in non-blocking mode. A full pty buffer then answers `EAGAIN`, which is not a
    /// failure; this waits for the descriptor to drain with `poll`, an event wait on this serial
    /// queue, exactly where a blocking write on a full pipe already waits. A dead peer ends the
    /// wait with `POLLHUP` or `POLLERR`, and the next write reports the error.
    ///
    /// The wait is bounded. A client that is alive but reads nothing, for example one stopped
    /// with SIGSTOP, never drains the pty and never hangs up, so an unbounded wait would hold this
    /// queue, and every write behind it, for as long as the client stays stopped. After
    /// `stallTimeoutMilliseconds` with no room to write, the write fails, and the connection's
    /// existing write-failure handling takes over, so a mirror never wedges and teardown never stalls.
    nonisolated static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        stallTimeoutMilliseconds: Int32 = defaultStallTimeoutMilliseconds
    ) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&request, 1, stallTimeoutMilliseconds)
                if ready == 0 { return false }
                if ready < 0, errno != EINTR { return false }
            }
            return true
        }
    }

    /// How long a write may wait for a client that is not reading before it counts as failed.
    nonisolated static let defaultStallTimeoutMilliseconds: Int32 = 10_000

    private func finishWrite(byteCount: Int, didFail: Bool) {
        pendingBytes = max(0, pendingBytes - byteCount)
        if didFail, !closed {
            onFailure()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        queue.async { [handle] in
            try? handle.close()
        }
    }
}
