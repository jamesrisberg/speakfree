import AppKit
import ApplicationServices
import os

// MARK: - Public types

/// Where a take's text goes.
public enum DictationDestination: String, Equatable, Sendable {
    /// Returned to whoever drives the session; nothing is typed.
    case caller
    /// Typed at the cursor through `TextInserter`, refocusing the element focused at record start.
    case cursor
}

/// Why a take did not start or did not produce text. `message` is the wording the local API
/// reports.
public enum DictationFailure: Error, Equatable {
    /// The session is disabled (`isEnabled` is false).
    case notReady
    /// A take is already recording.
    case busy
    /// Microphone access is missing; the permission prompt or alert has been shown.
    case microphoneUnavailable
    /// `stop` was called with nothing recording.
    case notRecording
    /// The recorder could not start.
    case recordingFailed
    /// The recorder stopped without a recording.
    case noAudio
    /// Shorter than `FinalizePipeline.minSamples`: an accidental tap.
    case tooShort
    /// Below the silence threshold: a dead or muted microphone.
    case silent
    /// The capture delivered no audio frames at all.
    case captureFailed
    /// No transcriber is configured.
    case engineNotReady
    /// The engine's model is not downloaded.
    case modelMissing(recordingKept: Bool)
    /// The engine threw. `reason` is the error's localized description.
    case transcriptionFailed(reason: String, recordingKept: Bool)
    /// The take was cancelled before it finished.
    case cancelled

    public var message: String {
        switch self {
        case .notReady: return "speakfree is not ready"
        case .busy: return "A dictation is already in progress"
        case .microphoneUnavailable: return "Recording did not start (check microphone permission)"
        case .notRecording: return "No dictation is recording"
        case .recordingFailed: return "Recording failed: check your microphone"
        case .noAudio: return "No audio was captured"
        case .tooShort: return "Recording too short"
        case .silent: return "No speech captured"
        case .captureFailed: return "Capture failed"
        case .engineNotReady: return "Transcription engine not ready"
        case .modelMissing: return "Model not downloaded"
        case .transcriptionFailed: return "Transcription failed"
        case .cancelled: return "Dictation cancelled"
        }
    }
}

/// What happened to a finished take's text.
public enum DictationDelivery: Equatable, Sendable {
    /// Handed to the inserter at the cursor.
    case inserted
    /// The inserter could not type it (focus lost or Secure Input) and put it on the clipboard.
    case copiedToClipboard
    /// The transcript was empty; nothing was typed.
    case nothingToInsert
    /// Returned to the caller; nothing was typed.
    case returnedToCaller
    /// Delivered to an open edit session.
    case editSession
}

/// A finished take.
public struct DictationResult: Equatable, Sendable {
    public let takeID: UUID
    public let destination: DictationDestination
    /// The engine transcript.
    public let raw: String
    /// Spoken punctuation, glossary and overrides applied.
    public let processed: String
    /// The final text: what is typed at the cursor.
    public let styled: String
    public let delivery: DictationDelivery
    /// The take's WAV. It no longer exists when `recordingKept` is false.
    public let audioURL: URL
    public let recordingKept: Bool
    public let audioDuration: TimeInterval
}

/// The inserter could not type the text normally.
public enum DictationDeliveryFallback: Equatable, Sendable {
    /// Secure Input blocked typing; the text is on the concealed clipboard and was not inserted.
    case secureInput(text: String)
    /// An accessibility write timed out and may have landed; the text is on the concealed clipboard.
    case mayHaveCommitted
    /// Focus could not be restored; the text is on the clipboard instead.
    case focusLost
}

/// Everything a session reports, in order, for one take. Observers run on the main actor in the
/// order they were added.
public enum DictationEvent: Equatable, Sendable {
    /// A new take was accepted; capture is being set up.
    case preparing
    /// Capture starts now; a host presents its recording UI here.
    case starting
    /// Capture is running.
    case recording
    /// A start during the post-buffer continued the released take.
    case resumed
    /// `stop` ended the press; capture continues through the adaptive post-buffer.
    case released
    case retargeted(DictationDestination)
    /// Microphone level, 0...1, every `levelEventInterval` while recording.
    case inputLevel(Float)
    /// Live-preview text while recording (only with streaming on and a streaming engine).
    case partialText(String)
    case partialTextCleared
    /// No audio, or pure digital silence, is arriving mid-recording.
    case audioStalled
    case audioRecovered
    /// Capture is over and finalize begins. A host applies deferred settings here: the
    /// transcriber and configuration are read right after this event.
    case captureEnded
    case transcribing
    /// The engine's model is still loading; transcription waits for it.
    case modelLoading
    /// Text is ready and about to be delivered.
    case delivering(DictationDestination)
    /// Reported during or after delivery, possibly after `finished`.
    case deliveryFallback(DictationDeliveryFallback)
    case finished(DictationResult)
    case failed(DictationFailure)
    case cancelled
}

/// What `start` did.
public enum DictationStartOutcome: Equatable, Sendable {
    case started(UUID)
    /// The released take was still in its post-buffer and continues; the destination is unchanged.
    case resumed(UUID)
    /// Nothing was recorded and no event was reported.
    case refused(DictationFailure)
    /// Capture could not start; `failed` was reported for the take.
    case failed(DictationFailure)
}

/// The settings a take runs with. The host updates it whenever its settings change; a take reads
/// it when capture starts and again when finalize begins.
public struct DictationConfiguration: Equatable {
    public var language = "en"
    public var punctuationMode: PunctuationMode = .off
    /// Live preview while recording.
    public var streamingEnabled = true
    /// OCR the screen at record start to prime the prompt and the name corrector.
    public var screenContextEnabled = false
    /// Reuse the last streaming partial instead of a final pass when it is fresh enough.
    public var reuseStreamingPartial = false
    /// Keep recordings that fail the length or silence gates. Kept or not, a finished take's
    /// retention follows the saved settings at the moment it finishes.
    public var saveRecordings = false

    public init() {}

    public init(config: Config) {
        language = config.language
        punctuationMode = config.effectivePunctuationMode
        streamingEnabled = config.streamingEnabled?.value ?? true
        screenContextEnabled = config.screenContext?.value == true
        reuseStreamingPartial = config.reuseStreamingPartial?.value ?? false
        saveRecordings = config.saveRecordings?.value ?? false
    }
}

// MARK: - DictationSession

/// SpeakFree's recording flow: capture, transcription, the text pipeline and delivery, for one
/// take at a time (a new take may start while the previous one transcribes).
///
/// A host drives it with `start(destination:)`, `retarget(to:)`, `stop()` and `cancel()`, and
/// presents what `addObserver` reports. The session owns no hotkeys, menus, windows or overlay;
/// SpeakFree's app, its local API and other apps all drive the same type.
@MainActor
public final class DictationSession {
    public typealias Observer = @MainActor (_ takeID: UUID, _ event: DictationEvent) -> Void

