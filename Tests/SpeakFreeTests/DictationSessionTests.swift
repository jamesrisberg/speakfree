import AppKit
import XCTest
@testable import SpeakFreeLib

private final class SessionTestCapture: DeviceCapturing {
    var deliver: ((CapturePacket) -> Void)?
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
               failure: @escaping (String) -> Void) { deliver = packet }
    func stop() {}
}

/// Drives a whole `DictationSession` take — capture, post-buffer, transcription, text pipeline and
/// delivery — with a fake capture device, a scripted engine and an inserter whose output seam
/// records text instead of typing. No microphone, model, AX query or real keystroke is involved.
@MainActor
final class DictationSessionTests: XCTestCase {
    private var directory: URL!
    private var previousConfigDirectory: URL?
    private var capture: SessionTestCapture!
    private var recorder: AudioRecorder!
    private var engine: FakeScriptedEngine!
    private var inserter: TextInserter!
    private var inserted: [String] = []
    private var session: DictationSession!
    private var events: [DictationEvent] = []
    private var microphoneAllowed = true

    private let spokenText = "hello from the session test"

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configDirectory = directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        previousConfigDirectory = Config.configDirOverride
        Config.configDirOverride = configDirectory

        let device = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in", isBuiltIn: true,
                                      isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
        let capture = SessionTestCapture()
        self.capture = capture
        recorder = AudioRecorder(factory: { capture })
        recorder.capture.configure(devices: [device], systemDefault: device, pin: nil, prelisten: true)
        recorder.capture.start()
        recorder.capture.queue.sync {}

        engine = FakeScriptedEngine(engineID: "whisper", supportsStreaming: false, scriptedFinal: spokenText)
        inserted = []
        inserter = TextInserter()
        inserter.isSecureInputActive = { false }
        inserter.focusedElementProvider = { nil }
        inserter.frontmostBundleIDProvider = { nil }
        inserter.pasteboard = NSPasteboard(name: NSPasteboard.Name("DictationSessionTests-\(UUID())"))
        inserter.performInsertion = { [weak self] text in self?.inserted.append(text) }

