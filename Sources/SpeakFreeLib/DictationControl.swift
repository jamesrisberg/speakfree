import Foundation

/// Lifecycle of a dictation as seen over the local API. `idle` is only ever a stream state (no
/// dictation in progress); a session moves recording → transcribing → done | error, or → cancelled.
public enum DictationPhase: String, Equatable {
    case idle, recording, transcribing, done, error, cancelled

    var isTerminal: Bool { self == .done || self == .error || self == .cancelled }
}

/// One API-started dictation. Text fields are filled only for `destination == .caller` sessions
/// that finished; a cursor session's text goes to the focused app, never back over the API.
public struct DictationAPISession: Equatable {
    public let id: UUID
    public internal(set) var destination: DictationDestination
    public internal(set) var phase: DictationPhase
    public internal(set) var result: CallerFinalizePayload?
    public internal(set) var error: String?
}

/// The recording pipeline the control center drives. `DictationSession` conforms; tests
/// substitute a stub so no microphone or model is needed.
@MainActor
protocol DictationDriver: AnyObject {
    /// True while a take is being captured (key held, toggle on, or post-buffer still running).
    var isDictating: Bool { get }
    /// Engine id of the active transcriber (e.g. "parakeet", "whisper").
    var activeEngineID: String { get }
    /// Current input level, 0...1.
    var inputLevel: Float { get }
    /// Start recording for an API session. Returns nil once recording started, else a reason.
    /// The driver must report the outcome through the control center's `pipeline…` hooks.
    func startAPIDictation(sessionID: UUID, destination: DictationDestination) -> String?
    /// Stop capture and finalize (same path as releasing the hotkey).
    func stopAPIDictation()
    /// Abort capture and discard the take.
    func cancelAPIDictation()
}

extension DictationSession: DictationDriver {
    var isDictating: Bool { isCapturing }
    var activeEngineID: String { engineID }

    func startAPIDictation(sessionID: UUID, destination: DictationDestination) -> String? {
        // A start during the post-buffer would continue the hotkey take, not begin this session.
        guard !isCapturing else { return DictationFailure.busy.message }
        switch start(destination: destination, takeID: sessionID) {
        case .started, .resumed:
            return nil
        case .refused(let failure) where failure == .notReady || failure == .busy:
            return failure.message
        case .refused, .failed:
            return DictationFailure.microphoneUnavailable.message
        }
    }

    func stopAPIDictation() { stopRecording() }

    func cancelAPIDictation() { cancel() }
}

/// Session registry + event fan-out for the local API's dictation control endpoints.
///
/// Main actor only: the server hops to the main queue before calling in, and the dictation
/// session reports progress from main. That keeps the state machine free of locks and in the same
/// order as the pipeline that drives it.
///
/// Every dictation — hotkey or API — is reported through the `pipeline…` hooks so `/v1/events`
/// subscribers see one consistent state stream. Events never carry transcript text: a subscriber
/// learns THAT a dictation finished, and only the session's own caller can fetch its text.
@MainActor
final class DictationControlCenter {

    nonisolated static let defaultTimeoutMs = 5 * 60 * 1_000
    nonisolated static let maxTimeoutMs = 30 * 60 * 1_000
    nonisolated static let levelInterval: TimeInterval = 0.1
    nonisolated static let keepaliveInterval: TimeInterval = 15
    /// Finished sessions kept for `GET /v1/dictation/{id}`.
    nonisolated static let retainedSessions = 32

    enum ControlError: Error, Equatable {
        case notReady
        case busy
        case engineMismatch(active: String)
        case notFound
        case startFailed(String)
        case invalidTransition(DictationPhase)
    }

    weak var driver: DictationDriver?

    private(set) var sessions: [UUID: DictationAPISession] = [:]
    private var sessionOrder: [UUID] = []
    /// The API session currently recording or transcribing, if any.
    private(set) var activeSessionID: UUID?
    /// Stream state: what `/v1/events` last announced.
    private(set) var streamPhase: DictationPhase = .idle
    private var streamSessionID: UUID?

    private var subscribers: [UUID: (String) -> Void] = [:]
    private var stopWaiters: [UUID: [(DictationAPISession) -> Void]] = [:]
    private var timeoutWork: DispatchWorkItem?
    private var levelTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?

    nonisolated init() {}

    // MARK: - Control (called by LocalAPIServer on main)

    func start(destination: DictationDestination, engine: String?, timeoutMs: Int?) -> Result<DictationAPISession, ControlError> {
        guard let driver = driver else { return .failure(.notReady) }
        if let engine = engine, engine != driver.activeEngineID {
            return .failure(.engineMismatch(active: driver.activeEngineID))
        }
        if activeSessionID != nil || driver.isDictating { return .failure(.busy) }

        let id = UUID()
        remember(DictationAPISession(id: id, destination: destination, phase: .recording, result: nil, error: nil))
        activeSessionID = id
        if let reason = driver.startAPIDictation(sessionID: id, destination: destination) {
            // The driver may already have reported pipelineDidFail; finish() settles only once.
            finish(id, phase: .error, error: reason)
            return .failure(.startFailed(reason))
        }

        let ms = min(max(timeoutMs ?? Self.defaultTimeoutMs, 1), Self.maxTimeoutMs)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.sessions[id]?.phase == .recording else { return }
            DiagnosticLogger.shared.log("LocalAPI: dictation session timed out after \(ms) ms — stopping")
            self.driver?.stopAPIDictation()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
        return .success(sessions[id]!)
    }

