import Foundation
import Testing

// TmuxServerSocketResolver.swift compiles into this target, so it needs no app import.

/// `cmux tmux-mirror` mirrors the server `tmux ls` would show in the calling shell.
@Suite struct TmuxServerSocketResolverTests {
    private func resolver(_ environment: [String: String]) -> TmuxServerSocketResolver {
        TmuxServerSocketResolver(environment: environment, userID: 501, currentDirectory: "/Users/me/work")
    }

    @Test func outsideTmuxTheDefaultServerFollowsTMUXTMPDIR() throws {
        #expect(try resolver([:]).socketPath(for: .callerDefault) == "/tmp/tmux-501/default")
        #expect(try resolver(["TMUX_TMPDIR": "/private/var/t"]).socketPath(for: .callerDefault)
            == "/private/var/t/tmux-501/default")
        #expect(try resolver(["TMUX_TMPDIR": "/private/var/t/"]).socketPath(for: .callerDefault)
            == "/private/var/t/tmux-501/default")
        // tmux treats an empty TMUX_TMPDIR as unset.
        #expect(try resolver(["TMUX_TMPDIR": ""]).socketPath(for: .callerDefault) == "/tmp/tmux-501/default")
    }

    @Test func insideTmuxTheCurrentPanesServerWins() throws {
        let inside = resolver(["TMUX": "/tmp/x/alt,4242,3", "TMUX_TMPDIR": "/elsewhere"])
        #expect(try inside.socketPath(for: .callerDefault) == "/tmp/x/alt")
    }

    @Test func aMalformedTMUXFallsBackToTheDefaultServer() throws {
        #expect(try resolver(["TMUX": ""]).socketPath(for: .callerDefault) == "/tmp/tmux-501/default")
        #expect(try resolver(["TMUX": "relative,1,0"]).socketPath(for: .callerDefault) == "/tmp/tmux-501/default")
    }

    @Test func socketNameIsTmuxDashL() throws {
        let inside = resolver(["TMUX": "/tmp/x/alt,1,0", "TMUX_TMPDIR": "/t"])
        // An explicit flag beats the pane's server.
        #expect(try inside.socketPath(for: .socketName("work")) == "/t/tmux-501/work")
    }

    @Test(arguments: ["", ".", "..", "a/b", "bad\nname", "bad\u{7}name", "zero\u{200b}width"])
    func unusableSocketNamesAreRefused(_ name: String) {
        #expect(throws: CLIError.self) { try resolver([:]).socketPath(for: .socketName(name)) }
    }

    @Test func socketPathIsTmuxDashSMadeAbsolute() throws {
        #expect(try resolver([:]).socketPath(for: .socketPath("/tmp/x/sock")) == "/tmp/x/sock")
        #expect(try resolver([:]).socketPath(for: .socketPath("sockets/../s")) == "/Users/me/work/s")
        #expect(try resolver(["TMUX": "/tmp/x/alt,1,0"]).socketPath(for: .socketPath("/tmp/y")) == "/tmp/y")
    }
}
