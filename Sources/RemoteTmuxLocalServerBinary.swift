import Darwin
import Foundation

/// Finds the tmux binary a running local server was started from. Not implemented yet.
enum RemoteTmuxLocalServerBinary {
    static func executable(
        forSocket socketPath: String,
        userID: uid_t = getuid(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? { nil }

    static func serverProcessID(socketPath: String, userID: uid_t = getuid()) -> pid_t? { nil }

    static func executablePath(ofProcess pid: pid_t) -> String? { nil }

    static func release(fromClientVersionOutput output: String) -> String? { nil }

    static func release(fromServerVersionOutput output: String) -> String? { nil }
}