    /// Stop recording and call `completion` once the session reaches a terminal phase (immediately
    /// if it already has — stop is idempotent).
    func stop(id: UUID, completion: @escaping (DictationAPISession) -> Void) -> ControlError? {
        guard let session = sessions[id] else { return .notFound }
        if session.phase.isTerminal { completion(session); return nil }
        stopWaiters[id, default: []].append(completion)
        if session.phase == .recording {
            timeoutWork?.cancel()
            driver?.stopAPIDictation()
        }
        return nil
    }

    /// Cancel a session. While recording the take is discarded. While transcribing, a caller
    /// session's result is discarded; a cursor session cannot be recalled (the text is about to be
    /// typed), so that is refused.
    func cancel(id: UUID) -> Result<DictationAPISession, ControlError> {
        guard let session = sessions[id] else { return .failure(.notFound) }
        switch session.phase {
        case .recording:
            timeoutWork?.cancel()
            driver?.cancelAPIDictation()
            // The driver reports pipelineDidCancel; settle here too in case it did not.
            finish(id, phase: .cancelled)
        case .transcribing where session.destination == .caller:
            finish(id, phase: .cancelled)
        case .cancelled:
            break
        default:
            return .failure(.invalidTransition(session.phase))
        }
        return .success(sessions[id]!)
    }

    func session(id: UUID) -> DictationAPISession? { sessions[id] }

    // MARK: - Session events

    /// Drive `session` and report every take it runs, hotkey ones included. Attach before the
    /// host adds its own observer, so an API caller hears about a finished or failed take before
    /// the host presents anything modal.
    func attach(to session: DictationSession) {
        driver = session
        session.addObserver { [weak self] takeID, event in
            self?.sessionDidReport(takeID: takeID, event: event)
        }
    }

    private func sessionDidReport(takeID: UUID, event: DictationEvent) {
        // Takes this center did not start are hotkey dictations: no session, nil id.
        let id: UUID? = sessions[takeID] == nil ? nil : takeID
        switch event {
        case .recording:
            pipelineDidStartRecording(sessionID: id)
        case .transcribing:
            pipelineDidBeginTranscribing(sessionID: id)
        case .retargeted(let destination):
            if let id, sessions[id]?.phase.isTerminal == false { sessions[id]?.destination = destination }
        case .finished(let result):
            switch result.delivery {
            case .returnedToCaller:
                pipelineDidFinish(sessionID: id, result: CallerFinalizePayload(
                    sessionID: takeID, raw: result.raw, processed: result.processed, styled: result.styled))
            case .editSession:
                pipelineDidFinish(sessionID: nil, result: nil)
            case .inserted, .copiedToClipboard, .nothingToInsert:
                pipelineDidFinish(sessionID: id, result: nil)
            }
        case .failed(let failure):
            pipelineDidFail(sessionID: id, message: failure.message)
        case .cancelled:
            pipelineDidCancel(sessionID: id)
        default:
            break
        }
    }

    // MARK: - Pipeline hooks (called on main for EVERY dictation)
    //
    // `sessionID` is nil for hotkey dictations: they still move the event stream, but no session.

    func pipelineDidStartRecording(sessionID: UUID?) {
        publishState(.recording, sessionID: sessionID)
        startLevelSamplingIfNeeded()
    }

    func pipelineDidBeginTranscribing(sessionID: UUID?) {
        stopLevelSampling()
        if let id = sessionID, sessions[id]?.phase == .recording {
            sessions[id]?.phase = .transcribing
        }
        publishState(.transcribing, sessionID: sessionID)
    }

    func pipelineDidFinish(sessionID: UUID?, result: CallerFinalizePayload?) {
        stopLevelSampling()
        if let id = sessionID {
            // A caller session cancelled mid-transcription stays cancelled; its text is dropped.
            guard sessions[id]?.phase.isTerminal == false else { return }
            sessions[id]?.result = result
            finish(id, phase: .done)
        } else {
            publishState(.done, sessionID: nil)
            publishState(.idle, sessionID: nil)
        }
    }

    func pipelineDidFail(sessionID: UUID?, message: String) {
        stopLevelSampling()
        if let id = sessionID {
            finish(id, phase: .error, error: message)
        } else {
            publishState(.error, sessionID: nil, error: message)
            publishState(.idle, sessionID: nil)
        }
    }

