import XCTest
@testable import SpeakFreeLib

/// The fn gesture recognizer. The first section pins the plain hold/toggle behavior
/// (`AppDelegate.handleKeyDown`/`handleKeyUp` with `isPressed` as the session) and proves
/// the recognizer with the alternate gesture off reproduces it; the rest covers the
/// alternate gesture.
final class KeyGestureRecognizerTests: XCTestCase {
    typealias R = KeyGestureRecognizer

    private enum Event {
        case down(TimeInterval)
        case up(TimeInterval)
        case expire(TimeInterval)
    }

    /// Replays events through a recognizer against a simulated session that follows the
    /// intents, the way a consumer would. Returns the intents per event.
    private func run(_ mode: R.Mode,
                     alternate: Bool,
                     _ events: [Event],
                     sessionActiveAtStart: Bool = false) -> [[R.Intent]] {
        var recognizer = R(mode: mode, configuration: .init(alternateEnabled: alternate))
        var session = sessionActiveAtStart
        return events.map { event in
            let intents: [R.Intent]
            switch event {
            case .down(let t): intents = recognizer.keyDown(at: t, sessionActive: session)
            case .up(let t): intents = recognizer.keyUp(at: t, sessionActive: session)
            case .expire(let t): intents = recognizer.expire(at: t, sessionActive: session)
            }
            for intent in intents {
                switch intent {
                case .begin: session = true
                case .end, .discard: session = false
                case .retarget: break
                }
            }
            return intents
        }
    }

    // MARK: - Plain hold/toggle (alternate off)

    /// The plain key-mode mapping: hold begins on a press when idle and ends on any
    /// release while recording; toggle alternates begin and end on each press and
    /// ignores releases.
    private func plainIntents(_ mode: R.Mode, isDown: Bool, isPressed: Bool) -> [R.Intent] {
        switch (mode, isDown) {
        case (.hold, true): return isPressed ? [] : [.begin(.primary)]
        case (.hold, false): return isPressed ? [.end] : []
        case (.toggle, true): return isPressed ? [.end] : [.begin(.primary)]
        case (.toggle, false): return []
        }
    }

    /// Every alternating press/release sequence up to eight events, with quick and slow
    /// timing, with and without a session already running, in both modes: the recognizer
    /// with the alternate gesture off emits exactly the plain mapping.
    func testAlternateOffMatchesPlainKeyModesExhaustively() {
        for mode in [R.Mode.hold, .toggle] {
            for startActive in [false, true] {
                for gapMask in 0..<(1 << 8) {
                    var recognizer = R(mode: mode)
                    var session = startActive
                    var t: TimeInterval = 0
                    for step in 0..<8 {
                        t += (gapMask >> step) & 1 == 1 ? 0.05 : 1.0
                        let isDown = step.isMultiple(of: 2)
                        let expected = plainIntents(mode, isDown: isDown, isPressed: session)
                        let actual = isDown
                            ? recognizer.keyDown(at: t, sessionActive: session)
                            : recognizer.keyUp(at: t, sessionActive: session)
                        XCTAssertEqual(actual, expected,
                                       "\(mode) startActive=\(startActive) mask=\(gapMask) step=\(step)")
                        XCTAssertNil(recognizer.deadline, "alternate off never needs a timer")
                        for intent in actual {
                            if case .begin = intent { session = true } else { session = false }
                        }
                    }
                }
            }
        }
    }

    func testPlainHoldQuickTapEndsRatherThanDiscards() {
        XCTAssertEqual(run(.hold, alternate: false, [.down(0), .up(0.05)]),
                       [[.begin(.primary)], [.end]])
    }

    func testPlainToggleQuickDoubleTapStartsAndStops() {
        XCTAssertEqual(run(.toggle, alternate: false, [.down(0), .up(0.05), .down(0.10), .up(0.15)]),
                       [[.begin(.primary)], [], [.end], []])
    }

    /// A session can end without the hotkey (watchdog, API, error). The next press must
    /// start a new one, not "stop" the one the recognizer remembers.
    func testSessionEndedElsewhereIsNotStoppedAgain() {
        for mode in [R.Mode.hold, .toggle] {
            var recognizer = R(mode: mode)
            XCTAssertEqual(recognizer.keyDown(at: 0, sessionActive: false), [.begin(.primary)])
            _ = recognizer.keyUp(at: 1, sessionActive: true)
            XCTAssertEqual(recognizer.keyDown(at: 2, sessionActive: false), [.begin(.primary)], "\(mode)")
        }
    }

    // MARK: - Toggle with the alternate gesture

    func testToggleSingleTapBeginsPrimaryAndTheNextTapEnds() {
        XCTAssertEqual(run(.toggle, alternate: true, [.down(0), .up(0.1), .down(3), .up(3.1)]),
                       [[.begin(.primary)], [], [.end], []])
    }

    func testToggleDoubleTapRetargetsAndKeepsRecording() {
        XCTAssertEqual(
            run(.toggle, alternate: true,
                [.down(0), .up(0.1), .down(0.3), .up(0.4), .down(5), .up(5.1)]),
            [[.begin(.primary)], [], [.retarget(.alternate)], [], [.end], []])
    }

    func testToggleSecondTapAfterTheWindowEnds() {
        XCTAssertEqual(run(.toggle, alternate: true, [.down(0), .up(0.1), .down(0.41)]),
                       [[.begin(.primary)], [], [.end]])
    }

