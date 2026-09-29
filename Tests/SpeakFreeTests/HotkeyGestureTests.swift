import AppKit
import XCTest
@testable import SpeakFreeLib

/// `HotkeyManager` end to end with synthetic events: the flagsChanged handler that the fn
/// event tap calls, fed CGEvents built in-process (none are posted and no tap is created),
/// with the clock, timer and hardware key-state read injected.
///
/// The first section pins the raw callbacks and the consume-everything disposition that
/// keeps the emoji drawer closed; the rest covers the opt-in gesture intents.
final class HotkeyGestureTests: XCTestCase {
    typealias Intent = KeyGestureRecognizer.Intent

    private final class Recorder {
        var events: [String] = []
        var intents: [Intent] = []
        var sessionActive = false
        var now: TimeInterval = 0
        var physicallyDown = false
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    }

    private var managers: [HotkeyManager] = []

    override func tearDown() {
        for manager in managers {
            manager.primeForTesting(pressed: false, onKeyUp: {})
            manager.stop()
        }
        drainMain()
        managers.removeAll()
        super.tearDown()
    }

    private func makeManager(_ recorder: Recorder,
                             keyCode: UInt16 = KeyCodes.fnKeyCode,
                             gestures mode: KeyGestureRecognizer.Mode? = nil,
                             alternate: Bool = true) -> HotkeyManager {
        let manager = HotkeyManager(keyCode: keyCode)
        manager.physicallyDownRead = { _ in recorder.physicallyDown }
        manager.tapRepairOverride = { .none }   // never create a live tap
        manager.gestureClock = { recorder.now }
        manager.gestureScheduler = { delay, work in recorder.scheduled.append((delay, work)) }
        let gestures = mode.map { mode in
            HotkeyManager.Gestures(
                mode: mode,
                configuration: .init(alternateEnabled: alternate),
                isSessionActive: { recorder.sessionActive },
                onIntent: { intent in
                    recorder.intents.append(intent)
                    switch intent {
                    case .begin: recorder.sessionActive = true
                    case .end, .discard: recorder.sessionActive = false
                    case .retarget: break
                    }
                })
        }
        manager.configureForTesting(
            onKeyDown: { recorder.events.append("down") },
            onKeyUp: { recorder.events.append("up") },
            onAbort: { recorder.events.append("abort") },
            gestures: gestures)
        managers.append(manager)
        return manager
    }