    func pipelineDidCancel(sessionID: UUID?) {
        stopLevelSampling()
        if let id = sessionID {
            finish(id, phase: .cancelled)
        } else {
            publishState(.idle, sessionID: nil)
        }
    }

    // MARK: - Event stream

    /// Register an SSE writer. It immediately receives the current state. Returns a token for
    /// `unsubscribe`.
    func subscribe(_ send: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = send
        send(Self.stateFrame(streamPhase, sessionID: streamSessionID, error: nil))
        startKeepaliveIfNeeded()
        if streamPhase == .recording { startLevelSamplingIfNeeded() }
        return token
    }

    func unsubscribe(_ token: UUID) {
        subscribers[token] = nil
        if subscribers.isEmpty {
            stopLevelSampling()
            keepaliveTimer?.cancel()
            keepaliveTimer = nil
        }
    }

    var subscriberCount: Int { subscribers.count }

    /// Emit one input-level sample. Driven by the 10 Hz timer while recording; internal so tests
    /// can sample deterministically.
    func sampleLevel() {
        guard streamPhase == .recording, let level = driver?.inputLevel else { return }
        broadcast(Self.levelFrame(level, sessionID: streamSessionID))
    }

    // MARK: - SSE framing (pure, unit-tested)

    /// One Server-Sent Events frame. Multi-line data is split into one `data:` line per line, as
    /// the SSE spec requires, and the frame ends with the blank-line terminator.
    nonisolated static func sseFrame(event: String?, data: String) -> String {
        var out = ""
        if let event = event { out += "event: \(event)\n" }
        let lines = data.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines { out += "data: \(line)\n" }
        return out + "\n"
    }

    nonisolated static func stateFrame(_ phase: DictationPhase, sessionID: UUID?, error: String?) -> String {
        var obj: [String: Any] = ["state": phase.rawValue, "id": sessionID?.uuidString ?? NSNull()]
        if let error = error { obj["error"] = error }
        return sseFrame(event: "state", data: json(obj))
    }

    nonisolated static func levelFrame(_ level: Float, sessionID: UUID?) -> String {
        let rounded = (Double(max(0, min(1, level))) * 1000).rounded() / 1000
        return sseFrame(event: "level", data: json(["level": rounded, "id": sessionID?.uuidString ?? NSNull()]))
    }

    /// SSE comment line; keeps idle connections alive and surfaces dead clients as send errors.
    nonisolated static let keepaliveFrame = ": keepalive\n\n"

    /// JSON view of a session for the HTTP responses. Text only for finished caller sessions.
    nonisolated static func sessionJSON(_ s: DictationAPISession) -> String {
        var obj: [String: Any] = [
            "id": s.id.uuidString,
            "state": s.phase.rawValue,
            "destination": s.destination.rawValue,
        ]
        if let e = s.error { obj["error"] = e }
        if s.destination == .caller, s.phase == .done, let r = s.result {
            obj["raw"] = r.raw
            obj["processed"] = r.processed
            obj["styled"] = r.styled
        }
        return json(obj)
    }

    nonisolated static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Internals

    private func remember(_ session: DictationAPISession) {
        sessions[session.id] = session
        sessionOrder.append(session.id)
        while sessionOrder.count > Self.retainedSessions {
            let old = sessionOrder.removeFirst()
            if old != activeSessionID { sessions[old] = nil }
        }
    }

    /// Settle a session exactly once; later reports for the same session are ignored.
    private func finish(_ id: UUID, phase: DictationPhase, error: String? = nil) {
        guard let current = sessions[id], !current.phase.isTerminal else { return }
        sessions[id]?.phase = phase
        if let error = error { sessions[id]?.error = error }
        if activeSessionID == id {
            activeSessionID = nil
            timeoutWork?.cancel()
            timeoutWork = nil
        }
        publishState(phase, sessionID: id, error: error)
        publishState(.idle, sessionID: nil)
        if let session = sessions[id], let waiters = stopWaiters.removeValue(forKey: id) {
            waiters.forEach { $0(session) }
        }
    }

    private func publishState(_ phase: DictationPhase, sessionID: UUID?, error: String? = nil) {
        streamPhase = phase
        streamSessionID = phase == .idle ? nil : sessionID
        broadcast(Self.stateFrame(phase, sessionID: streamSessionID, error: error))
    }

    private func broadcast(_ frame: String) {
        for send in subscribers.values { send(frame) }
    }

    private func startLevelSamplingIfNeeded() {
        guard levelTimer == nil, !subscribers.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.levelInterval, repeating: Self.levelInterval)
        timer.setEventHandler { [weak self] in self?.sampleLevel() }
        timer.resume()
        levelTimer = timer
    }

    private func stopLevelSampling() {
        levelTimer?.cancel()
        levelTimer = nil
    }

    private func startKeepaliveIfNeeded() {
        guard keepaliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.keepaliveInterval, repeating: Self.keepaliveInterval)
        timer.setEventHandler { [weak self] in self?.broadcast(Self.keepaliveFrame) }
        timer.resume()
        keepaliveTimer = timer
    }
}
