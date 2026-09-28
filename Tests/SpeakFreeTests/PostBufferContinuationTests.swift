import XCTest
@testable import SpeakFreeLib

private final class PostBufferCapture: DeviceCapturing {
    var deliver: ((CapturePacket) -> Void)?
    func start(device: AudioInputDevice, packet: @escaping (CapturePacket) -> Void,
               failure: @escaping (String) -> Void) { deliver = packet }
    func stop() {}
}

/// Exercise the session's press/release/abort and post-buffer timer paths without starting
/// inference or desktop UI: finalize is replaced by a hook that only stops the recorder.
@MainActor
final class PostBufferContinuationTests: XCTestCase {
    private func withRecording(_ body: (DictationSession, AudioRecorder, PostBufferCapture, URL) throws -> Void) throws {
        let device = AudioInputDevice(id: 1, uid: "built-in", name: "Built-in", isBuiltIn: true,
                                     isBluetooth: false, nominalSampleRate: 48_000, inputChannels: 1)
        let capture = PostBufferCapture()
        let recorder = AudioRecorder(factory: { capture })
        recorder.capture.configure(devices: [device], systemDefault: device, pin: nil, prelisten: true)
        recorder.capture.start()
        recorder.capture.queue.sync {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configDirectory = directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let previousConfigDirectory = Config.configDirOverride
        Config.configDirOverride = configDirectory
        defer {
            recorder.shutdown()
            recorder.capture.queue.sync {}
            Config.configDirOverride = previousConfigDirectory
            try? FileManager.default.removeItem(at: directory)
        }
        var environment = DictationSession.Environment()
        environment.requestMicrophone = { true }
        environment.frontmostApplication = { nil }
        environment.readCursorContext = { _ in (nil, nil) }
        environment.captureScreenText = { nil }
        let inserter = TextInserter()
        inserter.frontmostBundleIDProvider = { nil }
        let session = DictationSession(recorder: recorder, inserter: inserter, environment: environment)
        var configuration = DictationConfiguration()
        configuration.streamingEnabled = false
        session.configuration = configuration
        session.isEnabled = true
        guard case .started = session.start(destination: .cursor) else {
            return XCTFail("the take did not start")
        }
        let url = try XCTUnwrap(session.currentAudioURL)
        try body(session, recorder, capture, url)
    }

    private func assertWAV(_ url: URL, contains samples: [Float], file: StaticString = #filePath,
                           line: UInt = #line) throws {
        let decoded = try ProcessCommand.loadSamples(from: url)
        XCTAssertEqual(decoded.count, samples.count, file: file, line: line)
        // WAV archives are s16: retain every sample in order within its quantization step.
        let largestError = zip(decoded, samples).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(largestError, 1.0 / 32768.0, file: file, line: line)
    }

    func testRepressContinuesSameTakeAndOnlyNextReleaseCanFinalize() throws {
        try withRecording { session, recorder, capture, url in
            let first = Array(repeating: Float(0.25), count: 1600)
            capture.deliver?(CapturePacket(start: 0, samples: first))
            recorder.capture.queue.sync {}
            let obsoleteFinalization = expectation(description: "The old release must not finalize the held take")
            obsoleteFinalization.isInverted = true
            session._finalizeOverride = { _ in
                obsoleteFinalization.fulfill()
                _ = recorder.stopRecording()
            }
            session.stopRecording()
            // The continuation returns before focus capture, another sentinel/WAV, or another
            // call to recorder.startRecording.
            XCTAssertEqual(session.start(destination: .cursor), .resumed(try XCTUnwrap(session.currentTakeID)))
            XCTAssertTrue(session.isRecording)
            // Below the silence threshold: an obsolete timer would finalize at 90 ms,
            // comfortably inside the inverted wait (speech would extend it to 1.2 s).
            let continued = Array(repeating: Float(0.005), count: 1600)
            capture.deliver?(CapturePacket(start: 0.1, samples: continued))
            wait(for: [obsoleteFinalization], timeout: 0.3)
            XCTAssertTrue(session.isRecording)
            XCTAssertEqual(recorder.currentSamples(), first + continued)
            XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStore.sentinelFile.path))

            let newFinalization = expectation(description: "The next release finalizes once")
            var result: (url: URL, samples: [Float])?
            var finalizations = 0
            session._finalizeOverride = { _ in
                finalizations += 1
                result = recorder.stopRecording()
                newFinalization.fulfill()
            }
            session.stopRecording()
            let silence = Array(repeating: Float(0), count: 1440)
            capture.deliver?(CapturePacket(start: 0.2, samples: silence))
            wait(for: [newFinalization], timeout: 1)
            XCTAssertEqual(finalizations, 1)
            XCTAssertEqual(result?.url, url)
            XCTAssertEqual(result?.samples, first + continued + silence)
            try assertWAV(url, contains: first + continued + silence)
            let wavs = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                   includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }
            XCTAssertEqual(wavs.map(\.lastPathComponent), [url.lastPathComponent])
        }
    }

    func testShortcutAbortOfContinuationPreservesReleasedTakeAndFinalizesNormally() throws {
        try withRecording { session, recorder, capture, url in
            let first = Array(repeating: Float(0.25), count: 1600)
            capture.deliver?(CapturePacket(start: 0, samples: first))
            recorder.capture.queue.sync {}
            session._finalizeOverride = { _ in XCTFail("the first release was superseded") }
            session.stopRecording()
            session.start(destination: .cursor)
            let finalized = expectation(description: "Canceling only the continuation still finalizes the take")
            var result: (url: URL, samples: [Float])?
            session._finalizeOverride = { _ in
                result = recorder.stopRecording()
                finalized.fulfill()
            }
            session.abortPress()
            XCTAssertFalse(session.isRecording)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStore.sentinelFile.path))
            let silence = Array(repeating: Float(0), count: 1440)
            capture.deliver?(CapturePacket(start: 0.1, samples: silence))
            wait(for: [finalized], timeout: 1)
            XCTAssertEqual(result?.url, url)
            XCTAssertEqual(result?.samples, first + silence)
            try assertWAV(url, contains: first + silence)
        }
    }

    func testShortcutAbortOfFirstPressStillDiscardsTheCanceledTake() throws {
        try withRecording { session, recorder, capture, url in
            capture.deliver?(CapturePacket(start: 0, samples: Array(repeating: 0.25, count: 1600)))
            recorder.capture.queue.sync {}
            let finalized = expectation(description: "A canceled first press must not finalize")
            finalized.isInverted = true
            session._finalizeOverride = { _ in finalized.fulfill() }
            session.abortPress()
            XCTAssertFalse(session.isRecording)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingStore.sentinelFile.path))
            XCTAssertNil(recorder.stopRecording())
            wait(for: [finalized], timeout: 0.3)
        }
    }

    func testCancelDuringPostBufferDiscardsTheReleasedTake() throws {
        try withRecording { session, recorder, capture, url in
            capture.deliver?(CapturePacket(start: 0, samples: Array(repeating: 0.25, count: 1600)))
            recorder.capture.queue.sync {}
            let finalized = expectation(description: "A cancelled release must not finalize")
            finalized.isInverted = true
            session._finalizeOverride = { _ in finalized.fulfill() }
            session.stopRecording()
            XCTAssertTrue(session.isTrailing)
            XCTAssertTrue(session.cancel())
            XCTAssertFalse(session.isCapturing)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNil(recorder.stopRecording())
            wait(for: [finalized], timeout: 0.3)
        }
    }
}