    /// The system probes a take touches outside the recorder and inserter. Tests replace them so
    /// no permission prompt, AX query or screen capture runs.
    struct Environment {
        var requestMicrophone: () -> Bool = { Permissions.ensureMicrophoneForRecording() }
        var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
        /// Runs off main.
        var readCursorContext: (CursorContextRequest) -> (AXUIElement?, String?) = CursorContextCapture.read
        /// Runs off main.
        var captureScreenText: () -> String? = { ScreenContext.captureAndRecognize() }
    }

    public let recorder: AudioRecorder
    public let inserter: TextInserter
    /// The engine takes are transcribed with. A take snapshots it when finalize begins.
    public var transcriber: Transcriber?
    /// Id of the engine `transcriber` runs ("whisper", "parakeet"); recorded in each take's metadata.
    public var engineID = "whisper"
    public var configuration = DictationConfiguration()
    /// Takes start only while enabled.
    public var isEnabled = false
    /// When set, `inputLevel` events are reported at this interval while recording.
    public var levelEventInterval: TimeInterval?

    private let environment: Environment
    private var observers: [(token: UUID, observer: Observer)] = []
    private var stopWaiters: [UUID: [(Result<DictationResult, DictationFailure>) -> Void]] = [:]

    // MARK: Take state (main only)

    // Lock-backed so the capture state can be read from any thread; written on main only.
    private let _isRecording = OSAllocatedUnfairLock(initialState: false)
    private let _isTrailing = OSAllocatedUnfairLock(initialState: false)
    /// True while the press is held (or a toggle is on). False during the post-buffer.
    public nonisolated var isRecording: Bool { _isRecording.withLock { $0 } }
    /// True while capture continues after `stop` (the adaptive post-buffer).
    public nonisolated var isTrailing: Bool { _isTrailing.withLock { $0 } }
    /// True from start until finalize begins.
    public nonisolated var isCapturing: Bool { isRecording || isTrailing }
    /// The take being captured; nil once its finalize begins.
    public private(set) var currentTakeID: UUID?
    public private(set) var currentDestination: DictationDestination?
    public var inputLevel: Float { recorder.currentLevel }
    /// The WAV the capturing take writes.
    var currentAudioURL: URL? { recordingActivityLease?.audioURL }

    /// Transfers to the finalization task; closing the writer alone does not end file use.
    private var recordingActivityLease: RecordingActivity.Lease?
    private var recordingStyleMode: TextPostProcessor.StyleMode = .none
    /// Frontmost app at record start — where the dictation will land. Persisted in
    /// .meta.json so the edit-feedback batch can find the final artifact to diff.
    private var recordingTargetBundleID: String?
    /// The current press resumed a take whose previous hold had already been released.
    private var continuedReleasedTake = false

    // MARK: Edit Mode seams (nil = hold/toggle behavior)

    /// Set at record-start by an edit session so finalize knows this segment belongs to it. nil
    /// for every hold/toggle dictation, which then resolves through the take's destination.
    var editFinalizeTarget: (sessionID: UUID, segmentID: UUID)?
    /// Delivers a finalized edit segment to the open session INSTEAD of inserting it (C1).
    var editFinalizeSink: ((EditFinalizePayload) -> Void)?

    /// Test seam: replaces finalize (after the post-buffer) so press/release tests run no inference.
    var _finalizeOverride: ((_ keyReleaseTime: Double) -> Void)?

    // R1: focus capture (the AXUIElement focused at record-start, used to refocus before
    // pasting, plus the cursor-context text passed to whisper as a prompt). The AX read
    // runs OFF-MAIN so record-start never blocks on an unresponsive frontmost app's AX tree:
    // `begin()` at record-start, the background reader `publish`es when it lands, and
    // finalize `consume(waitingUpTo:)`s it (waiting briefly only if still in flight — never
    // on the start path; nil on timeout).
    private let focusCapture = FocusCaptureBox<(AXUIElement?, String?)>()
    // Screen OCR text captured at recording start (opt-in). Written only on main via
    // generation-token check, so no lock needed.
    private var screenContextText: String?
    // Generation token: bumped at recording start AND end/cancel. The OCR background task
    // captures the UUID at dispatch time and writes back only if the token still matches,
    // discarding stale results from previous recordings.
    private var screenCaptureGeneration = UUID()

    // In-recording dead-audio watchdog (2026-07-25).
    private var recordingWatchdogTimer: Timer?
    private var watchdogWarnedDeadAudio = false
    private var watchdogSilentTicks = 0

    // Tail of the last successful insertion (2026-07-15): feeds the cursor-context
    // fallback for AX-opaque editors.
    private var lastInsertionTail: String?
    private var lastInsertionBundleID: String?
    private var lastInsertionAt: Date?
    private var lastInsertionElement: AXUIElement?
    private var lastInsertionInteractionGeneration: UInt64?
    private let userInteractionGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

    // Adaptive post-buffer (T2.1): poll trailing audio after key release. The policy requires
    // 90ms of current trailing silence, otherwise waits 220ms, extending up to 1.2s when trailing
    // energy crosses the speech threshold. This timer feeds it RMS windows from the live recorder.
    private var postBufferTimer: Timer? {
        didSet {
            let trailing = postBufferTimer != nil
            _isTrailing.withLock { $0 = trailing }
        }
    }
    private var postBufferGeneration: UInt64 = 0
    /// Window cadence the post-buffer poll uses (matches PostBufferPolicy's default window grain).
    private let postBufferWindowMs: Double = 30.0

    // Streaming transcription: periodic inference during recording
    private var streamingTimer: Timer?
    private var isStreamingInFlight = false  // prevents overlapping inference runs
    /// Streaming-preview text assembler: owns the "committed" display text (sentences that
    /// have ended and won't reflow) and the stable-append logic.
    private var streamingAssembler = StreamingTextAssembler()
    /// Monotonically-increasing token bumped every time streaming stops. Stale partial-result
    /// callbacks that arrive on main after recording ended compare against this and are dropped.
    private var streamingGeneration: UInt = 0

    // T2.3 — Reuse last streaming partial. These three capture the LAST completed streaming pass so
    // `finalizeRecording` can (when StreamingReuse.decide approves) skip the redundant final
    // inference and route this saved raw partial through TextPipeline instead. Reset on every
    // streaming start. Written on the main queue only.
    /// Raw engine text the last completed streaming pass returned (pre-TextPipeline). "" = none.
    private var lastStreamingRawPartial: String = ""
    /// Recorder sample count the last streaming pass ran over.
    private var lastStreamingSampleCount: Int = 0
    /// `CFAbsoluteTime` the last streaming pass completed (0 = none yet).
    private var lastStreamingCompletedAt: Double = 0

    private var levelTimer: Timer?

    public convenience init(recorder: AudioRecorder, inserter: TextInserter = TextInserter()) {
        self.init(recorder: recorder, inserter: inserter, environment: Environment())
    }

