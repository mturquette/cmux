import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// T19 (R20): the control socket accepts a local tmux host only as an absolute path to a socket
/// the current user owns, and refuses every parameter that belongs to a remote transport.
///
/// The positive control comes first: a real socket owned by this user must be accepted as a
/// `local` host. Without it, every refusal below would pass on a build that refuses all local
/// hosts, which is exactly a build without the local transport.
@Suite(.serialized) struct RemoteTmuxLocalSocketBoundaryTests {
    private static func noBroker(_ requestedName: String?) -> RemoteTmuxBrokerSelection { .none }

    @Test func acceptsAnAbsoluteSocketOwnedByTheUser() throws {
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        let host = TerminalController.remoteTmuxHost(
            from: ["transport": "local", "socket_path": fixture.socketPath],
            selectBroker: Self.noBroker
        )
        #expect(host != nil)
        #expect(host?.transport.rawValue == "local")
    }

    /// Each case is refused for one reason only: everything else about it is valid.
    @Test(arguments: RemoteTmuxLocalSocketBoundaryTests.RefusalCase.allCases)
    func refuses(_ refusal: RefusalCase) throws {
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        let accepted = TerminalController.remoteTmuxHost(
            from: ["transport": "local", "socket_path": fixture.socketPath],
            selectBroker: Self.noBroker
        )
        try #require(accepted != nil, "positive control: the valid local socket must be accepted first")
        let params = try refusal.params(fixture: fixture)
        #expect(TerminalController.remoteTmuxHost(from: params, selectBroker: Self.noBroker) == nil)
    }

    @Test func refusesABrokerForALocalHost() throws {
        let fixture = try SocketFixture()
        defer { fixture.remove() }
        let broker = RemoteTmuxTransportBroker(executable: "/opt/site/bin/broker", leadingArguments: ["-et"])
        let host = TerminalController.remoteTmuxHost(
            from: ["transport": "local", "socket_path": fixture.socketPath, "transport_broker": "site"],
            selectBroker: { $0 == "site" ? .resolved(broker) : .unknown(name: $0 ?? "") }
        )
        #expect(host == nil)
    }

    @Test(.enabled(if: RemoteTmuxLocalSocketBoundaryTests.SocketFixture.foreignSocketPath != nil))
    func refusesASocketOwnedByAnotherUser() throws {
        let path = try #require(SocketFixture.foreignSocketPath)
        let host = TerminalController.remoteTmuxHost(
            from: ["transport": "local", "socket_path": path],
            selectBroker: Self.noBroker
        )
        #expect(host == nil)
    }

    enum RefusalCase: String, CaseIterable, CustomTestStringConvertible {
        case relativePath
        case controlCharacter
        case newline
        case hiddenCharacter
        case regularFile
        case directory
        case missingPath
        case hostWithLocal
        case port
        case identityFile
        case transportPort
        case helperPath

        var testDescription: String { rawValue }

        func params(fixture: SocketFixture) throws -> [String: Any] {
            let valid: [String: Any] = ["transport": "local", "socket_path": fixture.socketPath]
            func with(_ key: String, _ value: Any) -> [String: Any] {
                var params = valid
                params[key] = value
                return params
            }
            switch self {
            case .relativePath:
                return with("socket_path", (fixture.socketPath as NSString).lastPathComponent)
            case .controlCharacter:
                return with("socket_path", try fixture.boundSocket(named: "ctl\u{07}char"))
            case .newline:
                return with("socket_path", try fixture.boundSocket(named: "new\nline"))
            case .hiddenCharacter:
                return with("socket_path", try fixture.boundSocket(named: "zero\u{200B}width"))
            case .regularFile:
                return with("socket_path", try fixture.regularFile())
            case .directory:
                return with("socket_path", fixture.directory)
            case .missingPath:
                return with("socket_path", fixture.directory + "/absent.sock")
            case .hostWithLocal:
                return with("host", "localhost")
            case .port:
                return with("port", 22)
            case .identityFile:
                return with("identity_file", NSHomeDirectory() + "/.ssh/id_ed25519")
            case .transportPort:
                return with("transport_port", 2022)
            case .helperPath:
                return with("transport_helper_path", "/bin/sh")
            }
        }
    }

    /// A private directory in /tmp holding a listening unix socket owned by this user.
    struct SocketFixture {
        let directory: String
        let socketPath: String
        private let descriptor: Int32

        /// A socket on this Mac that belongs to another user (root), if there is one.
        static var foreignSocketPath: String? {
            let path = "/var/run/mDNSResponder"
            var info = stat()
            guard lstat(path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFSOCK,
                  info.st_uid != getuid()
            else { return nil }
            return path
        }

        init() throws {
            // /tmp, not NSTemporaryDirectory(): a unix socket path is capped at 104 bytes.
            var template = Array("/tmp/cmux-lsb.XXXXXX".utf8CString)
            guard let created = mkdtemp(&template) else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            directory = String(cString: created)
            socketPath = directory + "/s.sock"
            descriptor = try Self.bind(socketPath)
        }

        func boundSocket(named name: String) throws -> String {
            let path = directory + "/" + name
            let fd = try Self.bind(path)
            Darwin.close(fd)
            return path
        }

        func regularFile() throws -> String {
            let path = directory + "/regular"
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                throw POSIXError(.EIO)
            }
            return path
        }

        func remove() {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: directory)
        }

        private static func bind(_ path: String) throws -> Int32 {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let bytes = Array(path.utf8)
            guard bytes.count < capacity else {
                Darwin.close(fd)
                throw POSIXError(.ENAMETOOLONG)
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                    for (index, byte) in bytes.enumerated() {
                        buffer[index] = CChar(bitPattern: byte)
                    }
                    buffer[bytes.count] = 0
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 1) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            return fd
        }
    }
}
