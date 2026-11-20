import Foundation

/// Runs commands against a remote host's tmux server over a shared SSH
/// ControlMaster connection.
///
/// This is the non-interactive half of the remote-tmux feature: session
/// discovery (`tmux list-sessions`) and one-shot mutations (`new-session`,
/// `new-window`, `split-window`, `kill-*`, `send-keys`). The latency-sensitive
/// `tmux -CC` control stream is NOT run here — it runs in a ghostty surface so
/// it gets a PTY. Both share the same ControlMaster socket
/// (``RemoteTmuxHost/controlSocketPath``), so the first to connect authenticates
/// and the rest are subsecond.
///
/// Modeled as an `actor` because it owns the per-host connection lifecycle and
/// serializes process launches; reads/writes are `async`.
actor RemoteTmuxSSHTransport {
    private static let maxCapturedOutputBytes = 1_048_576

    /// The host this transport talks to.
    ///
    /// `nonisolated` so the controller can read it synchronously (it's an immutable
    /// `Sendable` value) when tearing down masters on quit/window-close.
    nonisolated let host: RemoteTmuxHost

    /// How this host's one-shots are carried, and whether it has a shared master at all.
    ///
    /// `nonisolated` for the same reason as ``host``: an immutable `Sendable` value.
    nonisolated let transportProfile: RemoteTmuxTransportProfile

    /// The `ssh` that answers `-O check` and `-O exit` against the shared master.
    private let sshExecutablePath: String

    /// The binary that runs one-shot commands with the profile's argv.
    private let oneShotExecutablePath: String

    /// How long a one-shot may run, from the profile unless a caller overrides it.
    private let oneShotDeadline: Duration?

    /// In-flight shared-master warmup, if any. ``ensureMasterReady()`` funnels every
    /// concurrent caller through this single task so the master is opened at most
    /// once even though the actor is reentrant across awaits (see that method).
    private var readinessTask: Task<Bool, Error>?

    /// - Parameters:
    ///   - host: the remote destination.
    ///   - sshExecutablePath: replaces the `ssh` binary for one-shots and master control
    ///     (tests inject a fake). `nil` uses the profile's one-shot binary.
    ///   - transportProfile: overrides the host's profile (tests use it to exercise the seam
    ///     without a real transport). `nil` uses ``RemoteTmuxHost/transportProfile``.
    ///   - oneShotDeadline: overrides the profile's ``RemoteTmuxTransportProfile/oneShotDeadline``,
    ///     so a test can exercise the deadline in milliseconds. `nil` uses the profile's.
    init(
        host: RemoteTmuxHost,
        sshExecutablePath: String? = nil,
        transportProfile: RemoteTmuxTransportProfile? = nil,
        oneShotDeadline: Duration? = nil
    ) {
        let profile = transportProfile ?? host.transportProfile
        self.host = host
        self.transportProfile = profile
        self.sshExecutablePath = sshExecutablePath ?? RemoteTmuxHost.defaultSSHExecutablePath()
        self.oneShotExecutablePath = sshExecutablePath ?? profile.oneShotExecutablePath()
        self.oneShotDeadline = oneShotDeadline ?? profile.oneShotDeadline
    }

    // MARK: - High-level tmux operations

    /// Lists the tmux sessions on the remote server.
    ///
    /// Returns an empty array when the remote tmux server is not running yet
    /// (cmux treats "no server running" / "no sessions" as zero sessions, not
    /// an error, so the sidebar can still offer to create one).
    func listSessions() async throws -> [RemoteTmuxSession] {
        let result = try await runTmux([
            "list-sessions", "-F", RemoteTmuxSessionListParser.formatString,
        ])
        if !result.succeeded {
            if Self.indicatesAuthRequired(result.stderr) {
                throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            if Self.indicatesNoServer(result.stderr) { return [] }
            throw commandFailure(result)
        }
        return RemoteTmuxSessionListParser.parse(result.stdout)
    }

    /// Probes the remote tmux client version via `tmux -V`.
    ///
    /// - Returns: the parsed version, or `nil` when `tmux -V` succeeds but its
    ///   output has no `<major>.<minor>` (a dev/distro build like `tmux master`),
    ///   which callers treat as "unknown, allow".
    /// - Throws: ``RemoteTmuxError/commandFailed`` when the command itself fails, or
    ///   ``RemoteTmuxError/tmuxNotFound(destination:)`` when `tmux` is not installed.
    func tmuxClientVersion() async throws -> RemoteTmuxVersion? {
        let result = try await run(["tmux", "-V"])
        guard result.succeeded else {
            throw commandFailure(result)
        }
        return RemoteTmuxVersion.parse(result.stdout)
    }

    /// Probes the running tmux server version via the server's `#{version}` format.
    private func tmuxServerVersionProbe() async throws -> (
        serverExists: Bool, version: RemoteTmuxVersion?, release: String?
    ) {
        let result = try await runTmux(["display-message", "-p", "#{version}"])
        guard result.succeeded else {
            if Self.indicatesNoServer(result.stderr) { return (serverExists: false, version: nil, release: nil) }
            throw commandFailure(result)
        }
        return (
            serverExists: true,
            version: RemoteTmuxVersion.parseServerFormat(result.stdout),
            release: RemoteTmuxLocalServerBinary.release(fromServerVersionOutput: result.stdout)
        )
    }

    /// Probes the live-subscription capability directly when server version text
    /// is unparseable. New tmux recognizes `-B` but may fail with "no current
    /// client" outside control mode; old tmux rejects the flag itself.
    private func serverSupportsRefreshClientSubscriptions() async throws -> Bool {
        let result = try await runTmux(["refresh-client", "-B", "cmux_probe::#{version}"])
        if result.succeeded { return true }
        if Self.indicatesRefreshClientSubscriptionUnsupported(result.stderr) { return false }
        if Self.indicatesRefreshClientNeedsCurrentClient(result.stderr) { return true }
        throw commandFailure(result)
    }

    /// Asserts that the remote server supports live mirroring.
    ///
    /// Call this before any `tmux -CC` control stream can launch. An unparseable
    /// running-server version falls back to a direct `refresh-client -B`
    /// capability probe so dev/distro builds are treated consistently with the
    /// cold-start path while old servers still fail before attach.
    /// When no server is running, pass `true` only for paths that will create one;
    /// those paths gate on the tmux client binary that will become the new server.
    func assertMinimumTmuxVersion(checkClientWhenNoServer: Bool) async throws {
        let serverProbe = try await tmuxServerVersionProbe()
        if serverProbe.serverExists {
            guard let version = serverProbe.version else {
                if try await serverSupportsRefreshClientSubscriptions() {
                    try await assertClientMatchesServer(release: serverProbe.release)
                    return
                }
                throw RemoteTmuxError.unsupportedTmux(detected: RemoteTmuxError.unknownVersionDisplayName)
            }
            try assertSupportedTmuxVersion(version)
            try await assertClientMatchesServer(release: serverProbe.release)
            return
        }
        guard checkClientWhenNoServer else { return }
        if let version = try await tmuxClientVersion() {
            try assertSupportedTmuxVersion(version)
        }
    }

    /// Makes sure the tmux client this transport will run is the build the running server runs,
    /// for a transport that compares them (``RemoteTmuxTransportProfile/comparesClientRelease``).
    ///
    /// Nothing runs for ssh and et. With no server running there is nothing to compare.
    func assertClientMatchesServer() async throws {
        guard transportProfile.comparesClientRelease else { return }
        let serverProbe = try await tmuxServerVersionProbe()
        guard serverProbe.serverExists else { return }
        try await assertClientMatchesServer(release: serverProbe.release)
    }

    /// The client is the server's own binary when running it with `-V` prints the server's release.
    /// That check, made once per server process, rules out a pid that now names another program
    /// and a binary rebuilt in place as another release.
    ///
    /// Otherwise the client is the resolver's tmux, which must be exactly the server's release:
    /// tmux 3.2a and 3.6a share protocol version 8, and control mode still fails between them.
    private func assertClientMatchesServer(release server: String?) async throws {
        guard transportProfile.comparesClientRelease else { return }
        if let candidate = transportProfile.serverTmuxCandidate(host: host) {
            if try await serverBinaryPrintsServerRelease(candidate, server: server) { return }
        }
        // The resolver's tmux, which is what the control stream runs without a checked server binary.
        let resolved = try await runRemoteCommand(RemoteTmuxHost.tmuxResolutionProbeCommand)
        guard resolved.succeeded else { throw commandFailure(resolved) }
        let unknown = RemoteTmuxError.unknownVersionDisplayName
        // Everything below comes from binaries cmux does not trust and may reach the user's
        // terminal through the CLI, so only a plain path and a release-shaped version are kept.
        guard let clientPath = RemoteTmuxLocalServerBinary.displayablePath(resolved.stdout) else {
            throw transportProfile.clientVersionMismatchError(
                host: host, server: server ?? unknown, client: unknown, clientPath: unknown)
        }
        let result = try await runRemoteCommand(Self.execCommand(clientPath, ["-V"]))
        let client = result.succeeded
            ? RemoteTmuxLocalServerBinary.release(fromClientVersionOutput: result.stdout) : nil
        if let server, let client, server == client { return }
        throw transportProfile.clientVersionMismatchError(
            host: host, server: server ?? unknown, client: client ?? unknown, clientPath: clientPath)
    }

    /// Runs `candidate` once with `-V`, unless an earlier attach to the same server process already
    /// did, and records whether it printed `server`.
    private func serverBinaryPrintsServerRelease(
        _ candidate: RemoteTmuxServerBinaryCandidate, server: String?
    ) async throws -> Bool {
        if let known = transportProfile.serverTmuxVerification(candidate) { return known }
        // A file that is not tmux may fail, print anything, or run until the one-shot deadline.
        // Each of those simply means it is not the server's binary.
        let output: String?
        do {
            let result = try await runRemoteCommand(Self.execCommand(candidate.path, ["-V"]))
            output = result.succeeded ? result.stdout : nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            output = nil
        }
        let release = output.flatMap(RemoteTmuxLocalServerBinary.release(fromClientVersionOutput:))
        let matches = server != nil && release == server
        transportProfile.recordServerTmuxVerification(candidate, matchesServer: matches)
        return matches
    }

    /// `exec '<path>' '<argument>'…`, with every word quoted for the shell.
    private static func execCommand(_ path: String, _ arguments: [String]) -> String {
        "exec " + ([path] + arguments).map(RemoteTmuxHost.shellSingleQuoted).joined(separator: " ")
    }

    private func assertSupportedTmuxVersion(_ version: RemoteTmuxVersion) throws {
        if !version.meetsMinimum {
            throw RemoteTmuxError.unsupportedTmux(detected: version.displayString)
        }
    }

    /// Asserts that the remote server supports live mirroring, then discovers sessions.
    func discoverMirrorSessions(createIfEmpty: Bool) async throws -> [RemoteTmuxSession] {
        try await assertMinimumTmuxVersion(checkClientWhenNoServer: createIfEmpty)
        var sessions = try await listSessions()
        if sessions.isEmpty, createIfEmpty {
            if let refusal = transportProfile.emptyServerRefusal(host: host) { throw refusal }
            // Only ssh and et get here: a transport that refuses an empty server returned above.
            _ = try? await runTmux(["new-session", "-d"])
            sessions = try await listSessions()
        }
        return sessions
    }

    /// The `new-session` arguments for a detached session that cmux's UI creates, printing the
    /// name tmux gave it. The profile adds where it starts (the home directory for a local server,
    /// since the app's own working directory means nothing to the user).
    nonisolated func detachedSessionArguments(name: String, columns: Int, rows: Int) -> [String] {
        ["new-session", "-d", "-s", name, "-x", "\(columns)", "-y", "\(rows)"]
            + transportProfile.appCreatedSessionArguments()
            + ["-P", "-F", "#{session_name}"]
    }

    /// Runs a `tmux <args…>` command on the remote host and returns its result.
    @discardableResult
    func runTmux(_ args: [String]) async throws -> RemoteTmuxCommandResult {
        try await run(["tmux"] + args)
    }

    /// Runs an arbitrary remote command the way the host's transport profile says.
    ///
    /// The remote command is one shell string. `ssh` concatenates the
    /// post-destination argv with spaces and the remote login shell re-splits
    /// the result, so each remote token is single-quoted here; otherwise
    /// whitespace inside an argument (e.g. the tabs in a `list-sessions -F`
    /// format string) would be word-split on the remote. A leading literal
    /// `tmux` is the `runTmux(_:)` contract and selects the tmux resolver;
    /// other commands are treated as explicit remote argv.
    ///
    /// The profile supplies the executable and argv
    /// (``RemoteTmuxTransportProfile/oneShotArgv(host:remoteCommand:)``), so the
    /// transport never builds an ssh command line itself.
    @discardableResult
    func run(_ remoteArgs: [String]) async throws -> RemoteTmuxCommandResult {
        // Before the command is built: building it may look at the server behind the socket.
        if let refusal = transportProfile.refusalBeforeSpawn(host: host) { throw refusal }
        let remoteCommand: String
        if remoteArgs.first == "tmux" {
            remoteCommand = transportProfile.tmuxOneShotCommand(host: host, arguments: Array(remoteArgs.dropFirst()))
        } else {
            remoteCommand = remoteArgs
                .map { RemoteTmuxHost.shellSingleQuoted($0) }
                .joined(separator: " ")
        }
        return try await runRemoteCommand(remoteCommand, socketChecked: true)
    }

    /// Runs one already-built remote command string the way the host's transport profile says.
    private func runRemoteCommand(
        _ remoteCommand: String, socketChecked: Bool = false
    ) async throws -> RemoteTmuxCommandResult {
        if !socketChecked, let refusal = transportProfile.refusalBeforeSpawn(host: host) { throw refusal }
        if transportProfile.usesSharedControlMaster {
            try host.ensureControlSocketDirectory()
        }
        let executable = oneShotExecutablePath
        let arguments = transportProfile.oneShotArgv(host: host, remoteCommand: remoteCommand)
        let environment = transportProfile.oneShotEnvironment(inheriting: ProcessInfo.processInfo.environment)
        guard let deadline = oneShotDeadline else {
            return try await Self.runProcess(executable: executable, arguments: arguments, environment: environment)
        }
        return try await Self.runOneShotBeforeDeadline(
            executable: executable,
            arguments: arguments,
            environment: environment,
            deadline: deadline,
            timeoutError: transportProfile.oneShotTimeoutError(host: host)
        )
    }

    /// Runs a one-shot that must finish before `deadline`.
    ///
    /// A deadline, not a poll: the command and a single sleep race, the first to finish wins, and
    /// cancelling the loser stops the process through `runProcess`'s cancellation handler. It
    /// exists for transports with no timeout of their own: ssh has `ConnectTimeout` and
    /// `ServerAlive*`, while a local tmux client facing a stopped server waits forever, and
    /// the app would keep one such process per call.
    private static func runOneShotBeforeDeadline(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        deadline: Duration,
        timeoutError: RemoteTmuxError
    ) async throws -> RemoteTmuxCommandResult {
        try await withThrowingTaskGroup(of: RemoteTmuxCommandResult?.self) { group in
            group.addTask {
                try await Self.runProcess(executable: executable, arguments: arguments, environment: environment)
            }
            group.addTask {
                try await ContinuousClock().sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw timeoutError }
            return result
        }
    }

    /// Opens the shared SSH ControlMaster (if it isn't already up) and confirms it
    /// accepts multiplexed sessions, so the burst of `tmux -CC attach` connections
    /// the controller fires next — each `ControlMaster=auto`
    /// (``RemoteTmuxHost/controlModeArguments``) — rides a *ready* master instead of
    /// all racing to create one at the same `ControlPath`.
    ///
    /// On a cold first attach with many sessions, that creation race makes
    /// all-but-one connection fail with "ControlSocket … already exists, disabling
    /// multiplexing", so only one or two sessions mirror (#6732). Even discovery
    /// (which opens the master implicitly) leaves a brief background hand-off window
    /// where the socket exists but isn't yet accepting sessions; `ssh -O check` is
    /// the authoritative "ready now" signal that closes it.
    ///
    /// Idempotent: returns `true` at once when a master is already live (warm path);
    /// otherwise opens it exactly once with `run(["true"])` — a single connection
    /// can't lose the creation race — and then confirms with one authoritative
    /// `ssh -O check` (a non-multiplexed fallback can make `run` succeed without a
    /// live master, so the open's exit code is not trusted). A single mux-socket
    /// query, never a timer or poll. Returns `false` only when readiness can't be
    /// confirmed; the controller fails closed on `false` (aborts the burst rather
    /// than racing the cold master).
    ///
    /// Single-flight: the actor is reentrant across `await`, so two concurrent
    /// bulk-mirror callers for the same host (e.g. a dedicated-window attach and a
    /// `remote.tmux.mirror` socket call) could otherwise both observe no master and
    /// both open it, recreating the race. Every caller shares one in-flight
    /// ``readinessTask``; the check-create-store below is a single synchronous actor
    /// step (no `await` between them), so only one caller becomes the creator.
    ///
    /// Not cancellation-aware by itself: the shared warmup is unstructured and
    /// bounded by `ConnectTimeout`, so a cancelled caller awaits its completion
    /// rather than tearing it down for the others. Callers that must bail re-check
    /// `Task.checkCancellation()` after this — as the controller does before
    /// creating the dedicated window.
    ///
    /// A transport whose profile has no shared master is always ready: there is
    /// nothing to warm, and no socket whose absence would mean "not yet".
    @discardableResult
    func ensureMasterReady() async throws -> Bool {
        guard transportProfile.usesSharedControlMaster else { return true }
        if let existing = readinessTask {
            return try await existing.value
        }
        let task = Task { try await self.performMasterReady() }
        readinessTask = task
        // Cleared only if still ours: a wake renewal may have installed its own task since.
        defer { if readinessTask == task { readinessTask = nil } }
        return try await task.value
    }

    /// Closes the shared master and confirms a fresh one, as the warm-up every later caller joins.
    ///
    /// A warm-up already in flight may have seen the old master answer `-O check`, so it is left
    /// to finish and never joined. Checking for it and installing this task is one synchronous
    /// actor step, so a ``ensureMasterReady()`` caller that arrives afterwards joins the renewal
    /// and gets the fresh master's result.
    ///
    /// - Returns: whether the fresh master is running, and the open's stderr, which says why
    ///   when it is not.
    func closeAndReopenMaster() async -> (isRunning: Bool, openStderr: String) {
        while let earlier = readinessTask {
            _ = try? await earlier.value
            if readinessTask == earlier { break }
        }
        let renewal = Task { () async throws -> (isRunning: Bool, openStderr: String) in
            await self.shutdownMaster()
            return try await self.openMasterIfNeeded()
        }
        // Joiners only need to know whether a master is running.
        let task = Task { try await renewal.value.isRunning }
        readinessTask = task
        defer { if readinessTask == task { readinessTask = nil } }
        return (try? await renewal.value) ?? (false, "")
    }

    /// The actual warmup, run exactly once per ``readinessTask`` (see
    /// ``ensureMasterReady()`` for the single-flight + readiness rationale).
    private func performMasterReady() async throws -> Bool {
        try await openMasterIfNeeded().isRunning
    }

    /// Opens the shared master unless one is running, then confirms it.
    ///
    /// - Returns: whether a master is running afterwards, and the open's stderr (empty when no
    ///   open was needed or it printed nothing).
    private func openMasterIfNeeded() async throws -> (isRunning: Bool, openStderr: String) {
        try? host.ensureControlSocketDirectory()
        if try await masterIsRunning() { return (true, "") }
        // Warm the shared master once, then confirm. The open's exit code is not
        // trusted (a non-multiplexed fallback can make `run` exit 0 with no live
        // master — see the doc comment); the post-open `ssh -O check` is authoritative.
        let open = try? await run(["true"])
        return (try await masterIsRunning(), open?.stderr ?? "")
    }

    /// Whether the shared ControlMaster is live and accepting sessions, via the
    /// local `ssh -O check` control command. `-O check` hits the LOCAL control
    /// socket only (identified by `ControlPath`), so it never opens a network
    /// connection and returns in milliseconds.
    ///
    /// Propagates `CancellationError` (so a cancelled ``ensureMasterReady()`` aborts
    /// rather than mis-reading the cancellation as "no master"); collapses only
    /// ordinary launch/socket failures to `false`.
    private func masterIsRunning() async throws -> Bool {
        do {
            let result = try await Self.runProcess(
                executable: sshExecutablePath,
                arguments: ["-O", "check", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
            )
            return result.succeeded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    /// Whether the shared ControlMaster is live, WITHOUT trying to open one.
    ///
    /// `ssh -O check` hits the local control socket only, so it returns in
    /// milliseconds and can never prompt for credentials. That makes it the safe
    /// probe for "has the user finished authenticating in the login terminal yet?" —
    /// unlike ``ensureMasterReady()``, which would attempt a `BatchMode` open and
    /// burn a failed authentication attempt while the user is still typing.
    ///
    /// A transport with no shared master reports live, matching
    /// ``ensureMasterReady()``: nothing is pending on a socket.
    func isMasterLive() async -> Bool {
        guard transportProfile.usesSharedControlMaster else { return true }
        return (try? await masterIsRunning()) ?? false
    }

    /// Tears down the shared SSH master (e.g. when the user removes a host).
    /// Does nothing for a transport with no shared master.
    func shutdownMaster() async {
        guard transportProfile.usesSharedControlMaster else { return }
        _ = try? await Self.runProcess(
            executable: sshExecutablePath,
            arguments: ["-O", "exit", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
        )
    }

    /// Fire-and-forget `ssh -O exit` to close the host's shared SSH ControlMaster.
    ///
    /// `nonisolated` and non-`async` so it can run from the synchronous app-quit /
    /// window-close paths where awaiting an actor isn't possible. `-O exit` hits the
    /// LOCAL control socket (fast, no network round-trip) and the spawned process
    /// runs independently of cmux, so the master is torn down even as the app exits
    /// — instead of lingering for `ControlPersist` after the user closes the app or
    /// the mirror window. Best-effort: a missing/dead socket just fails fast.
    /// Spawns nothing for a host whose transport has no shared master.
    nonisolated static func spawnControlMasterExit(
        host: RemoteTmuxHost,
        sshExecutablePath: String = RemoteTmuxHost.defaultSSHExecutablePath()
    ) {
        guard host.transportProfile.usesSharedControlMaster else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = ["-O", "exit", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()  // fire-and-forget — do not wait
    }

    /// Kills each `(transport, sessionTarget)` via `tmux kill-session`. Races the kill
    /// round-trips against a single `Task.sleep(timeout)` and returns at the first to
    /// finish (`group.next()` then `cancelAll()`) — so on a RESPONSIVE connection this
    /// returns as soon as the kills land (well under `timeout`). Kills to the SAME host
    /// serialize on that host's transport actor; different hosts run in parallel.
    ///
    /// `runProcess` force-stops its child when task cancellation follows the
    /// timeout, so the structured group also finishes within this boundary.
    /// The remote kill remains best-effort when the connection itself is dead.
    nonisolated static func killSessions(
        _ jobs: [(transport: RemoteTmuxSSHTransport, target: String)],
        timeout: Duration
    ) async {
        guard !jobs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { kills in
                    for job in jobs {
                        kills.addTask { _ = try? await job.transport.runTmux(["kill-session", "-t", job.target]) }
                    }
                    await kills.waitForAll()
                }
            }
            group.addTask { try? await ContinuousClock().sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Heuristics

    /// Whether stderr indicates the remote tmux server simply isn't running.
    static func indicatesNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
            || lowered.contains("no sessions")
            || (lowered.contains("error connecting to /") && lowered.contains("/tmux-"))
    }

    static func indicatesRefreshClientSubscriptionUnsupported(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let tokens = lowered.split { character in
            !(character.isLetter || character.isNumber || character == "-")
        }.map(String.init)
        let mentionsBFlag = tokens.enumerated().contains { index, token in
            if token == "-b" || token == "--b" { return true }
            guard token == "b" else { return false }
            if index > 0, tokens[index - 1] == "flag" || tokens[index - 1] == "option" {
                return true
            }
            if index > 1, tokens[index - 1] == "--" {
                let optionNoun = tokens[index - 2]
                return optionNoun == "flag" || optionNoun == "option"
            }
            return false
        }
        let rejectsOption = lowered.contains("unknown flag")
            || lowered.contains("unknown option")
            || lowered.contains("invalid option")
            || lowered.contains("illegal option")
        return mentionsBFlag && rejectsOption
    }

    static func indicatesRefreshClientNeedsCurrentClient(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no current client")
            || lowered.contains("not a client")
            || lowered.contains("not a control client")
    }

    /// Whether one lowercased stderr line says the et client or its remote helper could not be found.
    private static func namesAMissingTransportBinary(_ line: Substring) -> Bool {
        guard line.contains("no such file or directory") else { return false }
        if line.contains("etterminal") { return true }
        // `et` as a whole path component or command name: "/usr/local/bin/et: ...", "et: ...".
        let words = line.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "'" || $0 == "\"" })
        return words.contains { $0 == "et" || $0.hasSuffix("/et") }
    }

    /// Whether a control-stream failure can never be fixed by trying again.
    ///
    /// The counterpart to ``indicatesAuthRequired``, and the same reasoning: retrying is only
    /// honest when the next attempt could differ. A missing binary, a remote helper that is not
    /// where the transport said it was, or a malformed invocation will fail identically forever, so
    /// retrying converts a precise error into an opaque attach timeout — measured, after
    /// end-of-stream stopped implying the session was over: a transport that could not start at all
    /// produced a 60-second wait and no message.
    ///
    /// Deliberately narrow. Anything not listed keeps retrying, because the cost of wrongly
    /// retrying is a delay while the cost of wrongly giving up is a mirror that never returns.
    static func indicatesUnrecoverableTransportFailure(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        // The pty allocator could not find the transport binary. `/usr/bin/script` resolves its
        // argument against the app's PATH, which for a GUI app is not the user's.
        if lowered.contains("script:"), lowered.contains("no such file or directory") { return true }
        // posix_spawn / Process launch failures for the transport itself. The missing file has to
        // be the transport, named on the same line: ssh reports plenty of other missing files (an
        // agent socket, an identity file) and any `/etc/...` path contains `/et`, and neither says
        // the next attempt will fail.
        if lowered.split(whereSeparator: \.isNewline).contains(where: Self.namesAMissingTransportBinary) {
            return true
        }
        // et's own message when its ssh bootstrap cannot start the remote helper — wrong
        // `--terminal-path`, or a helper missing on the server. Retrying sends the same path.
        if lowered.contains("error starting et process") { return true }
        // An argv the transport rejects outright is a bug in what cmux built, not a bad moment.
        if lowered.contains("unrecognized option") || lowered.contains("unknown option") { return true }
        // Go's flag package wording for the same thing. Wrappers that front a transport are
        // routinely written in Go, and without this a mis-ordered argv reads as a bad moment:
        // cmux would retry the identical rejected command forever. Measured against a real
        // broker, which answers "flag provided but not defined: -p" and exits 2.
        if lowered.contains("flag provided but not defined") { return true }
        return false
    }

    /// Whether a failed non-interactive (`BatchMode=yes`) connect failed because
    /// the host needs **interactive** authentication or host-key confirmation
    /// that batch mode cannot service — a password, an unknown/changed host key,
    /// keyboard-interactive MFA, or a FIDO touch. Used to decide whether to hand
    /// the user an interactive `ssh` (run in their terminal by `cmux ssh-tmux`) that
    /// opens the shared ControlMaster, versus surfacing a genuine
    /// unreachable/transient error.
    ///
    /// Matches the canonical OpenSSH failure phrases only. "Permission denied"
    /// already covers `Permission denied (publickey,keyboard-interactive)`, so
    /// the bare "keyboard-interactive" substring is intentionally omitted (it
    /// also appears in success-time banners). A *changed* host key ("remote host
    /// identification has changed") is included so the interactive terminal
    /// renders ssh's actionable message rather than an opaque alert — even though
    /// the user must fix `known_hosts` themselves. Algorithm-negotiation failures
    /// ("no matching host key type") are deliberately NOT matched: an interactive
    /// retry cannot fix them, so they surface as a normal error instead.
    /// Lines are read one at a time so that a line about something other than the
    /// ssh handshake cannot supply the phrase. tmux reports a socket it cannot open
    /// as `error connecting to /tmp/tmux-501/default (Permission denied)`, and
    /// ``listSessions()`` consults this before the no-server branch, so matching it
    /// would offer an interactive login for a problem no login can fix.
    static func indicatesAuthRequired(_ stderr: String) -> Bool {
        stderr.lowercased()
            .split(whereSeparator: \.isNewline)
            .contains(where: Self.lineIndicatesAuthRequired)
    }

    private static func lineIndicatesAuthRequired(_ lowercasedLine: Substring) -> Bool {
        guard !lowercasedLine.contains("error connecting to /") else { return false }
        return lowercasedLine.contains("permission denied")
            || lowercasedLine.contains("host key verification failed")
            || lowercasedLine.contains("remote host identification has changed")
            || lowercasedLine.contains("authentication failed")
            || lowercasedLine.contains("too many authentication failures")
    }

    // MARK: - Process plumbing

    /// Launches a process and captures bounded stdout/stderr without blocking the actor.
    ///
    /// Each pipe is drained to EOF on a detached task so a chatty command can't
    /// deadlock against a full 64 KiB pipe buffer while we await termination.
    /// We capture only the raw fds (`Int32`, `Sendable`) across the task
    /// boundary — never the non-`Sendable` `FileHandle` — and the `Pipe`s stay
    /// alive because `process` retains them until this function returns.
    ///
    /// `environment` nil inherits the app's environment, as ssh's master commands do.
    private static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> RemoteTmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let outRead = Task.detached { Self.drain(fd: outFD, maxBytes: Self.maxCapturedOutputBytes) }
        let errRead = Task.detached { Self.drain(fd: errFD, maxBytes: Self.maxCapturedOutputBytes) }
        let cancellation = RemoteTmuxProcessCancellation(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        // Install the termination handler BEFORE launching, then launch inside the
        // continuation. If `run()` and the handler assignment were separate steps, a
        // process that exits in the window between them would terminate before the
        // handler is installed — and Foundation does not invoke a terminationHandler
        // assigned after the process has already ended, so the continuation would
        // never resume and the caller would hang until its timeout. This matters for
        // the fast auth-failure exits the `cmux ssh-tmux` flow classifies.
        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                    do {
                        try process.run()
                        if Task.isCancelled {
                            cancellation.cancel()
                        }
                    } catch {
                        // The process never started, so the handler will not fire; resume
                        // exactly once here with the launch failure.
                        process.terminationHandler = nil
                        continuation.resume(throwing: RemoteTmuxError.launchFailed(error.localizedDescription))
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            outRead.cancel()
            errRead.cancel()
            _ = await outRead.value
            _ = await errRead.value
            throw error
        }

        let outData = await outRead.value
        let errData = await errRead.value
        return RemoteTmuxCommandResult(
            exitCode: exitCode,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Reads a file descriptor to EOF, returning at most `maxBytes`.
    ///
    /// Uses the raw `read(2)` so nothing non-`Sendable` crosses the task
    /// boundary; the owning `Pipe` keeps `fd` open for the duration.
    private static func drain(fd: Int32, maxBytes: Int) -> Data {
        var data = Data()
        var remaining = max(0, maxBytes)
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            if Task.isCancelled { break }
            let count = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, bufferSize)
            }
            if count > 0 {
                if remaining > 0 {
                    let kept = min(count, remaining)
                    data.append(contentsOf: buffer[0..<kept])
                    remaining -= kept
                }
            } else if count == 0 {
                break // EOF
            } else if errno == EINTR {
                continue // interrupted, retry
            } else {
                break // read error; return what we have
            }
        }
        return data
    }
}
