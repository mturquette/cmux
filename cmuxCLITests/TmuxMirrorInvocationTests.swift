import Foundation
import Testing

// TmuxMirrorInvocation.swift compiles into this target, so it needs no app import.

/// The `cmux tmux-mirror` argument contract (D9, R2, R13).
@Suite struct TmuxMirrorInvocationTests {
    @Test func noArgumentsMirrorsTheCallersServer() throws {
        let invocation = try TmuxMirrorInvocation.parse([])
        #expect(invocation.action == .mirror)
        #expect(invocation.server == .callerDefault)
        #expect(invocation.focus == nil)
        #expect(!invocation.newWindow)
    }

    @Test func serverFlagsSelectTheServer() throws {
        #expect(try TmuxMirrorInvocation.parse(["--socket-name", "work"]).server == .socketName("work"))
        #expect(try TmuxMirrorInvocation.parse(["--socket-path", "/tmp/s"]).server == .socketPath("/tmp/s"))
        #expect(throws: CLIError.self) {
            try TmuxMirrorInvocation.parse(["--socket-name", "a", "--socket-path", "/tmp/s"])
        }
    }

    @Test func focusFlagsOverrideTheDefault() throws {
        #expect(try TmuxMirrorInvocation.parse(["--focus"]).focus == true)
        #expect(try TmuxMirrorInvocation.parse(["--no-focus"]).focus == false)
    }

    @Test func mirrorOptionsAreKept() throws {
        let invocation = try TmuxMirrorInvocation.parse(["--new-window", "--name", "dev"])
        #expect(invocation.newWindow)
        #expect(invocation.workspaceName == "dev")
    }

    @Test(arguments: ["list", "ls"])
    func listTakesOnlyServerFlags(_ verb: String) throws {
        #expect(try TmuxMirrorInvocation.parse([verb, "--socket-name", "x"]).action == .list)
        #expect(throws: CLIError.self) { try TmuxMirrorInvocation.parse([verb, "--name", "x"]) }
    }

    @Test func attachNeedsASession() throws {
        #expect(try TmuxMirrorInvocation.parse(["attach", "work"]).action == .attach(session: "work"))
        #expect(throws: CLIError.self) { try TmuxMirrorInvocation.parse(["attach"]) }
    }

    @Test(arguments: ["start", "close", "status", "cleanup"])
    func localTmuxSubcommandsPointAtLocalTmux(_ verb: String) {
        do {
            _ = try TmuxMirrorInvocation.parse([verb])
            Issue.record("expected \(verb) to be refused")
        } catch let error as CLIError {
            #expect(error.message.contains("local-tmux"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func unknownInputIsRefused() {
        #expect(throws: CLIError.self) { try TmuxMirrorInvocation.parse(["frobnicate"]) }
        #expect(throws: CLIError.self) { try TmuxMirrorInvocation.parse(["--port", "22"]) }
        #expect(throws: CLIError.self) { try TmuxMirrorInvocation.parse(["--socket-name"]) }
    }

    @Test func helpNamesLocalTmux() {
        #expect(TmuxMirrorInvocation.usage.contains("cmux local-tmux"))
    }
}