        microphoneAllowed = true
        var environment = DictationSession.Environment()
        environment.requestMicrophone = { [weak self] in self?.microphoneAllowed ?? false }
        environment.frontmostApplication = { nil }
        environment.readCursorContext = { _ in (nil, nil) }
        environment.captureScreenText = { nil }
        session = DictationSession(recorder: recorder, inserter: inserter, environment: environment)
        session.transcriber = Transcriber(engine: engine, modelID: "base.en", language: "en")
        session.engineID = "whisper"
        var configuration = DictationConfiguration()
        configuration.streamingEnabled = false
        session.configuration = configuration
        session.isEnabled = true
        events = []
        _ = session.addObserver { [weak self] _, event in
            if case .inputLevel = event { return }
            self?.events.append(event)
        }
    }

    override func tearDown() async throws {
        session.cancel()
        recorder.shutdown()
        recorder.capture.queue.sync {}
        Config.configDirOverride = previousConfigDirectory
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// One second of a voiced tone: passes the length and silence gates.
    private func speak(seconds: Double = 1, at start: Double = 0) {
        let count = Int(seconds * 16_000)
        let samples = (0..<count).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
        capture.deliver?(CapturePacket(start: start, samples: samples))
        recorder.capture.queue.sync {}
    }

    private struct TakeDidNotStart: Error {}

    private func start(_ destination: DictationDestination) throws -> UUID {
        guard case .started(let id) = session.start(destination: destination) else {
            throw TakeDidNotStart()
        }
        return id
    }

    // MARK: - Destinations

    func testCursorTakeInsertsTheStyledTextAtTheCursor() async throws {
        _ = try start(.cursor)
        XCTAssertTrue(session.isRecording)
        speak()
        let result = try await session.stop()

        XCTAssertEqual(result.destination, .cursor)
        XCTAssertEqual(result.delivery, .inserted)
        XCTAssertEqual(result.raw, spokenText)
        XCTAssertFalse(result.styled.isEmpty)
        XCTAssertEqual(inserted, [result.styled])
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(events.first, .preparing)
        XCTAssertEqual(Array(events.prefix(3)), [.preparing, .starting, .recording])
        XCTAssertTrue(events.contains(.released))
        XCTAssertTrue(events.contains(.captureEnded))
        XCTAssertTrue(events.contains(.transcribing))
        XCTAssertTrue(events.contains(.delivering(.cursor)))
        XCTAssertEqual(events.last, .finished(result))
    }

    func testCallerTakeReturnsTheTextAndTypesNothing() async throws {
        _ = try start(.caller)
        speak()
        let result = try await session.stop()

        XCTAssertEqual(result.destination, .caller)
        XCTAssertEqual(result.delivery, .returnedToCaller)
        XCTAssertEqual(result.raw, spokenText)
        XCTAssertFalse(result.processed.isEmpty)
        XCTAssertFalse(result.styled.isEmpty)
        XCTAssertTrue(inserted.isEmpty, "a caller take must never reach the inserter")
        XCTAssertTrue(events.contains(.delivering(.caller)))
    }

    func testRetargetToCallerMidRecordingReturnsTheText() async throws {
        let id = try start(.cursor)
        speak(seconds: 0.5)
        XCTAssertTrue(session.retarget(to: .caller))
        XCTAssertEqual(session.currentDestination, .caller)
        speak(seconds: 0.5, at: 0.5)
        let result = try await session.stop()

        XCTAssertEqual(result.takeID, id)
        XCTAssertEqual(result.destination, .caller)
        XCTAssertEqual(result.delivery, .returnedToCaller)
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertTrue(events.contains(.retargeted(.caller)))
    }

    func testRetargetToCursorMidRecordingInserts() async throws {
        _ = try start(.caller)
        speak(seconds: 0.5)
        XCTAssertTrue(session.retarget(to: .cursor))
        speak(seconds: 0.5, at: 0.5)
        let result = try await session.stop()

        XCTAssertEqual(result.destination, .cursor)
        XCTAssertEqual(result.delivery, .inserted)
        XCTAssertEqual(inserted, [result.styled])
    }

    func testRetargetIsRefusedWhenNothingIsCapturing() async throws {
        XCTAssertFalse(session.retarget(to: .caller))
        _ = try start(.cursor)
        speak()
        _ = try await session.stop()
        XCTAssertFalse(session.retarget(to: .caller), "the destination is fixed once finalize began")
    }

    // MARK: - Start preconditions

    func testStartIsRefusedWhileDisabled() {
        session.isEnabled = false
        XCTAssertEqual(session.start(destination: .cursor), .refused(.notReady))
        XCTAssertFalse(session.isCapturing)
        XCTAssertTrue(events.isEmpty)
    }

    func testStartIsRefusedWithoutMicrophoneAccess() {
        microphoneAllowed = false
        XCTAssertEqual(session.start(destination: .cursor), .refused(.microphoneUnavailable))
        XCTAssertFalse(session.isCapturing)
        XCTAssertTrue(events.isEmpty)
    }

    func testSecondStartWhileRecordingIsBusy() throws {
        _ = try start(.cursor)
        XCTAssertEqual(session.start(destination: .caller), .refused(.busy))
    }

    // MARK: - Failures and cancel

    func testTooShortTakeFailsWithoutDelivering() async {
        _ = session.start(destination: .caller)
        capture.deliver?(CapturePacket(start: 0, samples: Array(repeating: 0.2, count: 800)))
        recorder.capture.queue.sync {}
        do {
            _ = try await session.stop()
            XCTFail("a 50 ms take must fail the length gate")
        } catch {
            XCTAssertEqual(error as? DictationFailure, .tooShort)
        }
        XCTAssertEqual(events.last, .failed(.tooShort))
        XCTAssertTrue(inserted.isEmpty)
    }

    func testEngineErrorFailsTheTake() async throws {
        engine.error = TranscriptionEngineError.modelAssetsMissing("parakeet")
        engine.engineID = "parakeet"
        _ = try start(.cursor)
        speak()
        do {
            _ = try await session.stop()
            XCTFail("the engine threw")
        } catch let failure as DictationFailure {
            guard case .modelMissing = failure else { return XCTFail("got \(failure)") }
            XCTAssertEqual(failure.message, "Model not downloaded")
        }
        XCTAssertTrue(inserted.isEmpty)
    }

    func testCancelDiscardsTheTake() throws {
        _ = try start(.cursor)
        speak()
        XCTAssertTrue(session.cancel())
        XCTAssertFalse(session.isCapturing)
        XCTAssertEqual(events.last, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingStore.sentinelFile.path))
        XCTAssertFalse(session.cancel(), "nothing left to cancel")
    }

    func testStopWithNothingRecordingFails() async {
        do {
            _ = try await session.stop()
            XCTFail("nothing was recording")
        } catch {
            XCTAssertEqual(error as? DictationFailure, .notRecording)
        }
    }

    // MARK: - Local API control through the session

    func testControlCenterCallerSessionRunsThroughTheSession() throws {
        let center = DictationControlCenter()
        center.attach(to: session)
        let apiSession = try center.start(destination: .caller, engine: nil, timeoutMs: nil).get()
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(session.currentTakeID, apiSession.id)
        speak()

        let done = expectation(description: "stop answers after transcription")
        var delivered: DictationAPISession?
        XCTAssertNil(center.stop(id: apiSession.id) { delivered = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(delivered?.phase, .done)
        XCTAssertEqual(delivered?.result?.raw, spokenText)
        XCTAssertTrue(inserted.isEmpty)
    }

    func testControlCenterCancelDiscardsTheTake() throws {
        let center = DictationControlCenter()
        center.attach(to: session)
        let apiSession = try center.start(destination: .cursor, engine: nil, timeoutMs: nil).get()
        speak()
        XCTAssertEqual(try center.cancel(id: apiSession.id).get().phase, .cancelled)
        XCTAssertFalse(session.isCapturing)
        XCTAssertTrue(inserted.isEmpty)
    }

    func testControlCenterReportsTheSessionEngine() {
        let center = DictationControlCenter()
        center.attach(to: session)
        session.engineID = "parakeet"
        XCTAssertEqual(center.start(destination: .caller, engine: "whisper", timeoutMs: nil).failure,
                       .engineMismatch(active: "parakeet"))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
