import XCTest
@testable import SpeakFreeLib

/// Local API dictation control: the session state machine, the caller destination, and the SSE
/// framing. The recording pipeline is a stub driver that reports back through the same
/// `pipeline…` hooks AppDelegate calls, so no microphone, model, or AppKit is involved.
final class DictationControlTests: XCTestCase {

    /// Stands in for AppDelegate: records calls and lets each test script the pipeline's reports.
    final class StubDriver: DictationDriver {
        weak var center: DictationControlCenter?
        var isDictating = false
        var activeEngineID = "parakeet"
        var inputLevel: Float = 0.5
        var startFailure: String?
        var started: [(UUID, DictationAPIDestination)] = []
        var stops = 0
        var cancels = 0
        private var current: UUID?

        func startAPIDictation(sessionID: UUID, destination: DictationAPIDestination) -> String? {
            if let failure = startFailure { return failure }
            started.append((sessionID, destination))
            current = sessionID
            isDictating = true
            center?.pipelineDidStartRecording(sessionID: sessionID)
            return nil
        }

        func stopAPIDictation() {
            stops += 1
            isDictating = false
            center?.pipelineDidBeginTranscribing(sessionID: current)
        }

        func cancelAPIDictation() {
            cancels += 1
            isDictating = false
            center?.pipelineDidCancel(sessionID: current)
            current = nil
        }
    }

    private var center: DictationControlCenter!
    private var driver: StubDriver!
    private var frames: [String] = []

    override func setUp() {
        super.setUp()
        center = DictationControlCenter()
        driver = StubDriver()
        driver.center = center
        center.driver = driver
        frames = []
    }

    private func subscribe() { _ = center.subscribe { [unowned self] in self.frames.append($0) } }

    private func states() -> [String] {
        frames.compactMap { frame -> String? in
            guard frame.hasPrefix("event: state\n") else { return nil }
            let data = frame.components(separatedBy: "\n")[1].dropFirst("data: ".count)
            let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
            return obj?["state"] as? String
        }
    }

    private func startSession(_ destination: DictationAPIDestination = .caller) throws -> DictationSession {
        try center.start(destination: destination, engine: nil, timeoutMs: nil).get()
    }

    // MARK: - Caller destination

