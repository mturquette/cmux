import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Waiting for the screen to be unlocked before a reconnect authenticates (the owner's decision
/// Q-H2 in the wake-reconnect brief), with the lock state and the unlock notifications injected.
@MainActor
@Suite struct RemoteTmuxScreenUnlockGateTests {
    private static let unlockName = Notification.Name("cmux.test.screen-unlocked")

    @MainActor
    final class Calls {
        var count = 0
        var returned = false
    }

    @Test(arguments: [
        // No window-server session at all: nothing could prompt, so there is nothing to wait for.
        (nil as [String: Bool]?, false, false),
        ([kCGSessionOnConsoleKey as String: true], false, false),
        ([kCGSessionOnConsoleKey as String: true, "CGSSessionScreenIsLocked": true], false, true),
        ([kCGSessionOnConsoleKey as String: true], true, true),
        // Another user owns the console (fast user switching).
        ([kCGSessionOnConsoleKey as String: false], false, true),
    ])
    func lockStateComesFromTheSessionAndTheObservedNotifications(
        dictionary: [String: Bool]?, observedLocked: Bool, expected: Bool
    ) {
        #expect(
            RemoteTmuxScreenUnlockGate.screenIsLocked(sessionDictionary: dictionary, observedLocked: observedLocked)
                == expected
        )
    }

    @Test func anUnlockedScreenDoesNotWait() async {
        let calls = Calls()
        let gate = RemoteTmuxScreenUnlockGate(
            isLocked: { calls.count += 1; return false },
            unlockSignals: [.init(center: NotificationCenter(), name: Self.unlockName)]
        )

        await gate.waitUntilUnlocked()

        #expect(calls.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLockedScreenWaitsForTheUnlockSignal() async {
        let center = NotificationCenter()
        let calls = Calls()
        let (checks, checked) = AsyncStream<Int>.makeStream()
        let gate = RemoteTmuxScreenUnlockGate(
            isLocked: { calls.count += 1; checked.yield(calls.count); return true },
            unlockSignals: [.init(center: center, name: Self.unlockName)]
        )

        let waiter = Task { @MainActor in
            await gate.waitUntilUnlocked()
            calls.returned = true
        }
        // The second check runs after the gate subscribed, so a signal posted now is seen.
        for await count in checks where count == 2 { break }
        #expect(calls.returned == false)

        center.post(name: Self.unlockName, object: nil)
        await waiter.value

        #expect(calls.returned)
    }

    // Adversarial: an unlock that lands between the first check and the subscription is not missed.
    @Test(.timeLimit(.minutes(1)))
    func anUnlockBetweenTheTwoChecksIsNotMissed() async {
        let calls = Calls()
        let gate = RemoteTmuxScreenUnlockGate(
            isLocked: { calls.count += 1; return calls.count == 1 },
            unlockSignals: [.init(center: NotificationCenter(), name: Self.unlockName)]
        )

        await gate.waitUntilUnlocked()

        #expect(calls.count == 2)
    }
}