    /// A long first press is not a tap, so a quick press after it is an ordinary stop. This
    /// is also what keeps a release delayed by the phantom-release guard from reading as a
    /// double tap.
    func testToggleLongFirstPressDoesNotOpenTheWindow() {
        XCTAssertEqual(run(.toggle, alternate: true, [.down(0), .up(0.5), .down(0.6)]),
                       [[.begin(.primary)], [], [.end]])
    }

    func testToggleNeedsNoTimer() {
        var recognizer = R(mode: .toggle, configuration: .init(alternateEnabled: true))
        _ = recognizer.keyDown(at: 0, sessionActive: false)
        _ = recognizer.keyUp(at: 0.1, sessionActive: true)
        XCTAssertNil(recognizer.deadline)
        XCTAssertEqual(recognizer.expire(at: 10, sessionActive: true), [])
    }

    func testToggleTripleTapEndsOnTheThirdTap() {
        XCTAssertEqual(
            run(.toggle, alternate: true, [.down(0), .up(0.1), .down(0.2), .up(0.25), .down(0.3)]),
            [[.begin(.primary)], [], [.retarget(.alternate)], [], [.end]])
    }

    // MARK: - Hold with the alternate gesture

    func testHoldPressAndReleaseEnds() {
        XCTAssertEqual(run(.hold, alternate: true, [.down(0), .up(2)]),
                       [[.begin(.primary)], [.end]])
    }

    func testHoldTapThenHoldRetargetsAndReleaseEnds() {
        XCTAssertEqual(run(.hold, alternate: true, [.down(0), .up(0.1), .down(0.3), .up(3)]),
                       [[.begin(.primary)], [], [.retarget(.alternate)], [.end]])
    }

    func testHoldLoneQuickTapIsDiscardedWhenTheWindowLapses() {
        var recognizer = R(mode: .hold, configuration: .init(alternateEnabled: true))
        XCTAssertEqual(recognizer.keyDown(at: 0, sessionActive: false), [.begin(.primary)])
        XCTAssertEqual(recognizer.keyUp(at: 0.1, sessionActive: true), [])
        XCTAssertEqual(recognizer.deadline ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(recognizer.expire(at: 0.39, sessionActive: true), [], "early timer is harmless")
        XCTAssertEqual(recognizer.expire(at: 0.41, sessionActive: true), [.discard])
        XCTAssertNil(recognizer.deadline)
        XCTAssertEqual(recognizer.keyDown(at: 1, sessionActive: false), [.begin(.primary)])
    }

    /// The press arrives after the window but before the timer ran: the lone tap is still
    /// discarded, and the press begins a fresh primary session.
    func testHoldLatePressDiscardsTheTapAndBeginsAgain() {
        XCTAssertEqual(run(.hold, alternate: true, [.down(0), .up(0.1), .down(0.5), .up(2)]),
                       [[.begin(.primary)], [], [.discard, .begin(.primary)], [.end]])
    }

    func testHoldQuickSecondTapStillEndsAfterRetarget() {
        XCTAssertEqual(run(.hold, alternate: true, [.down(0), .up(0.1), .down(0.2), .up(0.25)]),
                       [[.begin(.primary)], [], [.retarget(.alternate)], [.end]])
    }

    func testTapMaxDurationBoundaryIsInclusive() {
        XCTAssertEqual(run(.hold, alternate: true, [.down(0), .up(0.2)]), [[.begin(.primary)], []])
        XCTAssertEqual(run(.hold, alternate: true, [.down(0), .up(0.2001)]),
                       [[.begin(.primary)], [.end]])
    }

    func testHoldPendingTapWhoseSessionEndedElsewhereIsNotDiscarded() {
        var recognizer = R(mode: .hold, configuration: .init(alternateEnabled: true))
        _ = recognizer.keyDown(at: 0, sessionActive: false)
        _ = recognizer.keyUp(at: 0.1, sessionActive: true)
        XCTAssertEqual(recognizer.expire(at: 1, sessionActive: false), [])
        XCTAssertNil(recognizer.deadline)
    }

    // MARK: - Shared rules

    func testRepeatedPressWhileDownIsIgnored() {
        for mode in [R.Mode.hold, .toggle] {
            for alternate in [false, true] {
                XCTAssertEqual(run(mode, alternate: alternate, [.down(0), .down(0.5), .down(0.6)]),
                               [[.begin(.primary)], [], []], "\(mode) alternate=\(alternate)")
            }
        }
    }

    func testAbortClearsAPendingGestureAndTheKeyState() {
        var recognizer = R(mode: .hold, configuration: .init(alternateEnabled: true))
        _ = recognizer.keyDown(at: 0, sessionActive: false)
        recognizer.abort()
        XCTAssertNil(recognizer.deadline)
        // The release of the aborted press is never reported; the next press begins.
        XCTAssertEqual(recognizer.keyDown(at: 0.15, sessionActive: false), [.begin(.primary)])
    }

    func testDefaults() {
        let config = R.Configuration()
        XCTAssertFalse(config.alternateEnabled)
        XCTAssertEqual(config.doubleTapWindow, 0.30)
        XCTAssertEqual(config.tapMaxDuration, 0.20)
    }
}