    func testCallerSessionStopReturnsTextAfterTranscription() throws {
        let session = try startSession(.caller)
        XCTAssertEqual(session.phase, .recording)
        XCTAssertEqual(driver.started.first?.1, .caller)

        var delivered: DictationSession?
        XCTAssertNil(center.stop(id: session.id) { delivered = $0 })
        XCTAssertEqual(driver.stops, 1)
        XCTAssertNil(delivered, "stop must wait for the transcription, not answer immediately")
        XCTAssertEqual(center.session(id: session.id)?.phase, .transcribing)

        let payload = CallerFinalizePayload(sessionID: session.id, raw: "hello world",
                                            processed: "hello world", styled: "Hello world.")
        center.pipelineDidFinish(sessionID: session.id, result: payload)

        XCTAssertEqual(delivered?.phase, .done)
        XCTAssertEqual(delivered?.result, payload)
        XCTAssertNil(center.activeSessionID)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(DictationControlCenter.sessionJSON(delivered!).utf8)) as? [String: Any])
        XCTAssertEqual(json["raw"] as? String, "hello world")
        XCTAssertEqual(json["processed"] as? String, "hello world")
        XCTAssertEqual(json["styled"] as? String, "Hello world.")
        XCTAssertEqual(json["state"] as? String, "done")
    }

    func testCursorSessionNeverExposesText() throws {
        let session = try startSession(.cursor)
        var delivered: DictationSession?
        _ = center.stop(id: session.id) { delivered = $0 }
        // Cursor takes insert at the cursor; AppDelegate reports no payload.
        center.pipelineDidFinish(sessionID: session.id, result: nil)
        XCTAssertEqual(delivered?.phase, .done)
        let json = DictationControlCenter.sessionJSON(delivered!)
        XCTAssertFalse(json.contains("styled"), json)
    }

    func testStopOnFinishedSessionIsIdempotent() throws {
        let session = try startSession()
        _ = center.stop(id: session.id) { _ in }
        center.pipelineDidFinish(sessionID: session.id, result: nil)
        var again: DictationSession?
        XCTAssertNil(center.stop(id: session.id) { again = $0 })
        XCTAssertEqual(again?.phase, .done)
        XCTAssertEqual(driver.stops, 1, "a second stop must not touch the recorder")
    }

    func testPipelineFailureSettlesSessionWithError() throws {
        let session = try startSession()
        var delivered: DictationSession?
        _ = center.stop(id: session.id) { delivered = $0 }
        center.pipelineDidFail(sessionID: session.id, message: "No speech captured")
        XCTAssertEqual(delivered?.phase, .error)
        XCTAssertEqual(delivered?.error, "No speech captured")
    }

    // MARK: - Start preconditions

    func testSecondStartWhileActiveIsBusy() throws {
        _ = try startSession()
        XCTAssertEqual(center.start(destination: .caller, engine: nil, timeoutMs: nil).failure, .busy)
    }

    func testStartWhileHotkeyDictationIsBusy() {
        driver.isDictating = true
        XCTAssertEqual(center.start(destination: .caller, engine: nil, timeoutMs: nil).failure, .busy)
        XCTAssertTrue(driver.started.isEmpty)
    }

    func testEngineMismatchIsRejectedWithoutRecording() {
        let result = center.start(destination: .caller, engine: "whisper", timeoutMs: nil)
        XCTAssertEqual(result.failure, .engineMismatch(active: "parakeet"))
        XCTAssertTrue(driver.started.isEmpty)
        XCTAssertNoThrow(try center.start(destination: .caller, engine: "parakeet", timeoutMs: nil).get())
    }

    func testStartFailureSettlesAndFreesTheSlot() {
        driver.startFailure = "Recording did not start"
        XCTAssertEqual(center.start(destination: .caller, engine: nil, timeoutMs: nil).failure,
                       .startFailed("Recording did not start"))
        XCTAssertNil(center.activeSessionID)
        driver.startFailure = nil
        XCTAssertNoThrow(try startSession())
    }

    func testNoDriverIsNotReady() {
        center.driver = nil
        XCTAssertEqual(center.start(destination: .caller, engine: nil, timeoutMs: nil).failure, .notReady)
    }

    func testTimeoutStopsRecording() throws {
        _ = try center.start(destination: .caller, engine: nil, timeoutMs: 20).get()
        let exp = expectation(description: "timeout stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(driver.stops, 1)
    }

    // MARK: - Cancel

    func testCancelWhileRecordingAbortsTake() throws {
        let session = try startSession()
        XCTAssertEqual(try center.cancel(id: session.id).get().phase, .cancelled)
        XCTAssertEqual(driver.cancels, 1)
        XCTAssertNil(center.activeSessionID)
    }

    func testCancelCallerWhileTranscribingDropsResult() throws {
        let session = try startSession(.caller)
        _ = center.stop(id: session.id) { _ in }
        XCTAssertEqual(try center.cancel(id: session.id).get().phase, .cancelled)
        center.pipelineDidFinish(sessionID: session.id, result: CallerFinalizePayload(
            sessionID: session.id, raw: "late", processed: "late", styled: "Late."))
        XCTAssertEqual(center.session(id: session.id)?.phase, .cancelled)
        XCTAssertNil(center.session(id: session.id)?.result, "a cancelled session must not keep late text")
    }

    func testCancelCursorWhileTranscribingIsRefused() throws {
        let session = try startSession(.cursor)
        _ = center.stop(id: session.id) { _ in }
        XCTAssertEqual(center.cancel(id: session.id).failure, .invalidTransition(.transcribing))
    }

    func testUnknownSessionIsNotFound() {
        XCTAssertEqual(center.cancel(id: UUID()).failure, .notFound)
        XCTAssertEqual(center.stop(id: UUID()) { _ in }, .notFound)
        XCTAssertNil(center.session(id: UUID()))
    }

    // MARK: - Event stream

    func testSubscriberGetsCurrentStateThenLifecycle() throws {
        subscribe()
        XCTAssertEqual(states(), ["idle"])
        let session = try startSession()
        _ = center.stop(id: session.id) { _ in }
        center.pipelineDidFinish(sessionID: session.id, result: nil)
        XCTAssertEqual(states(), ["idle", "recording", "transcribing", "done", "idle"])
        XCTAssertTrue(frames[1].contains(session.id.uuidString))
    }

    func testHotkeyDictationsAlsoStreamWithNullID() {
        subscribe()
        center.pipelineDidStartRecording(sessionID: nil)
        center.pipelineDidBeginTranscribing(sessionID: nil)
        center.pipelineDidFail(sessionID: nil, message: "Recording too short")
        XCTAssertEqual(states(), ["idle", "recording", "transcribing", "error", "idle"])
        XCTAssertTrue(frames[1].contains(#""id":null"#), frames[1])
        XCTAssertTrue(frames[3].contains("Recording too short"))
    }

    func testEventsNeverCarryTranscriptText() throws {
        subscribe()
        let session = try startSession(.caller)
        _ = center.stop(id: session.id) { _ in }
        center.pipelineDidFinish(sessionID: session.id, result: CallerFinalizePayload(
            sessionID: session.id, raw: "secret words", processed: "secret words", styled: "Secret words."))
        XCTAssertFalse(frames.joined().lowercased().contains("secret"))
    }

    func testLevelSamplesOnlyWhileRecording() throws {
        subscribe()
        center.sampleLevel()
        XCTAssertFalse(frames.contains { $0.hasPrefix("event: level") }, "no level while idle")
        _ = try startSession()
        driver.inputLevel = 0.25
        center.sampleLevel()
        XCTAssertEqual(frames.last, DictationControlCenter.levelFrame(0.25, sessionID: center.activeSessionID))
        XCTAssertTrue(frames.last!.contains(#""level":0.25"#), frames.last!)
    }

    func testLevelTimerRunsAtAboutTenHertz() throws {
        subscribe()
        _ = try startSession()
        let exp = expectation(description: "level samples")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let levels = frames.filter { $0.hasPrefix("event: level") }.count
        XCTAssertTrue((3...7).contains(levels), "expected ~5 samples in 0.55 s, got \(levels)")
    }

    func testUnsubscribeStopsDelivery() {
        let token = center.subscribe { [unowned self] in self.frames.append($0) }
        center.unsubscribe(token)
        center.pipelineDidStartRecording(sessionID: nil)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(center.subscriberCount, 0)
    }

    // MARK: - SSE framing

    func testSSEFrameShape() {
        XCTAssertEqual(DictationControlCenter.sseFrame(event: "state", data: #"{"state":"idle"}"#),
                       "event: state\ndata: {\"state\":\"idle\"}\n\n")
        XCTAssertEqual(DictationControlCenter.sseFrame(event: nil, data: "x"), "data: x\n\n")
    }

    func testSSEFrameSplitsMultilineData() {
        XCTAssertEqual(DictationControlCenter.sseFrame(event: "e", data: "a\nb\r\nc"),
                       "event: e\ndata: a\ndata: b\ndata: c\n\n",
                       "a raw newline inside data would end the event early")
    }

    func testLevelFrameClampsAndRounds() {
        XCTAssertTrue(DictationControlCenter.levelFrame(1.7, sessionID: nil).contains(#""level":1"#))
        XCTAssertTrue(DictationControlCenter.levelFrame(-1, sessionID: nil).contains(#""level":0"#))
        XCTAssertTrue(DictationControlCenter.levelFrame(0.123456, sessionID: nil).contains(#""level":0.123"#))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
