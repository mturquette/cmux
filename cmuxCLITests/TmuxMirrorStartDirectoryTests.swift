import Foundation
import Testing

// TmuxMirrorStartDirectory.swift compiles into this target, so it needs no app import.

/// Where the first session starts when `cmux tmux-mirror` starts the server (R1, R5, T20).
@Suite struct TmuxMirrorStartDirectoryTests {
    private func choose(
        pwd: String?,
        physical: String?,
        same: Bool = true,
        enterable: Bool = true
    ) -> TmuxMirrorStartDirectory.Choice {
        TmuxMirrorStartDirectory(
            shellWorkingDirectory: pwd,
            physicalWorkingDirectory: physical,
            homeDirectory: "/Users/me",
            namesSameDirectory: { _, _ in same },
            canEnter: { _ in enterable }
        ).choose()
    }

    @Test func aNormalDirectoryIsUsedAsIs() {
        let choice = choose(pwd: "/Users/me/src", physical: "/Users/me/src")
        #expect(choice == .init(directory: "/Users/me/src", fallback: nil))
        #expect(choice.notice == nil)
    }

    @Test func aSymlinkedPathIsKeptAsTyped() {
        #expect(choose(pwd: "/Users/me/link", physical: "/Volumes/data/real").directory == "/Users/me/link")
    }

    @Test func aStalePWDGivesWayToThePhysicalDirectory() {
        #expect(choose(pwd: "/old/place", physical: "/Users/me/src", same: false).directory == "/Users/me/src")
        #expect(choose(pwd: "relative", physical: "/Users/me/src").directory == "/Users/me/src")
    }

    @Test func aDeletedDirectoryFallsBackToHomeWithANotice() {
        let choice = choose(pwd: "/Users/me/gone", physical: nil)
        #expect(choice == .init(directory: "/Users/me", fallback: .workingDirectoryGone))
        #expect(choice.notice?.contains("/Users/me") == true)
    }

    @Test func anUnenterableDirectoryFallsBackToHomeWithANotice() {
        let choice = choose(pwd: "/Users/me/locked", physical: "/Users/me/locked", enterable: false)
        #expect(choice == .init(directory: "/Users/me", fallback: .notEnterable(path: "/Users/me/locked")))
        #expect(choice.notice?.contains("/Users/me/locked") == true)
    }

    @Test func aPathWithANewlineFallsBackToHome() {
        let choice = choose(pwd: "/tmp/a\nb", physical: "/tmp/a\nb")
        #expect(choice == .init(directory: "/Users/me", fallback: .controlCharacter))
        #expect(choice.notice != nil)
    }

    @Test func formatsInThePathStayLiteral() {
        let path = "/tmp/it's \"quoted\" 🦊 #{session_name}"
        let choice = choose(pwd: path, physical: path)
        #expect(choice.directory == path)
        #expect(choice.tmuxArgument == "/tmp/it's \"quoted\" 🦊 ##{session_name}")
    }

    @Test func realProcessStateUsesTheCurrentDirectory() {
        // The live initializer reads getcwd; this process's directory exists and can be entered.
        let choice = TmuxMirrorStartDirectory(environment: ["HOME": "/Users/me"]).choose()
        #expect(choice.fallback == nil)
        #expect(choice.directory == FileManager.default.currentDirectoryPath)
    }
}
