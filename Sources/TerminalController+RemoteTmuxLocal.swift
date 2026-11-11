import Foundation

/// The socket boundary for `transport: "local"` hosts.
///
/// A local host is named by one parameter, `socket_path`, which the CLI resolved from the caller's
/// shell. Everything that describes how to reach a remote machine is refused rather than ignored,
/// so a caller who mixed up the two transports is told which parameter does not belong.
extension TerminalController {
    /// Parameters that only make sense for a host reached over the network.
    nonisolated static let remoteTmuxLocalRefusedParameters = [
        "host", "port", "identity_file", "transport_port", "transport_broker", "transport_helper_path",
    ]

    /// Builds a local host from socket params, or says why not.
    ///
    /// - Parameter userID: the user the socket must belong to; tests pass another to fake a socket
    ///   owned by someone else.
    nonisolated static func remoteTmuxLocalHostResult(
        from params: [String: Any],
        userID: uid_t = getuid()
    ) -> Result<RemoteTmuxHost, RemoteTmuxLocalServerSocket.Refusal> {
        if let refused = remoteTmuxLocalRefusedParameters.first(where: { params[$0] != nil }) {
            return .failure(.parameterNotAllowed(name: refused))
        }
        guard let rawPath = params["socket_path"] as? String, !rawPath.isEmpty else {
            return .failure(.socketPathRequired)
        }
        do {
            let socket = try RemoteTmuxLocalServerSocket(validating: rawPath, userID: userID)
            return .success(RemoteTmuxHost.local(serverSocketPath: socket.path))
        } catch let refusal as RemoteTmuxLocalServerSocket.Refusal {
            return .failure(refusal)
        } catch {
            return .failure(.missing(path: rawPath))
        }
    }
}
