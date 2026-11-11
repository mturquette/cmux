import Foundation

/// Parsed arguments for `cmux tmux-mirror`.
///
/// `cmux tmux-mirror [--socket-name <n> | --socket-path <p>] [--new-window] [--name <title>]
/// [--focus | --no-focus]`, with `list` and `attach <session>` subcommands, following
/// `cmux ssh-tmux`.
struct TmuxMirrorInvocation: Equatable {
    enum Action: Equatable {
        case mirror
        case list
        case attach(session: String)
    }

    let action: Action
    let server: TmuxServerSocketResolver.Request
    let workspaceName: String?
    let focus: Bool?
    let newWindow: Bool

    /// Subcommands that belong to `cmux local-tmux`, which runs a private, persistent server.
    /// Typing one here is a likely mix-up between the two commands, so it gets a pointer.
    static let localTmuxSubcommands: Set<String> = [
        "start", "create", "open", "status", "info", "detach", "close", "kill", "delete", "cleanup", "prune",
    ]

    /// The help text. Its first line names `cmux local-tmux`, as `local-tmux`'s names this command.
    static var usage: String {
        String(localized: "cli.tmuxMirror.help", defaultValue: """
            Usage: cmux tmux-mirror [--socket-name <name> | --socket-path <path>] [--new-window] [--name <title>] [--focus | --no-focus]
                   cmux tmux-mirror list [--socket-name <name> | --socket-path <path>]
                   cmux tmux-mirror attach <session> [options]

            Mirror an existing tmux server on this Mac without SSH (cmux local-tmux runs a private, persistent server).
            Each session becomes a workspace, each window a tab, and each multi-pane window a native split.

            By default it mirrors the server `tmux ls` would show in this shell: the current pane's
            server inside tmux, otherwise the one chosen by TMUX_TMPDIR. When no server is running, it starts one with a session in the current directory.

            Flags:
              --socket-name <name>  The server tmux -L <name> would use
              --socket-path <path>  The server tmux -S <path> would use
              --new-window          Open the mirror in a new window
              --name <title>        Workspace title
              --focus, --no-focus   Override the default focus behavior
            """)
    }

    static func parse(_ commandArgs: [String]) throws -> TmuxMirrorInvocation {
        var action: Action?
        var sessionArgument: String?
        var server = TmuxServerSocketResolver.Request.callerDefault
        var workspaceName: String?
        var focus: Bool?
        var newWindow = false

        func value(after index: Int, for flag: String) throws -> String {
            guard index + 1 < commandArgs.count, !commandArgs[index + 1].hasPrefix("-") else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.tmuxMirror.error.flagRequiresValue",
                        defaultValue: "tmux-mirror: %@ requires a value"
                    ),
                    flag
                ))
            }
            return commandArgs[index + 1]
        }

        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            switch arg {
            case "--socket-name", "--socket-path":
                guard server == .callerDefault else {
                    throw CLIError(message: String(
                        localized: "cli.tmuxMirror.error.oneServer",
                        defaultValue: "tmux-mirror: pass --socket-name or --socket-path, not both"
                    ))
                }
                let raw = try value(after: index, for: arg)
                server = arg == "--socket-name" ? .socketName(raw) : .socketPath(raw)
                index += 2
            case "--name":
                workspaceName = try value(after: index, for: arg)
                index += 2
            case "--focus":
                focus = true
                index += 1
            case "--no-focus":
                focus = false
                index += 1
            case "--new-window":
                newWindow = true
                index += 1
            case "-h", "--help", "help":
                throw CLIError(message: usage)
            default:
                if arg.hasPrefix("-") {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.tmuxMirror.error.unknownFlag",
                            defaultValue: "tmux-mirror: unknown option %@"
                        ),
                        arg
                    ))
                }
                if action == nil, sessionArgument == nil {
                    switch arg.lowercased() {
                    case "list", "ls":
                        action = .list
                    case "attach":
                        action = .attach(session: "")
                    case let name where localTmuxSubcommands.contains(name):
                        throw CLIError(message: String(
                            format: String(
                                localized: "cli.tmuxMirror.error.localTmuxSubcommand",
                                defaultValue: "tmux-mirror: '%@' is a cmux local-tmux command; run cmux local-tmux %@"
                            ),
                            arg, arg
                        ))
                    default:
                        throw CLIError(message: String(
                            format: String(
                                localized: "cli.tmuxMirror.error.unknownSubcommand",
                                defaultValue: "tmux-mirror: unknown subcommand '%@'; use list or attach <session>"
                            ),
                            arg
                        ))
                    }
                } else if case .attach = action, sessionArgument == nil {
                    sessionArgument = arg
                } else {
                    throw CLIError(message: String(
                        format: String(
                            localized: "cli.tmuxMirror.error.extraArgument",
                            defaultValue: "tmux-mirror: unexpected argument '%@'"
                        ),
                        arg
                    ))
                }
                index += 1
            }
        }

        let resolved: Action
        switch action {
        case nil, .mirror:
            resolved = .mirror
        case .list:
            guard workspaceName == nil, !newWindow, focus == nil else {
                throw CLIError(message: String(
                    localized: "cli.tmuxMirror.error.listOptions",
                    defaultValue: "tmux-mirror list only accepts --socket-name or --socket-path"
                ))
            }
            resolved = .list
        case .attach:
            guard let session = sessionArgument?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !session.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.tmuxMirror.error.attachRequiresSession",
                    defaultValue: "tmux-mirror attach requires a session name"
                ))
            }
            resolved = .attach(session: session)
        }
        return TmuxMirrorInvocation(
            action: resolved,
            server: server,
            workspaceName: workspaceName,
            focus: focus,
            newWindow: newWindow
        )
    }
}
