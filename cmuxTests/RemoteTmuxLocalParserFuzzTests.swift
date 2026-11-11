import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Deterministic SplitMix64 PRNG. Every random draw in this file flows through
/// it, seeded from the test argument, so a failure reproduces exactly from the
/// seed in its message: no `Date()`, no `SystemRandomNumberGenerator`.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Seeded fuzz of the control-mode parser and the message decoders that the
/// local tmux mirror shares with ssh and et (DESIGN.md A12).
///
/// Three properties are checked for every seed:
///
/// 1. **Model round trip.** A generator plays tmux: it builds a stream of
///    well-formed frames the way tmux writes them (octal-escaped `%output`,
///    command blocks whose content holds lines that look like `%end`, `%exit`,
///    `%output` or the enter DCS, pty `\r\n` endings, shell noise before the
///    enter DCS), and records the messages the parser must produce. The bytes
///    are fed in random chunks split at arbitrary byte boundaries. Any
///    difference is a desync.
/// 2. **Chunking invariance.** Random protocol-flavored byte soup, fed whole and
///    fed in random chunks, gives the same messages up to the first
///    `streamError` (after which the caller drops the stream).
/// 3. **Decoder safety.** `RemoteTmuxControlMessageDecoding` never traps on
///    hostile `display-message` lines, keeps its escape output within terminal
///    bounds, and `windowOrder` keeps every window exactly once.
///
/// A seed that ever fails goes into ``regressionSeeds`` with a note, and stays
/// there, as `RemoteTmuxMultiplexFuzzTests` does. The time-boxed run reads
/// `CMUX_PARSER_FUZZ_SECONDS` and `CMUX_PARSER_FUZZ_BASE_SEED` from the test
/// runner's environment (pass them through xcodebuild as `TEST_RUNNER_...`);
/// with neither set it runs a fixed block of derived seeds, so CI stays
/// deterministic.
@Suite struct RemoteTmuxLocalParserFuzzTests {
    private static let seeds: [UInt64] = [
        0x1, 0x2A, 0xBEEF, 0xC0FFEE, 0xDEAD10CC, 0xFAB1E5, 0x7209, 0x424242,
        0x38854, 0x8421, 0x1F2E3D4C, 0xFFFF_FFFF_FFFF_FFFF,
    ]

    /// Seeds that once failed. Each entry keeps its reason. Empty at the
    /// pinned base commit 0b458fe: no seed has failed yet.
    private static let regressionSeeds: [UInt64] = []

    private static var allSeeds: [UInt64] { seeds + regressionSeeds }

    // MARK: - Property 1: model round trip

    @Test(.timeLimit(.minutes(1)), arguments: allSeeds)
    func wellFormedStreamsDecodeExactlyAtAnyChunking(seed: UInt64) {
        Self.checkRoundTrip(seed: seed, frames: 400)
    }

    // MARK: - Property 2: chunking invariance on byte soup

    @Test(.timeLimit(.minutes(1)), arguments: allSeeds)
    func byteSoupDecodesTheSameAtAnyChunking(seed: UInt64) {
        Self.checkSoup(seed: seed, length: 64 * 1024)
    }

    // MARK: - Property 3: decoders

    @Test(.timeLimit(.minutes(1)), arguments: allSeeds)
    func paneStateSeedNeverTrapsAndStaysInBounds(seed: UInt64) {
        Self.checkPaneStateSeed(seed: seed, cases: 2_000)
    }

    @Test(.timeLimit(.minutes(1)), arguments: allSeeds)
    func windowOrderKeepsEveryWindowExactlyOnce(seed: UInt64) {
        Self.checkWindowOrder(seed: seed, cases: 2_000)
    }

    // MARK: - Time-boxed run

