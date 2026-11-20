import Foundation

/// How renewing a host's shared ssh connection after wake turned out.
enum RemoteTmuxWakeRenewalResult: Sendable, Equatable {
    /// A fresh master is open and confirmed.
    case renewed
    /// The host could not be reached (a timeout, a refused connection, no route, or a name that
    /// does not resolve). Nothing local announces the host coming back, so the renewal is retried.
    case hostUnreachable
    /// Anything else, such as a host that needs a password, a security-key touch the user
    /// dismissed, or a changed host key. Retrying with the same non-interactive connection cannot
    /// succeed, so the streams go to their own login and end handling instead.
    case failed
}