    /// Runs every block already queued on the main queue (the manager hands events from
    /// the tap thread to the main queue).
    private func drainMain() {
        let exp = expectation(description: "main queue drained")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    private func fnEvent(down: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCodes.fnKeyCode), keyDown: down)!
        event.type = .flagsChanged
        event.flags = down ? .maskSecondaryFn : []
        return event
    }

    /// Feeds one fn transition at `time` and returns whether the event reached the OS.
    @discardableResult
    private func fn(_ manager: HotkeyManager, _ recorder: Recorder, down: Bool,
                    at time: TimeInterval, physicallyDown: Bool? = nil) -> Bool {
        recorder.now = time
        recorder.physicallyDown = physicallyDown ?? down
        let passed = manager.handleCGEvent(type: .flagsChanged, event: fnEvent(down: down)) != nil
        drainMain()
        return passed
    }

    // MARK: - Raw callbacks and disposition

    func testFnPressAndReleaseFireTheRawCallbacksAndAreConsumed() {
        let recorder = Recorder()
        let manager = makeManager(recorder)
        XCTAssertFalse(fn(manager, recorder, down: true, at: 0))
        XCTAssertFalse(fn(manager, recorder, down: false, at: 1))
        XCTAssertEqual(recorder.events, ["down", "up"])
        XCTAssertEqual(recorder.intents, [], "gestures are off by default")
    }

    func testRedundantFnTransitionsAreConsumedWithoutCallbacks() {
        let recorder = Recorder()
        let manager = makeManager(recorder)
        XCTAssertFalse(fn(manager, recorder, down: false, at: 0), "up while idle")
        fn(manager, recorder, down: true, at: 1)
        XCTAssertFalse(fn(manager, recorder, down: true, at: 2), "down while down")
        XCTAssertEqual(recorder.events, ["down"])
    }

    /// The phantom-release guard reads the hardware through the injectable seam: a release
    /// while the key is still physically down is swallowed, and the flap's down is absorbed.
    func testPhantomReleaseIsSwallowedThroughTheSeam() {
        let recorder = Recorder()
        let manager = makeManager(recorder)
        fn(manager, recorder, down: true, at: 0)
        XCTAssertFalse(fn(manager, recorder, down: false, at: 0.5, physicallyDown: true))
        XCTAssertFalse(fn(manager, recorder, down: true, at: 0.51))
        fn(manager, recorder, down: false, at: 2)
        XCTAssertEqual(recorder.events, ["down", "up"])
    }

    func testNonModifierHotkeyIgnoresKeyRepeat() throws {
        let recorder = Recorder()
        let manager = makeManager(recorder, keyCode: 0, gestures: .toggle)
        func key(_ type: NSEvent.EventType, repeating: Bool) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: repeating, keyCode: 0))
        }
        manager.handleNSEvent(try key(.keyDown, repeating: false))
        manager.handleNSEvent(try key(.keyDown, repeating: true))
        manager.handleNSEvent(try key(.keyDown, repeating: true))
        manager.handleNSEvent(try key(.keyUp, repeating: false))
        XCTAssertEqual(recorder.events, ["down", "up"], "a held key must not toggle on every repeat")
        XCTAssertEqual(recorder.intents, [.begin(.primary)])
    }

    // MARK: - Gestures: toggle

    func testToggleDoubleTapRetargetsWhileEveryEventStaysConsumed() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .toggle)
        let passed = [
            fn(manager, recorder, down: true, at: 0),
            fn(manager, recorder, down: false, at: 0.1),
            fn(manager, recorder, down: true, at: 0.3),
            fn(manager, recorder, down: false, at: 0.4),
            fn(manager, recorder, down: true, at: 4),
            fn(manager, recorder, down: false, at: 4.1),
        ]
        XCTAssertEqual(passed, Array(repeating: false, count: 6), "no fn event reaches the OS")
        XCTAssertEqual(recorder.intents, [.begin(.primary), .retarget(.alternate), .end])
        XCTAssertEqual(recorder.events, ["down", "up", "down", "up", "down", "up"],
                       "the raw callbacks keep firing alongside the intents")
    }

    func testToggleWithAlternateOffStopsOnTheSecondTap() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .toggle, alternate: false)
        fn(manager, recorder, down: true, at: 0)
        fn(manager, recorder, down: false, at: 0.1)
        fn(manager, recorder, down: true, at: 0.3)
        XCTAssertEqual(recorder.intents, [.begin(.primary), .end])
    }

    /// The Globe workaround's residue: when the phantom guard swallows a genuine release
    /// (a wrong hardware read), `modifierPressed` stays set and the next press is absorbed.
    /// The recognizer then sees one long press, never a double tap, so it cannot retarget
    /// by mistake; the take still ends within the same two taps plain toggle needs.
    func testSwallowedReleaseNeverReadsAsADoubleTap() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .toggle)
        fn(manager, recorder, down: true, at: 0)
        fn(manager, recorder, down: false, at: 0.1, physicallyDown: true)  // misread: swallowed
        fn(manager, recorder, down: true, at: 0.25)                        // absorbed
        fn(manager, recorder, down: false, at: 0.3)                        // delivered as the release
        XCTAssertEqual(recorder.intents, [.begin(.primary)], "no retarget from a swallowed release")
        fn(manager, recorder, down: true, at: 0.45)
        XCTAssertEqual(recorder.intents, [.begin(.primary), .end])
    }

    // MARK: - Gestures: hold

    func testHoldTapThenHoldRetargetsAndReleaseEnds() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .hold)
        fn(manager, recorder, down: true, at: 0)
        fn(manager, recorder, down: false, at: 0.1)
        XCTAssertEqual(recorder.scheduled.count, 1, "a pending tap arms the expiry timer")
        fn(manager, recorder, down: true, at: 0.3)
        fn(manager, recorder, down: false, at: 3)
        recorder.scheduled.forEach { $0.work() }   // a stale timer must do nothing
        XCTAssertEqual(recorder.intents, [.begin(.primary), .retarget(.alternate), .end])
    }

    func testHoldLoneTapIsDiscardedByTheTimer() throws {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .hold)
        fn(manager, recorder, down: true, at: 0)
        fn(manager, recorder, down: false, at: 0.1)
        let timer = try XCTUnwrap(recorder.scheduled.first)
        XCTAssertEqual(timer.delay, 0.3, accuracy: 1e-9)
        recorder.now = 0.4
        timer.work()
        XCTAssertEqual(recorder.intents, [.begin(.primary), .discard])
    }

    func testStopSettlesAPendingTap() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .hold)
        fn(manager, recorder, down: true, at: 0)
        fn(manager, recorder, down: false, at: 0.1)
        manager.stop()
        drainMain()
        XCTAssertEqual(recorder.intents, [.begin(.primary), .discard])
    }

    func testStopWhilePressedEndsTheTake() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .hold)
        fn(manager, recorder, down: true, at: 0)
        recorder.now = 2
        manager.stop()
        drainMain()
        XCTAssertEqual(recorder.intents, [.begin(.primary), .end])
    }

    func testReconciledReleaseEndsAHoldTake() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .hold)
        fn(manager, recorder, down: true, at: 0)
        recorder.now = 5
        recorder.physicallyDown = false
        manager.handleSystemResume("test")
        drainMain()
        XCTAssertEqual(recorder.intents, [.begin(.primary), .end])
    }

    func testShortcutAbortResetsTheGesture() {
        let recorder = Recorder()
        let manager = makeManager(recorder, gestures: .hold)
        fn(manager, recorder, down: true, at: 0)
        manager.abortForShortcut()
        XCTAssertEqual(recorder.events, ["down", "abort"])
        recorder.sessionActive = false
        // The aborted press's release is absorbed; the next press begins again.
        fn(manager, recorder, down: false, at: 0.1)
        fn(manager, recorder, down: true, at: 0.2)
        XCTAssertEqual(recorder.intents, [.begin(.primary), .begin(.primary)])
    }
}