    /// Runs fresh seeds until a deadline. Without the environment variables
    /// this is a fixed block of 64 seeds derived from a constant, so it is
    /// deterministic in CI; the adversarial stage sets a time budget and a
    /// random base seed and prints both, so a failure names its seed.
    @Test(.timeLimit(.minutes(30)))
    func timeBoxedRandomSeeds() {
        let environment = ProcessInfo.processInfo.environment
        let budget = environment["CMUX_PARSER_FUZZ_SECONDS"].flatMap(Double.init)
        let base = environment["CMUX_PARSER_FUZZ_BASE_SEED"].flatMap { UInt64($0, radix: 16) ?? UInt64($0) }
            ?? 0x5EED_0000_0000_0000
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int64((budget ?? 0) * 1000)))
        var iteration: UInt64 = 0
        var mixer = SplitMix64(seed: base)
        while budget == nil ? iteration < 64 : clock.now < deadline {
            let seed = mixer.next()
            Self.checkRoundTrip(seed: seed, frames: 200)
            Self.checkSoup(seed: seed, length: 16 * 1024)
            Self.checkPaneStateSeed(seed: seed, cases: 200)
            Self.checkWindowOrder(seed: seed, cases: 200)
            iteration += 1
        }
        print("RemoteTmuxLocalParserFuzzTests: \(iteration) seeds from base 0x\(String(base, radix: 16))")
        #expect(iteration > 0)
    }

    // MARK: - Generators and checkers

    private static func checkRoundTrip(seed: UInt64, frames: Int) {
        var rng = SplitMix64(seed: seed)
        var stream: [UInt8] = []
        var expected: [RemoteTmuxControlMessage] = []

        // Shell noise before control mode, then the enter DCS on the same line
        // as the first frame, as a login shell plus tmux -CC produce.
        if Bool.random(using: &rng) {
            stream += Array(randomText(&rng, maxLength: 40, allowNewlines: false).utf8)
            stream += [0x1b] + Array("]0;user@host:~".utf8) + [0x07]
        }
        stream += [0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        expected.append(.enter)

        for _ in 0..<frames {
            let frame = randomFrame(&rng)
            for line in frame.lines {
                stream += line
                stream += Bool.random(using: &rng) ? [0x0d, 0x0a] : [0x0a]
            }
            expected += frame.messages
        }
        // tmux ends control mode with %exit and the DCS terminator.
        stream += Array("%exit detached\r\n".utf8) + [0x1b, 0x5c]
        expected.append(.exit(reason: "detached"))

        var parser = RemoteTmuxControlStreamParser()
        var got: [RemoteTmuxControlMessage] = []
        for chunk in randomChunks(stream, &rng) {
            got += parser.feed(Data(chunk))
        }
        let firstDifference = firstMismatch(got, expected)
        let same = got == expected
        #expect(
            same,
            """
            seed 0x\(String(seed, radix: 16)): desync at message \(firstDifference) \
            of \(expected.count) (got \(got.count)). \
            expected \(firstDifference < expected.count ? String(describing: expected[firstDifference]) : "end"), \
            got \(firstDifference < got.count ? String(describing: got[firstDifference]) : "end")
            """
        )
    }

    private static func checkSoup(seed: UInt64, length: Int) {
        var rng = SplitMix64(seed: seed)
        let tokens: [[UInt8]] = [
            Array("%begin 1 ".utf8), Array("%end 1 ".utf8), Array("%error 1 ".utf8),
            Array("%output %".utf8), Array("%exit".utf8), Array("%window-add @".utf8),
            Array("%layout-change @1 ".utf8), Array("%session-renamed ".utf8),
            Array("%subscription-changed a $1 @1 1 %1 : ".utf8), Array("%client-detached ".utf8),
            [0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70], [0x1b, 0x5c], [0x0d], [0x0a], [0x0d, 0x0a],
            Array("\\".utf8), Array("\\377".utf8), Array("\\777".utf8), Array("\\0".utf8),
            [0xc3], [0x80], [0xf0, 0x9f], [0xff], [0x00], Array(" ".utf8), Array("$".utf8),
            Array("-1".utf8), Array("99999999999999999999".utf8), Array("0".utf8),
        ]
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length + 64)
        while bytes.count < length {
            if Int.random(in: 0..<3, using: &rng) == 0 {
                bytes.append(UInt8.random(in: 0...255, using: &rng))
            } else {
                bytes += tokens[Int.random(in: 0..<tokens.count, using: &rng)]
            }
        }
        // Small budgets make the overflow paths reachable inside the soup.
        let lineBudget = [64, 512, 1_048_576][Int.random(in: 0..<3, using: &rng)]
        let blockBudget = [128, 4096, RemoteTmuxControlStreamParser.defaultMaximumCommandBlockBytes][Int.random(in: 0..<3, using: &rng)]

        var whole = RemoteTmuxControlStreamParser(maxBufferedLineBytes: lineBudget, maxCommandBlockBytes: blockBudget)
        let reference = truncatedAtStreamError(whole.feed(Data(bytes)))

        var chunked = RemoteTmuxControlStreamParser(maxBufferedLineBytes: lineBudget, maxCommandBlockBytes: blockBudget)
        var got: [RemoteTmuxControlMessage] = []
        for chunk in randomChunks(bytes, &rng) {
            got += chunked.feed(Data(chunk))
            if got.contains(where: { if case .streamError = $0 { return true } else { return false } }) { break }
        }
        got = truncatedAtStreamError(got)
        let firstDifference = firstMismatch(got, reference)
        #expect(
            got == reference,
            "seed 0x\(String(seed, radix: 16)): chunking changed message \(firstDifference) (whole \(reference.count), chunked \(got.count)); budgets line \(lineBudget) block \(blockBudget)"
        )
    }

    private static func checkPaneStateSeed(seed: UInt64, cases: Int) {
        var rng = SplitMix64(seed: seed)
        let decoding = RemoteTmuxControlMessageDecoding()
        let keys = [
            "scroll_region_upper", "scroll_region_lower", "pane_height", "cursor_x", "cursor_y",
            "wrap_flag", "cursor_flag", "insert_flag", "keypad_cursor_flag", "keypad_flag",
            "mouse_all_flag", "mouse_button_flag", "mouse_standard_flag", "mouse_sgr_flag",
            "mouse_utf8_flag", "origin_flag", "", "=",
        ]
        let values = [
            "0", "1", "-1", "65535", "65536", "9223372036854775807", "-9223372036854775808",
            "99999999999999999999", "", "x", "1=1", "١٢", "0x10", " 5", "+5", "00012",
        ]
        for _ in 0..<cases {
            var pairs: [String] = []
            for _ in 0..<Int.random(in: 0..<24, using: &rng) {
                let key = keys[Int.random(in: 0..<keys.count, using: &rng)]
                let value = Bool.random(using: &rng)
                    ? values[Int.random(in: 0..<values.count, using: &rng)]
                    : String(Int.random(in: -70_000...70_000, using: &rng))
                pairs.append("\(key)=\(value)")
            }
            if Int.random(in: 0..<8, using: &rng) == 0 {
                pairs.append(randomText(&rng, maxLength: 30, allowNewlines: true))
            }
            let line = pairs.joined(separator: ",")
            let data = decoding.paneStateSeedSequence(from: line)
            let text = String(decoding: data, as: UTF8.self)
            #expect(data.allSatisfy { $0 < 0x80 }, "seed \(seed): non-ASCII escape output for \(line.debugDescription)")
            #expect(text.hasPrefix("\u{1b}[m"), "seed \(seed): missing SGR reset for \(line.debugDescription)")
            for number in numericParameters(in: text) {
                #expect((0...65_536).contains(number), "seed \(seed): parameter \(number) out of range for \(line.debugDescription)")
            }
        }
    }

    private static func checkWindowOrder(seed: UInt64, cases: Int) {
        var rng = SplitMix64(seed: seed)
        let decoding = RemoteTmuxControlMessageDecoding()
        for _ in 0..<cases {
            let count = Int.random(in: 0..<12, using: &rng)
            var order = Array(Set((0..<count).map { _ in Int.random(in: 0..<40, using: &rng) }))
            order.shuffle(using: &rng)
            let subset = order.filter { _ in Bool.random(using: &rng) }.shuffled(using: &rng)
            let result = decoding.windowOrder(order, applyingReorder: subset)
            #expect(result.sorted() == order.sorted(), "seed \(seed): \(order) with \(subset) gave \(result)")
            #expect(result.filter { subset.contains($0) } == subset, "seed \(seed): reordered windows not in the requested order")
            for (index, id) in order.enumerated() where !subset.contains(id) {
                #expect(result[index] == id, "seed \(seed): window \(id) moved although it was not reordered")
            }
        }
    }

    /// One frame: the lines tmux would write and the messages they must decode to.
    private struct Frame {
        var lines: [[UInt8]]
        var messages: [RemoteTmuxControlMessage]
    }

    private static func randomFrame(_ rng: inout SplitMix64) -> Frame {
        let id = Int.random(in: 0..<5_000, using: &rng)
        let other = Int.random(in: 0..<5_000, using: &rng)
        switch Int.random(in: 0..<14, using: &rng) {
        case 0, 1, 2:
            // %output: raw pane bytes, escaped as tmux does (control_append_data:
            // bytes below 0x20 and the backslash become \ooo, everything else,
            // including high bytes and split UTF-8, is written raw).
            var data: [UInt8] = []
            for _ in 0..<Int.random(in: 0..<200, using: &rng) {
                data.append(UInt8.random(in: 0...255, using: &rng))
            }
            return Frame(
                lines: [Array("%output %\(id) ".utf8) + tmuxEscaped(data)],
                messages: [.output(paneId: id, data: Data(data))]
            )
        case 3, 4:
            return commandBlock(&rng, number: id, isError: Int.random(in: 0..<4, using: &rng) == 0)
        case 5:
            return Frame(lines: [Array("%window-add @\(id)".utf8)], messages: [.windowAdd(windowId: id)])
        case 6:
            return Frame(lines: [Array("%unlinked-window-close @\(id)".utf8)], messages: [.windowClose(windowId: id)])
        case 7:
            let name = randomName(&rng)
            return Frame(
                lines: [Array("%window-renamed @\(id) \(name)".utf8)],
                messages: [.windowRenamed(windowId: id, name: name)]
            )
        case 8:
            let zoomed = Bool.random(using: &rng)
            let layout = "b25d,160x48,0,0{80x48,0,0,\(id),79x48,81,0,\(other)}"
            let visible = zoomed ? "a1b2,160x48,0,0,\(id)" : layout
            return Frame(
                lines: [Array("%layout-change @\(id) \(layout) \(visible) \(zoomed ? "*Z" : "*")".utf8)],
                messages: [.layoutChange(windowId: id, layout: layout, visibleLayout: visible, zoomed: zoomed)]
            )
        case 9:
            let name = randomName(&rng)
            return Frame(
                lines: [Array("%session-changed $\(id) \(name)".utf8)],
                messages: [.sessionChanged(sessionId: id, name: name)]
            )
        case 10:
            let name = randomName(&rng)
            guard !name.isEmpty else {
                return Frame(lines: [Array("%sessions-changed".utf8)], messages: [.sessionsChanged])
            }
            return Frame(
                lines: [Array("%session-renamed $\(id) \(name)".utf8)],
                messages: [.sessionRenamed(sessionId: id, name: "$\(id) \(name)", idBearingName: name)]
            )
        case 11:
            let value = randomName(&rng) + " : " + randomName(&rng)
            return Frame(
                lines: [Array("%subscription-changed cmux_cwd_\(id) $1 @\(other) 0 %\(id) : \(value)".utf8)],
                messages: [.subscriptionChanged(name: "cmux_cwd_\(id)", value: value)]
            )
        case 12:
            return Frame(
                lines: [Array("%window-pane-changed @\(id) %\(other)".utf8)],
                messages: [.windowPaneChanged(windowId: id, paneId: other)]
            )
        default:
            // Pty noise between frames: blank lines and stray ST terminators
            // produce nothing.
            return Frame(lines: [[], [0x1b, 0x5c]], messages: [])
        }
    }

    /// A command block whose content tries to end it early or to look like
    /// other frames. Only `%end`/`%error` with the block's own number ends it.
    private static func commandBlock(_ rng: inout SplitMix64, number: Int, isError: Bool) -> Frame {
        let time = Int.random(in: 1_700_000_000..<1_800_000_000, using: &rng)
        var lines: [[UInt8]] = [Array("%begin \(time) \(number) 1".utf8)]
        var content: [String] = []
        for _ in 0..<Int.random(in: 0..<12, using: &rng) {
            let wrongNumber = number + Int.random(in: 1..<1_000, using: &rng)
            let decoys = [
                "%end \(time) \(wrongNumber) 1",
                "%error \(time) \(wrongNumber) 1",
                "%end \(time) x 1",
                "%exit",
                "%output %1 not-a-frame",
                "%window-add @1",
                "%begin \(time) \(wrongNumber) 1",
                "\u{1b}P1000p%exit",
                "",
                "osc \u{1b}]0;t\u{1b}\\ end",
                randomName(&rng),
            ]
            content.append(decoys[Int.random(in: 0..<decoys.count, using: &rng)])
        }
        for line in content { lines.append(Array(line.utf8)) }
        lines.append(Array("%\(isError ? "error" : "end") \(time) \(number) 1".utf8))
        return Frame(lines: lines, messages: [.commandResult(commandNumber: number, lines: content, isError: isError)])
    }

    /// Escapes pane bytes the way tmux's control_append_data does.
    private static func tmuxEscaped(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for byte in data {
            if byte < 0x20 || byte == 0x5c {
                out += [0x5c, 0x30 + (byte >> 6), 0x30 + ((byte >> 3) & 7), 0x30 + (byte & 7)]
            } else {
                out.append(byte)
            }
        }
        return out
    }

    /// A name as tmux would print it: printable, possibly with spaces, `%`,
    /// `$`, `@`, emoji, combining marks and right-to-left text. tmux escapes
    /// control characters in names, so none appear.
    private static func randomName(_ rng: inout SplitMix64) -> String {
        let pieces = ["a", "Z", "9", " ", "%", "$", "@", "#", ":", ".", "-", "🧪", "e\u{301}", "שלום", "مرحبا", "%end", "%exit", "\\"]
        var name = ""
        for _ in 0..<Int.random(in: 0..<10, using: &rng) {
            name += pieces[Int.random(in: 0..<pieces.count, using: &rng)]
        }
        // A trailing carriage return would be stripped as pty framing.
        return name
    }

    private static func randomText(_ rng: inout SplitMix64, maxLength: Int, allowNewlines: Bool) -> String {
        let pieces = [
            "no server running on /tmp/x", "lost server", "can't find session: x", "no sessions",
            "session not found", "no current session", "Lost Server", " ", "\t", "x", "ü", "🧪",
            "can\u{2019}t find session: y", "error", ":", "ssh: connect", "%",
        ]
        var text = ""
        for _ in 0..<Int.random(in: 0..<maxLength / 8 + 1, using: &rng) {
            text += pieces[Int.random(in: 0..<pieces.count, using: &rng)]
            if allowNewlines, Int.random(in: 0..<5, using: &rng) == 0 { text += "\n" }
        }
        return text
    }

    /// Splits bytes at random boundaries: mostly tiny chunks (to cut through
    /// CRLF, DCS and escapes), sometimes large ones.
    private static func randomChunks(_ bytes: [UInt8], _ rng: inout SplitMix64) -> [[UInt8]] {
        var chunks: [[UInt8]] = []
        var index = 0
        while index < bytes.count {
            let size = Int.random(in: 0..<10, using: &rng) == 0
                ? Int.random(in: 1...4_096, using: &rng)
                : Int.random(in: 1...16, using: &rng)
            let end = min(bytes.count, index + size)
            chunks.append(Array(bytes[index..<end]))
            index = end
        }
        return chunks
    }

    /// Index of the first message that differs, or the shorter count when one
    /// list is a prefix of the other.
    private static func firstMismatch(_ a: [RemoteTmuxControlMessage], _ b: [RemoteTmuxControlMessage]) -> Int {
        let shared = min(a.count, b.count)
        return (0..<shared).first { a[$0] != b[$0] } ?? shared
    }

    private static func truncatedAtStreamError(_ messages: [RemoteTmuxControlMessage]) -> [RemoteTmuxControlMessage] {
        guard let index = messages.firstIndex(where: { if case .streamError = $0 { return true } else { return false } }) else {
            return messages
        }
        return Array(messages[...index])
    }

    /// Every decimal parameter in the escape sequences of `text`.
    private static func numericParameters(in text: String) -> [Int] {
        var numbers: [Int] = []
        var current = ""
        for character in text {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                numbers.append(Int(current) ?? Int.max)
                current = ""
            }
        }
        if !current.isEmpty { numbers.append(Int(current) ?? Int.max) }
        return numbers
    }
}