    init(recorder: AudioRecorder, inserter: TextInserter, environment: Environment) {
        self.recorder = recorder
        self.inserter = inserter
        self.environment = environment
    }

    private func setRecording(_ recording: Bool) {
        _isRecording.withLock { $0 = recording }
    }

    // MARK: - Observation

    /// Observers run on main, in the order they were added. Returns a token for `removeObserver`.
    @discardableResult
    public func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers.append((token, observer))
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers.removeAll { $0.token == token }
    }

    private func emit(_ takeID: UUID, _ event: DictationEvent) {
        for entry in observers { entry.observer(takeID, event) }
        let outcome: Result<DictationResult, DictationFailure>
        switch event {
        case .finished(let result): outcome = .success(result)
        case .failed(let failure): outcome = .failure(failure)
        case .cancelled: outcome = .failure(.cancelled)
        default: return
        }
        stopWaiters.removeValue(forKey: takeID)?.forEach { $0(outcome) }
    }

    // MARK: - Control

    /// Start a take, or continue the released take if it is still in its post-buffer.
    /// `takeID` lets a caller name the take (the local API uses its session id).
    @discardableResult
    public func start(destination: DictationDestination, takeID: UUID = UUID()) -> DictationStartOutcome {
        guard isEnabled else { return .refused(.notReady) }
        guard !isRecording else { return .refused(.busy) }
        if let timer = postBufferTimer, let resumedID = currentTakeID {
            // Capture is still running during the post-buffer. Continue this take without
            // creating another WAV/sentinel or replacing the original insertion context.
            postBufferGeneration &+= 1
            timer.invalidate()
            postBufferTimer = nil
            setRecording(true)
            continuedReleasedTake = true
            startRecordingWatchdog()
            startStreamingTimer()
            startLevelEvents()
            emit(resumedID, .resumed)
            return .resumed(resumedID)
        }
        continuedReleasedTake = false
        let startRequestedAt = CFAbsoluteTimeGetCurrent()

        // Microphone gate: never silently record silence. If access is missing, this prompts
        // (notDetermined) or shows an actionable alert (denied) and aborts this attempt.
        guard environment.requestMicrophone() else { return .refused(.microphoneUnavailable) }

        setRecording(true)
        currentTakeID = takeID
        currentDestination = destination
        emit(takeID, .preparing)
        let healthFinishedAt = CFAbsoluteTimeGetCurrent()

        // Detect style mode from frontmost app before menu bar steals focus. The
        // bundle id is also kept for the .meta.json sidecar — the edit-feedback batch
        // (tune-corpus) correlates dictations with where the text landed.
        let frontApp = environment.frontmostApplication()
        let frontBundleID = frontApp?.bundleIdentifier
        let avoidLiveWindowContext = TextInserter.shouldAvoidLiveWindowContext(
            bundleID: frontBundleID, bundleURL: frontApp?.bundleURL)
        recordingTargetBundleID = frontBundleID
        let electronClass = TextInserter.prefersClipboardPaste(app: frontApp)
        inserter.livePrependProbeSuppressed = electronClass
        recordingStyleMode = TextPostProcessor.detectStyleMode(bundleID: frontBundleID)
        let classificationFinishedAt = CFAbsoluteTimeGetCurrent()

        // Capture focused element before anything else changes.
        // Skip for remote desktop — AX reads the Splashtop UI, not the remote text field.
        let isRemoteDesktop = inserter.isRemoteDesktopFrontmost()
        if !isRemoteDesktop {
            captureFocusedElement(frontBundleID: frontBundleID, electronClass: electronClass,
                                  avoidLiveWindowContext: avoidLiveWindowContext)
        } else {
            // Reset the capture box to a published-nil so finalize consumes no stale context.
            focusCapture.reset()
        }

        // Capture screen context in background if enabled.
        // Skip for remote desktop apps — OCR captures the remote screen content
        // which whisper then parrots instead of transcribing speech.
        // OCR feeds both the prompt and the screen-aware NAME corrector, which works on every
        // engine — Parakeet users get on-screen spellings (Kris vs Chris) even though the
        // engine ignores prompts.
        if configuration.screenContextEnabled && !isRemoteDesktop && !avoidLiveWindowContext {
            // Bump generation so any in-flight OCR from a previous recording is discarded.
            let capturedGeneration = UUID()
            screenCaptureGeneration = capturedGeneration
            let captureScreenText = environment.captureScreenText
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let text = captureScreenText()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.screenCaptureGeneration == capturedGeneration else { return }
                    self.screenContextText = text
                }
            }
        }

        emit(takeID, .starting)
        let overlayFinishedAt = CFAbsoluteTimeGetCurrent()
        startRecordingWatchdog()
        do {
            // Always write to recordings dir — crash recovery works regardless of maxRecordings
            let outputURL = RecordingStore.newRecordingURL()
            recordingActivityLease = try RecordingActivity.shared.acquire(outputURL)
            let pathPreparedAt = CFAbsoluteTimeGetCurrent()
            RecordingStore.writeSentinel(recordingURL: outputURL)
            let sentinelWrittenAt = CFAbsoluteTimeGetCurrent()
            try recorder.startRecording(to: outputURL)
            let recordingStartedAt = CFAbsoluteTimeGetCurrent()
            if recordingStartedAt - startRequestedAt >= 0.25 {
                DiagnosticLogger.shared.log(String(
                    format: "Recording start slow: health=%.2fs classify=%.2fs overlay=%.2fs file=%.2fs total=%.2fs",
                    healthFinishedAt - startRequestedAt,
                    classificationFinishedAt - healthFinishedAt,
                    overlayFinishedAt - classificationFinishedAt,
                    recordingStartedAt - overlayFinishedAt,
                    recordingStartedAt - startRequestedAt))
                DiagnosticLogger.shared.log(String(
                    format: "Recording file setup: path=%.3fs sentinel=%.3fs writer=%.3fs",
                    pathPreparedAt - overlayFinishedAt,
                    sentinelWrittenAt - pathPreparedAt,
                    recordingStartedAt - sentinelWrittenAt))
            }

            // Start streaming transcription timer — processes audio every 2s for live preview
            startStreamingTimer()
            startLevelEvents()
            emit(takeID, .recording)
            return .started(takeID)
        } catch {
            // MUST be visible in the diagnostic log: this branch used to print only to
            // stdout, so the 2026-07-23 every-press-fails outage looked like a silent
            // no-op ("Health check: all OK" then nothing) and took a live stdout
            // capture to see. Error description only — never transcript content.
            DiagnosticLogger.shared.log("Recording start FAILED: \(error)")
            stopRecordingWatchdog()
            print("Error: \(error.localizedDescription)")
            if let lease = recordingActivityLease {
                RecordingStore.clearSentinel(recordingURL: lease.audioURL)
            }
            recordingActivityLease = nil
            setRecording(false)
            currentTakeID = nil
            currentDestination = nil
            focusCapture.reset()  // recording never started — invalidate the in-flight capture
            // I4: OCR was kicked off just above, but recording never started so nothing will
            // consume it. Clear it and invalidate the in-flight capture so a late OCR write can't
            // bias the next dictation's prompt.
            screenContextText = nil
            screenCaptureGeneration = UUID()
            emit(takeID, .failed(.recordingFailed))
            return .failed(.recordingFailed)
        }
    }

    /// Change where the capturing take's text goes. Allowed from start until finalize begins
    /// (the post-buffer included). Returns false when no take is capturing.
    @discardableResult
    public func retarget(to destination: DictationDestination) -> Bool {
        guard isCapturing, let takeID = currentTakeID else { return false }
        if currentDestination != destination {
            currentDestination = destination
            emit(takeID, .retargeted(destination))
        }
        return true
    }

    /// End the press: capture continues through the adaptive post-buffer, then the take
    /// finalizes. `completion` runs once the take finishes, fails or is cancelled, or right away
    /// with `.notRecording` when no take is capturing.
    public func stopRecording(completion: ((Result<DictationResult, DictationFailure>) -> Void)? = nil) {
        if let completion {
            guard let takeID = currentTakeID else { return completion(.failure(.notRecording)) }
            stopWaiters[takeID, default: []].append(completion)
        }
        guard isRecording, let takeID = currentTakeID else { return }
        setRecording(false)
        continuedReleasedTake = false

        stopRecordingWatchdog()
        stopStreamingTimer()
        stopLevelEvents()

        // Capture key-release time NOW — finalizeRecording runs up to the post-buffer later, so
        // measuring inside it would undercount the post-buffer delay in the latency log.
        let keyReleaseTime = CFAbsoluteTimeGetCurrent()
        emit(takeID, .released)

        // T2.1 — Adaptive post-buffer. We still keep recording AFTER key release so the tail of
        // the last word (an AVAudioEngine buffer releasing mid-word loses its tail) isn't clipped.
        // The wait DECISION is the pure PostBufferPolicy (unit-tested over RMS windows); this
        // loop only feeds it the live trailing samples.
        let samplesAtRelease = recorder.currentSampleCount()
        runAdaptivePostBuffer(samplesAtRelease: samplesAtRelease) { [weak self] in
            self?.finalizeRecording(keyReleaseTime: keyReleaseTime)
        }
    }

    /// End the press and wait for the take's text.
    public func stop() async throws -> DictationResult {
        try await withCheckedThrowingContinuation { continuation in
            stopRecording { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
    }

    /// Discard the capturing take (recording or in its post-buffer): the WAV is deleted and
    /// nothing is transcribed. Returns false when no take is capturing; a take that is already
    /// transcribing is not recalled.
    @discardableResult
    public func cancel() -> Bool {
        guard isCapturing else { return false }
        discardTake()
        return true
    }

    /// A real key was pressed while the dictation key was held — a keyboard shortcut, not
    /// dictation. Cancel the press silently. If this press resumed an already-released take,
    /// that take is kept and returns to its normal post-buffer and finalize.
    @discardableResult
    public func abortPress() -> Bool {
        guard isRecording else { return false }
        if continuedReleasedTake {
            stopRecording()
            return true
        }
        discardTake()
        return true
    }

    private func discardTake() {
        setRecording(false)
        continuedReleasedTake = false
        postBufferGeneration &+= 1
        postBufferTimer?.invalidate()
        postBufferTimer = nil

        stopRecordingWatchdog()
        stopStreamingTimer()
        stopLevelEvents()

        if let result = recorder.stopRecording() {
            try? FileManager.default.removeItem(at: result.url)
            RecordingStore.clearSentinel(recordingURL: result.url)
        }
        if let lease = recordingActivityLease {
            RecordingStore.clearSentinel(recordingURL: lease.audioURL)
        }
        recordingActivityLease = nil
        focusCapture.reset()  // invalidate any in-flight focus capture
        screenContextText = nil
        screenCaptureGeneration = UUID()  // invalidate any in-flight OCR
        let takeID = currentTakeID
        currentTakeID = nil
        currentDestination = nil
        if let takeID { emit(takeID, .cancelled) }
    }

    // MARK: - Cursor context

    private func captureFocusedElement(frontBundleID: String?, electronClass: Bool,
                                       avoidLiveWindowContext: Bool) {
        // R1: fire-and-commit. The AX read runs on a background queue and publishes into
        // `focusCapture`; finalize consumes the result (waiting briefly only if it is still in
        // flight). Record-start never waits on it. Pre-roll (500ms) means no audio is lost by
        // starting the recorder before the read completes.
        let token = focusCapture.begin()
        // Snapshot the main-only fallback inputs now so the background reader can compute the
        // Electron cursor-context fallback without touching main state.
        let request = CursorContextRequest(
            lastInsertionTail: lastInsertionTail,
            lastInsertionBundleID: lastInsertionBundleID,
            lastInsertionAt: lastInsertionAt,
            lastInsertionElement: lastInsertionElement,
            lastInsertionInteractionGeneration: lastInsertionInteractionGeneration,
            interactionGenerationAtStart: currentUserInteractionGeneration(),
            frontmostBundleID: frontBundleID,
            electronClass: electronClass,
            avoidLiveWindowContext: avoidLiveWindowContext)
        let read = environment.readCursorContext
        let box = focusCapture
        DispatchQueue.global(qos: .userInteractive).async {
            // Generation-guarded: a stale capture from a previous recording is dropped.
            box.publish(read(request), token: token)
        }
    }

    /// The user edited or moved the cursor. Keeps the remembered insertion tail in step with
    /// what the user typed, or forgets it when it can no longer be trusted.
    func noteUserInteraction(_ interaction: HotkeyManager.CursorInteraction) {
        func invalidate() {
            userInteractionGeneration.withLock { generation in
                generation &+= 1
            }
        }

        guard let bundleID = lastInsertionBundleID,
              environment.frontmostApplication()?.bundleIdentifier == bundleID,
              let tail = lastInsertionTail else {
            invalidate()
            return
        }

        let pastedText = interaction == .paste
            ? NSPasteboard.general.string(forType: .string) : nil
        guard let updatedTail = HotkeyManager.updatedCursorTail(
            tail, after: interaction, pastedText: pastedText) else {
            invalidate()
            return
        }

        // We now know the cursor tail from the actual edits, even if AX cannot expose the
        // editor. Clear the old AX identity (Electron may vend unstable wrapper objects), keep
        // only the bounded suffix, and refresh the fallback freshness window.
        lastInsertionTail = updatedTail
        lastInsertionAt = Date()
        lastInsertionElement = nil
    }

    private func currentUserInteractionGeneration() -> UInt64 {
        userInteractionGeneration.withLock { $0 }
    }

    // MARK: - Watchdog and level

    /// In-recording dead-audio watchdog (2026-07-25 audit C3/C5): the ONLY health
    /// checks used to run before recording started — a 60-minute hold had none. Every
    /// 5s this compares the last-buffer timestamp; >3s of no audio mid-recording means
    /// the tap/route died (AirPods handoff, config change) and the user must know NOW,
    /// not after dictating 40 minutes into a dead mic. Reported as `audioStalled`, and
    /// `audioRecovered` if it comes back.
    private func startRecordingWatchdog() {
        recordingWatchdogTimer?.invalidate()
        watchdogWarnedDeadAudio = false
        recordingWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAudioHealth() }
        }
    }

    private func checkAudioHealth() {
        guard isRecording, let takeID = currentTakeID else { return }
        let deadFor = recorder.secondsSinceLastBuffer()
        let peak = recorder.peakSinceLastCheck()
        // Two dead shapes (codex review #4): NO buffers (tap/route died), and
        // buffers of pure digital silence (muted mic / stale route still
        // delivering zeros — the 2026-07-25 lost VS Code dictation). A live mic's
        // noise floor peaks well above 0.001; zeros don't. Two consecutive silent
        // ticks (10s) before warning so a quiet pause can't false-positive.
        let buffersDead = deadFor > 3.0
        if buffersDead {
            watchdogSilentTicks = 0
        } else if peak < 0.001 {
            watchdogSilentTicks += 1
        } else {
            watchdogSilentTicks = 0
        }
        let silentMic = watchdogSilentTicks >= 2
        if buffersDead || silentMic {
            if !watchdogWarnedDeadAudio {
                watchdogWarnedDeadAudio = true
                DiagnosticLogger.shared.log(String(
                    format: "WATCHDOG: %@ mid-recording (no-buffers %.1fs, peak %.4f)",
                    buffersDead ? "capture dead" : "mic delivering silence", deadFor, peak))
                emit(takeID, .audioStalled)
                if buffersDead {
                    recorder.recoverDeadCaptureDuringRecording()
                }
            }
        } else if watchdogWarnedDeadAudio {
            watchdogWarnedDeadAudio = false
            DiagnosticLogger.shared.log("WATCHDOG: audio resumed")
            emit(takeID, .audioRecovered)
        }
    }

    private func stopRecordingWatchdog() {
        recordingWatchdogTimer?.invalidate()
        recordingWatchdogTimer = nil
        watchdogWarnedDeadAudio = false
        watchdogSilentTicks = 0
    }

    private func startLevelEvents() {
        levelTimer?.invalidate()
        levelTimer = nil
        guard let interval = levelEventInterval, interval > 0 else { return }
        levelTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording, let takeID = self.currentTakeID else { return }
                self.emit(takeID, .inputLevel(self.inputLevel))
            }
        }
    }

    private func stopLevelEvents() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    // MARK: - Post-buffer

    /// Poll the recorder's trailing audio on a short timer; once `PostBufferPolicy.decideWaitMs`
    /// says enough contiguous trailing silence has accrued (or the cap is hit), invoke
    /// `finalize` on the main queue. `samplesAtRelease` marks the sample count at key-release so
    /// only audio captured AFTER the key lifted is scored as "trailing". The decision is the pure
    /// policy; this only feeds it the live trailing samples.
    private func runAdaptivePostBuffer(samplesAtRelease: Int, finalize: @escaping () -> Void) {
        let windowMs = postBufferWindowMs
        // Hard deadline = the EXTENDED cap (2026-07-25): the policy's decided wait stays ≤220ms
        // for quiet releases and only exceeds it when trailing speech energy shows the speaker
        // finishing a word across the release — the deadline must not amputate that extension
        // (a word spoken across release died at the old 220ms ceiling: "…the last word, ⟨release⟩
        // selectors" → transcript ended at "word."). Latency for quiet releases is unchanged;
        // the deadline is the runaway guard only.
        let capMs = PostBufferPolicy.defaultExtendedCapMs
        // Perf adjudication dispute #1: bound the total wait by a MONOTONIC deadline. DispatchTime
        // is a monotonic clock (unlike wall-clock CFAbsoluteTimeGetCurrent, which NTP/clock-set can
        // jump), so a congested runloop firing a late tick still stops at the first tick past the
        // cap — we check the CURRENT clock against the deadline each tick, never trust tick count.
        let startTick = DispatchTime.now().uptimeNanoseconds

        postBufferTimer?.invalidate()
        postBufferGeneration &+= 1
        let generation = postBufferGeneration
        postBufferTimer = Timer.scheduledTimer(withTimeInterval: windowMs / 1000.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self = self else { timer.invalidate(); return }
                guard self.postBufferGeneration == generation, !self.isRecording else {
                    timer.invalidate()
                    return
                }
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startTick) / 1_000_000.0
                // R3: copy only the trailing slice, not the full (growing) sample array each tick.
                let trailing = self.recorder.samples(after: samplesAtRelease)
                // Ask the pure policy how long it wants given the trailing audio seen so far.
                let decided = PostBufferPolicy.decideWaitMs(trailingSamples: trailing, windowMs: windowMs)

                // Stop once the decided wait has elapsed, or the monotonic cap deadline is reached.
                if PostBufferPolicy.postBufferShouldFinalize(elapsedMs: elapsedMs, decidedMs: decided, capMs: capMs) {
                    timer.invalidate()
                    self.postBufferTimer = nil
                    finalize()
                }
            }
        }
    }

    // MARK: - Finalize

    func finalizeRecording(keyReleaseTime: Double = CFAbsoluteTimeGetCurrent()) {
        if let override = _finalizeOverride {
            override(keyReleaseTime)
            return
        }
        let activityLease = recordingActivityLease
        recordingActivityLease = nil
        // Retain on every synchronous early-return path, then transfer into Task below.
        defer { withExtendedLifetime(activityLease) {} }
        let takeID = currentTakeID ?? UUID()
        // The host applies settings it deferred during capture here, before the transcriber and
        // configuration snapshots below, so the whole finalization runs on ONE engine.
        emit(takeID, .captureEnded)

        let stopTime = keyReleaseTime
        let destination = currentDestination ?? .cursor
        currentTakeID = nil
        currentDestination = nil
        let configuration = self.configuration

        guard let recording = recorder.stopRecording() else {
            if let activityLease {
                RecordingStore.clearSentinel(recordingURL: activityLease.audioURL)
            }
            focusCapture.reset()
            emit(takeID, .failed(.noAudio))
            return
        }
        let audioURL = recording.url
        let saveRecordings = DevMode.isActive || configuration.saveRecordings

        // Pre-transcription gates (too-short / silent), with the wav on disk as arbiter:
        // if the in-memory samples fail a gate but the just-written wav passes, transcribe
        // the wav's samples instead of dropping the dictation (2026-06-29: a good AirPods
        // recording was dropped as "silent"; the wav transcribed fine offline).
        // Threshold + RMS live in FinalizePipeline so the test harness gates on the SAME values.
        let gate = FinalizePipeline.resolveGateSamples(
            memorySamples: recording.samples,
            readWav: { try? ProcessCommand.loadSamples(from: audioURL) }
        )
        if let failure = gate.failure {
            let reported: DictationFailure
            switch failure {
            case .captureFailed:
                DiagnosticLogger.shared.log(
                    "Finalize: zero-payload take; capture failed with zero PCM frames")
                reported = .captureFailed
            case .tooShort(let count):
                // Likely an accidental tap — skip quietly.
                DiagnosticLogger.shared.log(
                    "Recording too short (\(count) samples / \(Int(Double(count) / 16000.0 * 1000))ms) — skipping")
                reported = .tooShort
            default:
                // NOTE: the wav either agreed or could not be read — resolveGateSamples does
                // not distinguish; do not claim agreement in the log.
                DiagnosticLogger.shared.log(
                    "Recording was silent (RMS \(FinalizePipeline.rms(of: recording.samples))) and the wav did not rescue it — audio engine may be dead, rebuilding")
                reported = .silent
            }
            // A 0-sample or silent primary means a dead engine, not an accidental tap —
            // kick a rebuild now regardless of how the dictation resolves.
            if reported == .captureFailed || reported == .silent {
                recorder.recoverFailedCapture()
            }
            if reported == .captureFailed {
                try? FileManager.default.removeItem(at: audioURL)
            }
            // Keep None also applies to diagnostic failures. Developer mode remains
            // the explicit, visibly disclosed override through saveRecordings.
            if !saveRecordings {
                try? FileManager.default.removeItem(at: audioURL)
            } else if reported == .silent {
                // Empty sidecar (review #6): the kept wav is diagnostic evidence,
                // NOT a recoverable dictation — without this the launch sweep
                // re-offers known-silent audio every launch and masks real orphans.
                RecordingStore.saveTranscription(text: "", for: audioURL)
            }
            RecordingStore.clearSentinel(recordingURL: audioURL)
            focusCapture.reset()
            // I4: a gate-failed dictation never consumes its OCR, so clear it and invalidate any
            // in-flight capture — otherwise this recording's screenContextText survives and biases
            // the NEXT dictation's prompt with stale on-screen text.
            screenContextText = nil
            screenCaptureGeneration = UUID()
            emit(takeID, .failed(reported))
            return
        }
        if gate.usedWavFallback {
            // Divergence between the tap's in-memory copy and the wav is an upstream bug —
            // the dictation is saved, but leave a trace so it can be chased.
            DiagnosticLogger.shared.log(
                "Gate override: in-memory samples failed (count \(recording.samples.count), RMS \(FinalizePipeline.rms(of: recording.samples))) but wav passed — transcribing wav samples")
        }
        let samples = gate.samples

        emit(takeID, .transcribing)

        // R1: consume the off-main focus capture. In the normal case it published while the
        // user was still speaking, so this returns immediately; only if the AX read is still
        // in flight does it wait briefly (0.5s budget, off the felt start path). nil on
        // timeout means no context.
        let (capturedElement, capturedInputText) = focusCapture.consume(waitingUpTo: 0.5) ?? (nil, nil)
        let capturedScreenText = screenContextText
        screenContextText = nil
        screenCaptureGeneration = UUID()  // invalidate any late-arriving OCR

        // T2.2 — Precompute shouldPrependSpace NOW, on main, from the cursor-context string
        // that was already captured at record-start (off main, inside captureFocusedElement).
        // The last character of capturedInputText IS the character immediately before the cursor,
        // so no further AX query is needed.
        //
        // Tradeoff: the value reflects the focused element at RECORD-START. If focus changes
        // mid-dictation the answer may be stale — but we refocus that same element anyway, so
        // the element and the precomputed context always agree.
        let capturedPrependSpace = TextInserter.shouldPrependSpace(contextBefore: capturedInputText)
        DiagnosticLogger.shared.log(
            "Finalize: prependSpace=\(capturedPrependSpace) midSentence=\(TextPipeline.isMidSentence(contextBefore: capturedInputText)) ctxLen=\(capturedInputText?.count ?? 0)")

        // Snapshot ALL config-derived state on main before crossing into the async Task.
        // Retention is deliberately NOT captured here. A user can change it while
        // inference runs; the completion must honor that newer preference.
        // The punctuation mode resolves through `Config.effectivePunctuationMode`, the one
        // shared default every consumer reads.
        let mode = configuration.punctuationMode
        let glossary = Config.loadVocabulary()
        let overrides = Config.loadOverrides()
        let capturedStyleMode = recordingStyleMode
        // Provenance snapshot for the .meta.json sidecar — engine/model from the ACTIVE
        // transcriber (not config, which can disagree after a model fallback).
        let metaEngine = engineID
        let metaDevice = recorder.currentCaptureDeviceName()
        let metaTargetApp = recordingTargetBundleID
        // C1: snapshot the edit-session target (nil for hold/toggle) on main before the async Task,
        // so the finalize destination is decided from the target captured at record-start, never
        // re-derived.
        let editTarget = editFinalizeTarget

        // Snapshot the transcriber on main BEFORE crossing into the async Task. A settings
        // change mid-finalize can swap self.transcriber out from under us; the snapshot
        // guarantees this recording's audio runs through the engine that was active when the
        // user spoke, not a freshly-swapped one.
        guard let transcriber = self.transcriber else {
            RecordingStore.clearSentinel(recordingURL: audioURL)
            emit(takeID, .failed(.engineNotReady))
            return
        }

        // T2.3 — decide (on main, all state read here) whether to reuse the last streaming partial
        // instead of running a fresh final inference. The gate (flag + freshness + growth) is the
        // pure StreamingReuse type.
        //
        // DEFAULT OFF (AR-2 finding #2): the T2.3-PRE measurement that originally authorized
        // default-ON only varied THREAD COUNT on 2–3 s hallucination slices ("(upbeat music)",
        // empty strings) and reported 0.000% divergence — agreement on noise, not signal. It never
        // measured the axis production actually swaps: a `prompt:nil`, NON-VAD-trimmed streaming
        // partial (transcribeStreaming, processStreamingChunk) replacing a glossary/screen/cursor-context
        // -primed, VAD-trimmed FINAL pass (transcribe, prompt: prompt below). Re-measured on the FULL
        // real-speech fixtures that axis diverges ~5% (>5× the locked <1% gate). So reuse is OFF by
        // default until a valid prompt-axis measurement clears the gate; the flag remains for
        // opt-in/experiments. When the gate declines, `reuseDecision` is `.runFinalInference`.
        let reuseDecision = StreamingReuse.decide(StreamingReuse.State(
            flagEnabled: configuration.reuseStreamingPartial,
            lastRawPartial: lastStreamingRawPartial,
            lastStreamedSampleCount: lastStreamingSampleCount,
            lastStreamCompletedAt: lastStreamingCompletedAt,
            sampleCountAtRelease: samples.count,
            keyReleaseAt: keyReleaseTime
        ))

        // Bridge into async: the transcribe pipeline is async/await (FluidAudio is async-only;
        // WhisperEngine exposes async shims). The engines serialize access to their own context
        // internally. Results are marshalled back to main via DispatchQueue.main.async.
        Task { [weak self, activityLease] in
            defer { activityLease?.release() }
            guard let self = self else { return }
            do {
                // Build Whisper prompt + run post-processing through the shared TextPipeline
                // core, the same code path unit tests cover.
                let pipelineContext = TextPipeline.Input(
                    punctuationMode: mode,
                    cursorContextText: capturedInputText,
                    screenContextText: capturedScreenText,
                    styleMode: capturedStyleMode,
                    glossaryWords: glossary
                )
                let prompt = TextPipeline.assemblePromptHints(input: pipelineContext)
                let makeInput: (String, Int) -> TextPipeline.Input = { raw, sampleCount in
                    TextPipeline.Input(
                        raw: raw,
                        punctuationMode: mode,
                        cursorContextText: capturedInputText,
                        screenContextText: capturedScreenText,
                        styleMode: capturedStyleMode,
                        glossaryWords: glossary,
                        overrides: overrides,
                        audioDurationSeconds: Double(sampleCount) / 16000.0
                    )
                }

                if !transcriber.isLoaded {
                    DiagnosticLogger.shared.log(
                        "Finalize: dictation waiting on model load (cold start)")
                    DispatchQueue.main.async {
                        self.emit(takeID, .modelLoading)
                    }
                }

                let (primaryRaw, reusedPartial) = try await FinalizePipeline.resolveRaw(
                    reuseDecision: reuseDecision
                ) {
                    try await transcriber.transcribe(
                        audioURL: audioURL, samples: samples, prompt: prompt,
                        punctuationMode: mode)
                }
                if reusedPartial {
                    DiagnosticLogger.shared.log(
                        "T2.3: reused last streaming partial (skipped final inference)")
                }
                let pipelineResult = TextPipeline.run(
                    makeInput(primaryRaw, samples.count),
                    precomputedPrompt: .some(prompt))
                let text = pipelineResult.finalText
                let meta = RecordingStore.RecordingMeta(
                    appVersion: SpeakFree.version,
                    engine: metaEngine,
                    model: transcriber.modelID,
                    inputDevice: metaDevice,
                    date: ISO8601DateFormatter().string(from: Date()),
                    durationSeconds: Double(samples.count) / 16_000.0,
                    transcriptChars: text.count,
                    targetApp: metaTargetApp,
                    transcriptionDiagnostics: transcriber.lastDiagnostics
                )
                let retentionConfig = Config.load()
                let keepRecording = DevMode.effectiveSaveRecordings(retentionConfig)
                let maxRecordings = (DevMode.isActive || !keepRecording || retentionConfig.preserveAllRecordings?.value == true)
                    ? 0 : Config.effectiveMaxRecordings(retentionConfig.maxRecordings)
                RecordingStore.finishRecording(
                    audioURL: audioURL, keep: keepRecording, raw: primaryRaw, text: text, meta: meta)
                RecordingStore.clearSentinel(recordingURL: audioURL)
                if keepRecording && maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                func result(_ delivery: DictationDelivery) -> DictationResult {
                    DictationResult(
                        takeID: takeID, destination: destination, raw: primaryRaw,
                        processed: pipelineResult.processedText, styled: text, delivery: delivery,
                        audioURL: audioURL, recordingKept: keepRecording,
                        audioDuration: Double(samples.count) / 16_000.0)
                }
                // C1 finalize destination: an edit segment is delivered to its session and CANNOT
                // reach the inserter; a caller take is returned; a cursor take is typed.
                switch FinalizeDestination.resolve(
                    editTarget: editTarget, callerSession: destination == .caller ? takeID : nil) {
                case .returnToEditSession(let sessionID, let segmentID):
                    let payload = EditFinalizePayload(
                        sessionID: sessionID, segmentID: segmentID, raw: primaryRaw,
                        pipelineText: text, audioURL: audioURL, meta: meta)
                    DispatchQueue.main.async {
                        // No TextInserter, no focus recapture — the session owns the segment from here.
                        self.editFinalizeSink?(payload)
                        self.emit(takeID, .finished(result(.editSession)))
                    }
                case .returnToCaller:
                    DispatchQueue.main.async {
                        // No TextInserter: the text goes back to the caller and never reaches
                        // the focused app.
                        self.emit(takeID, .delivering(.caller))
                        self.emit(takeID, .finished(result(.returnedToCaller)))
                    }
                case .insertImmediately:
                    DispatchQueue.main.async {
                        self.emit(takeID, .delivering(.cursor))
                        let delivery = self.deliverAtCursor(
                            text,
                            takeID: takeID,
                            sampleCount: samples.count,
                            stopTime: stopTime,
                            prependSpace: capturedPrependSpace,
                            contextBefore: capturedInputText,
                            element: capturedElement
                        )
                        self.emit(takeID, .finished(result(delivery)))
                    }
                }
            } catch {
                RecordingStore.clearSentinel(recordingURL: audioURL)
                // The opt-out must win on the failure path too: finishRecording(keep:false)
                // — the deletion the user consented to — is never reached when inference
                // throws, and the wav would silently persist against the setting.
                let retentionConfig = Config.load()
                let keepRecording = DevMode.effectiveSaveRecordings(retentionConfig)
                let maxRecordings = (DevMode.isActive || !keepRecording || retentionConfig.preserveAllRecordings?.value == true)
                    ? 0 : Config.effectiveMaxRecordings(retentionConfig.maxRecordings)
                if !keepRecording {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                if maxRecordings > 0 {
                    RecordingStore.prune(maxCount: maxRecordings)
                }
                // A missing engine model (e.g. Parakeet never downloaded) is reported apart
                // from a generic failure so the host can say how to fix it.
                let failure: DictationFailure
                if case TranscriptionEngineError.modelAssetsMissing = error {
                    failure = .modelMissing(recordingKept: keepRecording)
                } else {
                    // Must be VISIBLE: a swallowed throw here means a good recording
                    // silently produces nothing (the 2026-06-29 dropped-dictation event
                    // took 12 days to trace because this branch only printed to stdout).
                    // Error type/description only — never transcript content.
                    let message = "Transcription failed: \(error)"
                    print("Error: \(message)")
                    DiagnosticLogger.shared.log(message)
                    failure = .transcriptionFailed(reason: error.localizedDescription,
                                                   recordingKept: keepRecording)
                }
                DispatchQueue.main.async {
                    self.emit(takeID, .failed(failure))
                }
            }
        }
    }

    /// Type the finished text at the cursor, refocusing the element captured at record start.
    private func deliverAtCursor(
        _ text: String,
        takeID: UUID,
        sampleCount: Int,
        stopTime: Double,
        prependSpace: Bool,
        contextBefore: String?,
        element: AXUIElement?
    ) -> DictationDelivery {
        guard !text.isEmpty else {
            let audioSeconds = Double(sampleCount) / 16_000.0
            DiagnosticLogger.shared.log(String(
                format: "Transcription EMPTY, nothing inserted (%.1fs of audio)",
                audioSeconds))
            return .nothingToInsert
        }
        let insertText = FinalizePipeline.composeInsertText(text, prependSpace: prependSpace)
        let spacing = TextInserter.spacingDiagnosis(
            contextBefore: contextBefore, insertText: insertText)
        DiagnosticLogger.shared.log(
            "Insertion boundary: prev=\(TextInserter.charClass(contextBefore?.last)) "
                + "first=\(TextInserter.charClass(insertText.first)) → \(spacing.rawValue)")
        inserter.onSecureInputFallback = { [weak self] text, reason in
            switch reason {
            case .axTimeoutMayHaveCommitted:
                // The AX write MAY have landed — a host must never prompt a paste or
                // auto-retry here; both risk a duplicate.
                self?.emit(takeID, .deliveryFallback(.mayHaveCommitted))
            case .secureInput:
                self?.emit(takeID, .deliveryFallback(.secureInput(text: text)))
            }
        }
        let pasted = inserter.insert(
            text: insertText,
            refocusing: element,
            onFocusLost: { [weak self] in
                self?.emit(takeID, .deliveryFallback(.focusLost))
            })
        guard pasted else { return .copiedToClipboard }
        lastInsertionTail = String(((contextBefore ?? "") + insertText).suffix(500))
        lastInsertionBundleID = environment.frontmostApplication()?.bundleIdentifier
        lastInsertionAt = Date()
        lastInsertionElement = element
        lastInsertionInteractionGeneration = currentUserInteractionGeneration()
        let elapsed = CFAbsoluteTimeGetCurrent() - stopTime
        DiagnosticLogger.shared.log(
            "Transcription complete: \(String(format: "%.2f", elapsed))s "
                + "from key-release to text-inserted, \(text.count) chars")
        return .inserted
    }

    // MARK: - Streaming transcription

    private func startStreamingTimer() {
        guard configuration.streamingEnabled else { return }
        // Gate on the transcriber's engine-agnostic passthroughs. Engines that don't support
        // live preview (parakeet v1) report supportsStreaming == false and are skipped here.
        guard let transcriber, transcriber.supportsStreaming, transcriber.isLoaded else { return }
        streamingAssembler.reset()
        isStreamingInFlight = false
        resetStreamingReuseState()  // T2.3: no partial to reuse until the first pass completes
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.processStreamingChunk() }
        }
        DiagnosticLogger.shared.log("Streaming: timer started (2.0s interval)")
    }

    private func stopStreamingTimer() {
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingAssembler.reset()
        isStreamingInFlight = false
        streamingGeneration &+= 1  // invalidate any in-flight partial-result callbacks
        // NOTE: lastStreamingRawPartial/SampleCount/CompletedAt are intentionally NOT cleared here.
        // stopRecording() calls stopStreamingTimer() BEFORE finalizeRecording reads the reuse
        // state, so clearing here would always defeat the reuse path. They are reset in
        // startStreamingTimer() (next recording) instead.
        if let takeID = currentTakeID { emit(takeID, .partialTextCleared) }
    }

    private func processStreamingChunk() {
        guard isRecording, !isStreamingInFlight, let takeID = currentTakeID else { return }

        let currentSamples = recorder.currentSamples()
        // Need at least 1 second of audio for meaningful transcription
        guard currentSamples.count > 16000 else { return }

        isStreamingInFlight = true

        // T2.3 — remember the sample count this streaming pass runs over so finalizeRecording can
        // measure how much the recording grew since (the reuse growth-gate).
        let streamedSampleCount = currentSamples.count

        let language = configuration.language

        // Snapshot the transcriber on main BEFORE crossing into the async Task (mirrors the
        // finalizeRecording fix). A mid-stream engine swap can replace self.transcriber; the
        // snapshot guarantees this partial runs through the engine that was active when the
        // chunk was captured, not a freshly-swapped one.
        guard let transcriber = self.transcriber else {
            isStreamingInFlight = false
            return
        }
        let suppressRegex = transcriber.suppressAutoPunctuation ? "[,\\.\\?!;:\\-—]" : nil

        let generation = streamingGeneration
        Task { [weak self] in
            guard let self = self else { return }
            // Re-check: user may have released hotkey while we waited to start
            guard self.isRecording else {
                DispatchQueue.main.async { self.isStreamingInFlight = false }
                return
            }
            do {
                let partial = try await transcriber.transcribeStreaming(
                    samples: currentSamples,
                    language: language,
                    prompt: nil,
                    suppressRegex: suppressRegex,
                    onPartialResult: { [weak self] text in
                        // Engines call back on their own queue; the assembler is main-only.
                        DispatchQueue.main.async {
                            guard let self = self, self.streamingGeneration == generation else { return }
                            // Strip Whisper hallucination markers so they don't appear in the
                            // live preview — the finalize path goes through TextPipeline, but
                            // the preview path calls the engine directly.
                            let cleaned = TextPipeline.stripWhisperBracketMarkers(text)
                            self.emit(takeID, .partialText(self.streamingAssembler.append(cleaned)))
                        }
                    }
                )
                DispatchQueue.main.async {
                    // Commit completed sentences so they won't change on next inference.
                    // Must run on main: streamingAssembler is main-queue-only state.
                    self.emit(takeID, .partialText(self.streamingAssembler.append(partial)))
                    self.isStreamingInFlight = false
                    // T2.3 — record THIS completed pass (raw partial + samples it saw + when it
                    // finished) so a fast key-release can reuse it instead of a fresh final pass.
                    // Guard on generation: a stop that already bumped the generation must not have
                    // its (now-stale) partial revived by a late-arriving completion.
                    if self.streamingGeneration == generation {
                        self.lastStreamingRawPartial = partial
                        self.lastStreamingSampleCount = streamedSampleCount
                        self.lastStreamingCompletedAt = CFAbsoluteTimeGetCurrent()
                    }
                }
            } catch {
                DiagnosticLogger.shared.log("Streaming: chunk failed — \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isStreamingInFlight = false
                }
            }
        }
    }

    /// T2.3 — clear the saved last-streaming-pass state (called at streaming START so a new
    /// recording can't reuse the previous recording's partial).
    private func resetStreamingReuseState() {
        lastStreamingRawPartial = ""
        lastStreamingSampleCount = 0
        lastStreamingCompletedAt = 0
    }
}
