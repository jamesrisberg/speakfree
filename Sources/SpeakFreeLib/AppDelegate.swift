// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-13
// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-09
import AppKit
import ApplicationServices
import AVFoundation
import os

public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusBar: StatusBarController!
    var hotkeyManager: HotkeyManager?
    var recorder: AudioRecorder!
    var transcriber: Transcriber! {
        didSet {
            let transcriber = transcriber
            onMainActor { [weak self] in self?.session?.transcriber = transcriber }
        }
    }
    var inserter: TextInserter!
    var config: Config! {
        didSet {
            guard let config else { return }
            let configuration = DictationConfiguration(config: config)
            onMainActor { [weak self] in self?.session?.configuration = configuration }
        }
    }
    /// The recording flow. Hotkey presses, the local API and the menu all drive this one session;
    /// the app presents what it reports (`present(_:)`).
    private(set) var session: DictationSession?
    var isReady = false {
        didSet { updateSessionAvailability() }
    }
    public var lastTranscription: String?
    private var recordingOverlay = RecordingOverlay()
    private var settingsViewModel: SettingsViewModel?
    private var localAPIServer: LocalAPIServer?
    /// Session registry + /v1/events fan-out for the local API. It observes every take.
    private(set) lazy var dictationControl = DictationControlCenter()
    /// True while an edit session window is open — extends the config-reload defer (MAP §8).
    var editSessionOpenProbe: (() -> Bool)?
    /// Routes an Edit-mode fn-tap through the EditSessionController (Phase 2). nil = fall back to
    /// toggle semantics so keyMode:"edit" still dictates before the controller exists.
    var editHotkeyRouter: (() -> Void)?

    // Clean up whisper model before exit to prevent ggml Metal assertion crash.
    // The crash happens in __cxa_finalize_ranges when ggml tries to free Metal
    // residency sets that are still active during static destructor cleanup.
    public func applicationWillTerminate(_ notification: Notification) {
        // Close an in-flight recording FIRST (2026-07-25 audit F7): a clean quit
        // (Cmd-Q, logout, Sparkle relaunch) previously left the wav header uncommitted —
        // total loss, same as a crash. stopRecording() drains the write queue and
        // patches the header; the wav then survives for the launch orphan sweep.
        if recorder?.stopRecording() != nil {
            DiagnosticLogger.shared.log("Terminate: closed in-flight recording for recovery")
        }
        // applicationWillTerminate cannot await — bridge the async unload to sync via the
        // transcriber's synchronous passthrough (semaphore-backed inside Transcriber).
        transcriber?.unloadModelSync()
        hotkeyManager?.stop()
        recorder?.shutdown()
        localAPIServer?.stop()
    }

    /// The app's updater, injected by the speakfree executable before launch; nil for hosts
    /// that embed dictation. Started from setupInner only (see SparkleUpdater).
    public var updater: AppUpdater?

    // Last time the transcription-failure alert was shown; a persistently broken engine
    // fails every attempt, and the modal is throttled to one per 5 minutes (main-only).
    private var lastTranscriptionFailureAlert: Date?
    // Recordings apology notice (2026-07-14): retained while showing; the timer re-shows
    // it every few hours until the user decides keep/delete. Main-only.
    private var recordingsNoticeController: RecordingsNoticeController?
    private var recordingsNoticeTimer: Timer?
    // Graceful SIGTERM (2026-07-14): a reinstall/kill must never eat an in-flight
    // dictation. The source is retained for process lifetime.
    private var sigtermSource: DispatchSourceSignal?
    // Draining after SIGTERM (2026-07-25): new recordings are refused while waiting to
    // exit — one started post-SIGTERM races the exit and its audio dies in memory.
    private var isTerminating = false {
        didSet { updateSessionAvailability() }
    }
    // Idle tap-health poll (2026-07-25). Main-only.
    private var tapHealthTimer: Timer?
    // L1: a config reload that lands while a dictation is in flight (fn held) must NOT mutate live
    // dictation state — it would (a) rebuild the HotkeyManager mid-press (recreating the event tap
    // loses the pending key-release, so the recording never stops and the next utterance merges
    // in), (b) swap the transcriber, finalizing THIS utterance on the wrong engine, and (c) flip
    // config.toggleMode so a Hold→Toggle switch mid-press makes handleKeyUp return early and strand
    // the running recording. So the ENTIRE reloadConfig is deferred by setting this flag; it is
    // re-run in full the moment the dictation ends (finalize / key-up / abort). The hotkey rebuild
    // happens inside the deferred reloadConfig, same as when not pressed. Main-only.
    private var pendingConfigReload = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Cap ALL AX messaging process-wide at 0.5 s. The AX default is an INDEFINITE block
        // when the target app is hung — set once on the system-wide element so no AX call
        // anywhere (insert path, RecordingOverlay, menu focus queries) can stall us into a
        // beachball waiting on an unresponsive frontmost app (AX-A).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        statusBar = StatusBarController()
        statusBar.updater = updater
        recorder = AudioRecorder()
        inserter = TextInserter()
        makeSession()
        installGracefulTermination()

        // Device catalog cache: the ONLY CoreAudio the main thread ever sees. Refreshes
        // off-main at launch and on device changes; the menu rebuilds from the cache.
        AudioDeviceCatalog.onCacheRefreshed = { [weak self] in
            self?.recorder.handleDeviceListChanged(AudioDeviceCatalog.cachedInputDevices)
            self?.statusBar.buildMenu()
        }
        recorder.onCaptureStatus = { [weak self] message in
            guard let self else { return }
            self.statusBar.captureMessage = message
            if self.statusBar.state == .recording {
                self.recordingOverlay.updateStreamingText(message)
            }
        }
        AudioDeviceCatalog.startCache()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.setup()
        }
    }

    /// Handles dock-drag, Finder "Open With", and `speakfree <file>` — all funnel here.
    public func application(_ application: NSApplication, open urls: [URL]) {
        let audioExtensions: Set<String> = ["m4a","mp3","wav","flac","aiff","aif","caf","aac","mp4","mov","ogg"]
        let audioURLs = urls.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard let first = audioURLs.first else { return }
        DispatchQueue.main.async {
            FileTranscriptionController.show(url: first)
        }
    }

    // MARK: - Setup failure seam

    /// Injectable executor: tests replace this to simulate a throw without running the full setup.
    /// Production code leaves it nil — `setup()` calls `setupInner()` directly.
    var _setupExecutor: (() throws -> Void)?
    private let setupGate = SetupGate()

    private func setup() {
        guard setupGate.begin() else { return }
        defer {
            // Keep the gate closed until queued UI initialization has finished too.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.setupGate.finish() { self.reloadConfig() }
            }
        }
        do {
            if let executor = _setupExecutor {
                try executor()
            } else {
                try setupInner()
            }
        } catch {
            let message = error.localizedDescription
            DiagnosticLogger.shared.log("Fatal setup error: \(message)")

            // Transition the menu bar to the visible error state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.statusBar.state = .setupFailed(message: message)
                self.statusBar.buildMenu()
            }

            // Surface a modal alert. Runs on main so we block the setup thread here
            // until the user dismisses — the process stays alive and in the error state.
            let present = { [weak self] in self?.showSetupFailureAlert(message: message) }
            if Thread.isMainThread { present() } else { DispatchQueue.main.sync(execute: present) }
        }
    }

    /// Shows a blocking NSAlert describing the setup failure.
    /// Separated from `setup()` so it can be replaced by a seam in tests.
    var _alertPresenter: ((String) -> Void)?

    func showSetupFailureAlert(message: String) {
        if let presenter = _alertPresenter {
            presenter(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "speakfree failed to start"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Continue Anyway")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        }
        // If the user clicked "Continue Anyway" the app stays alive in the error state.
    }

    /// Test-only bridge — calls `setup()` directly so tests can exercise the failure path
    /// without going through `applicationDidFinishLaunching`. Not called by production code.
    func runSetupForTesting() {
        setup()
    }

    // MARK: Legacy Parakeet model resolution (audit 2026-07-01, Michael's call)

    /// Test seam for the legacy model prompt — receives whether v3 is already on
    /// disk, returns the chosen model id. nil = show the real NSAlert.
    var _legacyModelPrompter: ((_ v3Downloaded: Bool) -> String)?

    /// Configs written before Parakeet-first onboarding can have engine=parakeet
    /// with no `parakeetModel` key. The old `?? v3` fallback silently steered
    /// those users to the multilingual model while the product default moved to
    /// v2 (faster English). Instead of silently picking either, ask ONCE at
    /// launch and persist the answer, so the config always carries an explicit
    /// choice afterwards.
    func resolveLegacyParakeetModel() -> String {  // internal for tests (seam: _legacyModelPrompter)
        if let explicit = config.parakeetModel { return explicit }
        let v3Downloaded = ParakeetModelManager.shared.isModelDownloaded("parakeet-tdt-0.6b-v3")
        let chosen = _legacyModelPrompter?(v3Downloaded)
            ?? Self.promptLegacyParakeetChoice(v3Downloaded: v3Downloaded)
        config.parakeetModel = chosen
        try? config.save()
        DiagnosticLogger.shared.log(
            "Legacy Parakeet config had no model choice — user chose \(chosen) (v3 on disk: \(v3Downloaded))")
        return chosen
    }

    /// Blocking one-time choice dialog. Runs on main (setup calls this off-main);
    /// the default button favors not surprising the user: keep multilingual if
    /// it's already installed and in use, recommend English v2 otherwise.
    private static func promptLegacyParakeetChoice(v3Downloaded: Bool) -> String {
        var choice = Config.defaultParakeetModel
        let present = {
            let alert = NSAlert()
            alert.messageText = "Choose your dictation model"
            alert.alertStyle = .informational
            if v3Downloaded {
                alert.informativeText = """
                speakfree now uses a faster English-only model by default. \
                You currently have the multilingual model installed.

                Keep multilingual, or switch to the faster English model? \
                Switching downloads about 600 MB. You can change this anytime in Settings.
                """
                alert.addButton(withTitle: "Keep Multilingual")
                alert.addButton(withTitle: "Switch to English (Faster)")
                choice = alert.runModal() == .alertFirstButtonReturn
                    ? "parakeet-tdt-0.6b-v3" : "parakeet-tdt-0.6b-v2"
            } else {
                alert.informativeText = """
                speakfree now uses a faster English-only model by default.

                Use English (recommended), or the multilingual model if you \
                dictate in other languages? You can change this anytime in Settings.
                """
                alert.addButton(withTitle: "English (Recommended)")
                alert.addButton(withTitle: "Multilingual")
                choice = alert.runModal() == .alertFirstButtonReturn
                    ? "parakeet-tdt-0.6b-v2" : "parakeet-tdt-0.6b-v3"
            }
        }
        if Thread.isMainThread { present() } else { DispatchQueue.main.sync(execute: present) }
        return choice
    }

    private func completeRecordingsSetupIfNeeded() -> Bool {
        // Avoid scanning a large corpus on ordinary reloads or developer machines.
        guard RecordingsSetup.shouldPresent(config: config, hasRecordings: false,
                                            developerMode: DevMode.isActive) else { return true }
        let hasRecordings = RecordingStore.hasAudioFiles()
        guard RecordingsSetup.shouldPresent(config: config, hasRecordings: hasRecordings,
                                            developerMode: DevMode.isActive) else { return true }
        let fileCount = hasRecordings ? RecordingStore.recordingCount() : 0
        let folderPath = RecordingStore.recordingsDir.path
        var proceeded = false
        let present = {
            proceeded = RecordingsSetupController.show(hasRecordings: hasRecordings,
                                                       fileCount: fileCount, folderPath: folderPath)
        }
        if Thread.isMainThread {
            present()
        } else {
            let finished = DispatchSemaphore(value: 0)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                present()
                finished.signal()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            finished.wait()
        }
        guard proceeded else {
            // Closing initial setup leaves no implicit answer. Quit gracefully so
            // the next launch asks again rather than leaving a non-recording app.
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
        config = Config.load()
        return true
    }

    private func setupInner() throws {
        DiagnosticLogger.shared.setup()
        DiagnosticLogger.shared.log("Setup started")
        config = Config.load()
        // Ask before pruning, recovery, downloads or live capture. This single gate
        // covers both cached models and Welcome's automatic post-download restart.
        guard completeRecordingsSetupIfNeeded() else { return }
        // One-line effective-config snapshot (Michael 2026-08-20: forensics need the
        // settings a session actually ran with, not a guess from the current file).
        var cfgParts: [String] = []
        cfgParts.append("engine=" + (config.engine ?? "whisper"))
        cfgParts.append("model=" + config.modelSize)
        cfgParts.append("parakeetModel=" + (config.parakeetModel ?? "-"))
        cfgParts.append("input=" + (config.inputDeviceUID ?? "system-default"))
        cfgParts.append("punctuation=\(config.effectivePunctuationMode)")
        cfgParts.append("streaming=\(config.streamingEnabled?.value ?? true)")
        cfgParts.append("preBuffer=\(config.preBuffer?.value ?? true)")
        cfgParts.append("keepLoaded=" + (config.keepModelLoaded ?? "auto"))
        cfgParts.append("saveRecordings=\(config.saveRecordings?.value ?? false)")
        cfgParts.append("screenContext=\(config.screenContext?.value ?? false)")
        cfgParts.append("language=" + config.language)
        DiagnosticLogger.shared.log("Config: " + cfgParts.joined(separator: " "))

        // Start Sparkle from the real launch path only (see updaterController's
        // comment — starting it at construction deadlocked the test suite).
        // setupInner runs off-main; the updater expects a main-thread start.
        // Bundle-gated: the bare CLI binary has no Info.plist, so Sparkle cannot
        // initialize there and throws an "Unable to Check For Updates" alert at launch.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            DispatchQueue.main.async { [weak self] in
                self?.updater?.start()
            }
        }

        // Check for crash recovery before touching recordings
        // Recovery (rebuilt 2026-07-25): the sentinel is one pointer, but the real
        // inventory is the ORPHAN SWEEP — any recent wav without a transcript sidecar,
        // headers repaired in place. The old handler (`reprocess`) only re-read a .txt
        // that a crashed recording never has; recovery now actually TRANSCRIBES.
        let maxRecordings = (DevMode.isActive || !DevMode.effectiveSaveRecordings(config) || config.preserveAllRecordings?.value == true)
            ? 0 : Config.effectiveMaxRecordings(config.maxRecordings)
        if maxRecordings > 0 {
            RecordingStore.prune(maxCount: maxRecordings)
        }

        // (Prune runs FIRST — codex review #2: pruning after the sweep could delete
        // an orphan mid-recovery.)
        // AUTO-recovery (Michael, 2026-07-25: "why should I have to click?"): orphans
        // are transcribed in the background at launch — no menu click, no clipboard
        // side effects. Results land as transcript sidecars, so recovered dictations
        // appear in Recent Dictations (where a click inserts them). Each orphan waits
        // for an idle moment so a live dictation's inference never queues behind a
        // recovery chunk. Empty transcripts (room tone) get an empty sidecar so
        // they're never re-swept. Failures stay orphaned and retry next launch.
        RecordingStore.clearSentinel()
        let orphans = RecordingStore.sweepRecoverableOrphans()
        if !orphans.isEmpty {
            DiagnosticLogger.shared.log(String(
                format: "Recovery: %d orphan(s) queued for background transcription (newest %@, %.0fs)",
                orphans.count, orphans[0].url.lastPathComponent, orphans[0].seconds))
            autoRecoverOrphans(orphans.map(\.url))
        }


        // Recordings notice (2026-07-14; corpus framing 2026-08-21): saving shipped
        // on-by-default through v1.7.1; the notice lets users keep or delete what
        // accumulated. Returns every
        // launch (and every few hours, below) until resolved. Dev machines are exempt —
        // the corpus there is intentional.
        switch DevMode.isActive
            ? RecordingsNotice.LaunchAction.nothing
            : RecordingsNotice.launchAction(decision: config.recordingsNoticeDecision,
                                            hasRecordings: RecordingStore.hasAudioFiles()) {
        case .markNotApplicable:
            var updated = Config.load()
            updated.recordingsNoticeDecision = "none-found"
            try? updated.save()
        case .show:
            DispatchQueue.main.async { [weak self] in self?.showRecordingsNotice() }
        case .nothing:
            break
        }

        // One-time migration: clean garbage auto-learned entries
        DispatchQueue.main.sync {
            VocabularyMigration.runIfNeeded()
        }

        // Resolve the engine + model identifier, then check whether the model is on disk.
        // If not, show the welcome dialog for both Whisper and Parakeet.
        let engineID = effectiveEngineID
        var modelID: String
        var needsDownload = false

        if engineID == "parakeet" {
            modelID = resolveLegacyParakeetModel()
            needsDownload = !ParakeetModelManager.shared.isModelDownloaded(modelID)
        } else {
            // Determine effective model (multilingual if needed)
            var effectiveModelSize = config.modelSize
            if config.language != "en" && WhisperLanguage.isEnglishOnly(config.modelSize) {
                effectiveModelSize = WhisperLanguage.multilingualModel(for: config.modelSize)
                print("Language \(config.language) requires multilingual model — using \(effectiveModelSize)")
            }

            if !Transcriber.modelExists(modelSize: effectiveModelSize) {
                // Fallback: if we wanted multilingual but only have .en, use .en —
                // same size class, so transcription quality is unchanged.
                if effectiveModelSize != config.modelSize && Transcriber.modelExists(modelSize: config.modelSize) {
                    DiagnosticLogger.shared.log("Multilingual model \(effectiveModelSize) not found — using \(config.modelSize) as fallback")
                    effectiveModelSize = config.modelSize
                }
                else {
                    // NO silent quality fallback. Substituting "any model on disk" once
                    // swapped tiny.en in for a missing large-v3-turbo and silently degraded
                    // every dictation for days (2026-06-11 collapse). A missing model gets
                    // the explicit download dialog, pre-set to the configured model.
                    DiagnosticLogger.shared.log("Configured model \(effectiveModelSize) missing from disk — showing download dialog (no silent fallback)")
                    needsDownload = true
                }
            }
            modelID = effectiveModelSize
        }

        if needsDownload {
            var selectedEngine = engineID
            var selectedModel = modelID
            var selectedLanguage = config.language
            var didProceed = false
            // Present the onboarding modal via the main RUN LOOP, NOT DispatchQueue.main.sync.
            // WelcomeController.show() runs NSApp.runModal; its nested run loop must keep draining the
            // main dispatch queue so the Parakeet download's progress callbacks AND its post-download
            // MainActor hops (finalize, compileAndCache, markDownloaded) can run. Launching the modal
            // from a main-queue dispatch block makes libdispatch treat the main queue as mid-drain and
            // starves every other main-queue block for the modal's whole lifetime: the ~600 MB model
            // downloads to disk, but the UI freezes at 0% and the install never finishes (the Task
            // hangs at the first `await MainActor.run`). CFRunLoopPerformBlock runs as a run-loop
            // activity, not a dispatch item, so the nested modal loop drains the main queue normally.
            let presentWelcome = {
                let result = WelcomeController.show(suggestedEngine: engineID, suggestedModel: modelID)
                selectedEngine = result.engine
                selectedModel = result.modelID
                selectedLanguage = result.language
                didProceed = result.shouldContinue
            }
            if Thread.isMainThread {
                presentWelcome()
            } else {
                let welcomeDone = DispatchSemaphore(value: 0)
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    presentWelcome()
                    welcomeDone.signal()
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                welcomeDone.wait()
            }
            guard didProceed else {
                DispatchQueue.main.async {
                    self.statusBar.state = .noModel
                    self.statusBar.buildMenu()
                }
                return
            }
            // Proceeding out of the needsDownload path means a model was just downloaded — flag it so
            // the re-run of setup() ends on the green `.ready` icon (see startListening()).
            justDownloadedModel = true
            config.engine = selectedEngine
            config.language = selectedLanguage
            if selectedEngine == "parakeet" {
                config.parakeetModel = selectedModel
            } else {
                config.modelSize = selectedModel
            }
            try? config.save()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.setup() }
            return
        }

        let engine = EngineFactory.make(config: config)
        transcriber = Transcriber(engine: engine, modelID: modelID, language: config.language)
        wireSecondOpinionStatus(for: transcriber)
        activeEngineID = engineID
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)
        DiagnosticLogger.shared.log("Transcriber configured: \(modelID) (engine: \(engineID))")

        // Apply routing BEFORE enabling pre-buffer. Assigning preBufferEnabled=true
        // starts the engine immediately; doing that first briefly opens the system
        // default route and then races the route-triggered rebuild at launch.
        let inputDeviceUID = config.inputDeviceUID
        let preBufferEnabled = config.preBuffer?.value ?? true
        DispatchQueue.main.async { [weak self] in
            self?.recorder.setPinnedInputDevice(uid: inputDeviceUID)
            self?.recorder.preBufferEnabled = preBufferEnabled
        }

        // Configure model persistence
        transcriber.keepModelLoaded = config.keepModelLoaded ?? "auto"
        transcriber.startMemoryPressureMonitoring()
        warmUpEngine(engineID)

        DispatchQueue.main.async {
            self.statusBar.reprocessHandler = { [weak self] url in
                self?.reprocess(audioURL: url)
            }
            self.statusBar.buildMenu()
        }

        // Whisper-only startup gate: a Parakeet setup has no whisper-cli/whisper-binary and
        // must not be blocked here. Gate on the effective engine so permissions/hotkeys still init.
        if engineID == "whisper" && Transcriber.findWhisperBinary() == nil {
            print("Error: whisper-cpp not found. Install it with: brew install whisper-cpp")
            return
        }

        Permissions.ensureMicrophone()

        // For Developer ID signed releases, macOS tracks TCC grants by bundle ID + team ID,
        // both of which stay constant across version updates. Resetting TCC on every version
        // bump breaks first launch after every release — don't do it.
        // For beta (ad-hoc signed) builds, the code identity changes on each rebuild, so we
        // still reset there to avoid stale grants.
        let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true
        if isBeta && Permissions.didUpgrade() {
            print("Beta upgrade detected — resetting Accessibility trust")
            Permissions.resetAccessibility()
        } else {
            _ = Permissions.didUpgrade()  // still update .last-version file
        }

        if !AXIsProcessTrusted() {
            print("Accessibility: not granted — prompting...")
            DispatchQueue.main.async {
                self.statusBar.state = .waitingForPermission
                self.statusBar.buildMenu()
            }
            Permissions.promptAccessibility()
            print("Waiting for Accessibility permission...")
            // Bounded wait: re-surface the system dialog every 60 s so the user is never
            // left with a silent infinite poll. Each 60-second cycle consists of 0.5-second
            // checks so we respond quickly when the user grants permission.
            let recheckInterval = 0.5
            let repromptCycle = 60.0
            var elapsed = 0.0
            while !AXIsProcessTrusted() {
                Thread.sleep(forTimeInterval: recheckInterval)
                elapsed += recheckInterval
                if elapsed >= repromptCycle {
                    elapsed = 0.0
                    print("Accessibility: still waiting — re-prompting...")
                    Permissions.promptAccessibility()
                }
            }
            print("Accessibility: granted")
            DispatchQueue.main.async {
                self.statusBar.state = .idle
                self.statusBar.buildMenu()
            }
        } else {
            print("Accessibility: granted")
        }

        // Warm up the audio engine now so first recording starts instantly
        recorder.warmUp()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isSetupComplete = true
            self.startListening()
            if self.openSettingsAfterSetup {
                self.openSettingsAfterSetup = false
                self.showSettings()
            }
            self.showTutorialPopoverIfNeeded()
        }
    }

    private func startListening() {
        hotkeyManager?.stop()
        tapHealthTimer?.invalidate()
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )

        hotkeyManager?.start(
            onKeyDown: { [weak self] in
                self?.handleKeyDown()
            },
            onKeyUp: { [weak self] in
                self?.handleKeyUp()
            },
            onAbort: { [weak self] in
                self?.handleRecordingAbort()
            },
            onUserInteraction: { [weak self] interaction in
                self?.onMainActor { self?.session?.noteUserInteraction(interaction) }
            }
        )

        isReady = true
        // Tap-health poll (2026-07-25 audit: a dead event tap was UNDETECTABLE —
        // the only health check was gated behind a successful keypress). Every 30s,
        // verify and re-arm the tap so "press fn, nothing happens" gets fixed before
        // the user hits it. NOT gated on a held take (2026-08-11): a stranded take —
        // release lost during a tap outage — keeps the session recording indefinitely, so an
        // idle-only poll was disabled during exactly the failure it guards. Running it
        // mid-take is safe: ensureTapHealthy reconciles only when it actually repaired
        // something, so a healthy take in progress is never touched.
        DispatchQueue.main.async { [weak self] in
            self?.tapHealthTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                guard let self = self, !self.isTerminating else { return }
                self.hotkeyManager?.ensureTapHealthy()
            }
        }
        // After a fresh model download, show the green "ready" icon as a "you're all set" cue until
        // the first dictation clears it (handleKeyDown → .recording). Normal launches stay idle.
        if justDownloadedModel {
            justDownloadedModel = false
            statusBar.state = .ready
        } else {
            statusBar.state = .idle
        }
        statusBar.buildMenu()

        let hotkeyDesc = KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)
        print("speakfree v\(SpeakFree.version)")
        print("Hotkey: \(hotkeyDesc)")
        print("Model: \(config.modelSize)")
        let readiness = transcriber.isLoaded ? "Ready" : "Hotkey ready; speech model not loaded yet"
        print(readiness)
        DiagnosticLogger.shared.log("\(readiness) — hotkey=\(hotkeyDesc) model=\(transcriber.modelID)")

        // Start LocalAPIServer on launch if enabled in config (T1.2).
        syncLocalAPIServerState()

        // Verify all subsystems after startup
        verifySubsystems(context: "startup")
    }

    /// Comprehensive health check — logs status of all subsystems.
    /// Call at startup and before each recording.
    private func verifySubsystems(context: String) {
        var issues: [String] = []

        // 1. Status bar icon
        if statusBar.statusItem.button?.image == nil {
            issues.append("status bar icon missing")
            statusBar.state = .idle  // force redraw
        }

        // 2. Event tap
        if let hm = hotkeyManager {
            hm.ensureTapHealthy()
        } else {
            issues.append("hotkeyManager is nil")
        }

        // 3. Audio engine
        recorder.ensureAudioHealthy()

        // 4. Accessibility
        if !AXIsProcessTrusted() {
            issues.append("accessibility not granted")
        }

        // 5. Microphone
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            issues.append("microphone not granted")
        }

        // 6. Model file exists (whisper-only — parakeet models live in FluidAudio's own cache
        //    and are validated by the engine on load, not via a ggml-*.bin lookup).
        //    Gate on the effective engine (honoring SPEAKFREE_ENGINE) so a Parakeet setup
        //    doesn't trip a whisper ggml-*.bin health check.
        if effectiveEngineID == "whisper" {
            if Transcriber.findModel(modelSize: transcriber?.modelID ?? config.modelSize) == nil {
                issues.append("model file missing")
            }
        }

        if issues.isEmpty {
            DiagnosticLogger.shared.log("Health check (\(context)): permissions and controls OK; audio recovery checked asynchronously")
        } else {
            DiagnosticLogger.shared.log("Health check (\(context)): ISSUES — \(issues.joined(separator: ", "))")
            print("⚠️ Health check (\(context)): \(issues.joined(separator: ", "))")
        }
    }

    /// The model identifier currently loaded by the transcriber.
    public var activeModelSize: String { transcriber?.modelID ?? config.modelSize }

    /// The engine id ("whisper" | "parakeet") of the currently-built transcriber. Tracked here
    /// so reloadConfig can detect an engine switch without reaching into transcriber.engine.*.
    private(set) var activeEngineID: String = "whisper" {
        didSet {
            let engineID = activeEngineID
            onMainActor { [weak self] in self?.session?.engineID = engineID }
        }
    }

    /// True once setupInner() has run to completion (hotkey listener started).
    /// While false, the app is in the "no model" state and reloadConfig triggers a full restart.
    private var isSetupComplete = false

    /// Set by WelcomeController's Configure button — opens Settings once setup finishes.
    public var openSettingsAfterSetup = false

    /// True when onboarding just downloaded a model this launch. Consumed by startListening() to show
    /// the green `.ready` icon until the first dictation; reset once shown.
    private var justDownloadedModel = false

    private var tutorialPopover: NSPopover?

    /// The effective engine id, honoring SPEAKFREE_ENGINE the same way EngineFactory does.
    /// Single source of truth so engine creation, model-id selection, and activeEngineID
    /// tracking can never disagree (e.g. building Parakeet but loading a whisper model size).
    private var effectiveEngineID: String {
        ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"] ?? config.engine ?? "whisper"
    }

    /// Decision for reloadConfig's Parakeet branch (UI-B). Settings saves the config the instant a
    /// Parakeet model is picked (EnginePickerView `.onChange` → save → reloadConfig), which can name
    /// a model that hasn't been downloaded yet (the inline Download button is tapped afterward).
    /// Swapping the live transcriber onto an undownloaded model would leave the hotkey active on an
    /// engine that can't transcribe. So rebuild only when the model is actually on disk; otherwise
    /// keep the current transcriber running. Pure so the guard is unit-testable.
    enum ParakeetReloadDecision: Equatable {
        case rebuild(modelID: String)
        case keepCurrent
    }

    static func parakeetReloadDecision(modelID: String, isModelDownloaded: Bool) -> ParakeetReloadDecision {
        isModelDownloaded ? .rebuild(modelID: modelID) : .keepCurrent
    }

    public func reloadConfig() {
        if setupGate.deferReloadIfRunning() { return }
        // L1: never mutate live dictation state mid-utterance. If fn is held (a dictation is in
        // flight), defer the ENTIRE reload — not just the hotkey rebuild — because it also swaps
        // the transcriber (this utterance would finalize on the wrong engine) and flips
        // config.toggleMode (a Hold→Toggle switch while held makes handleKeyUp return early and
        // never stops the recording). Set the flag and bail; every dictation-end path re-runs the
        // full reload once (performPendingConfigReloadIfNeeded), reloading fresh Config.load()
        // state from disk. This is reached from settings save, notice callbacks, and mic select —
        // all correctly get the same defer-if-pressed semantics.
        // Defer the whole reload while a dictation is in flight OR while an edit session is open
        // (MAP §8): swapping the transcriber/hotkey or flipping Key Mode under an open session would
        // strand its segments and change the hotkey out from under it. Every dictation-end path (and
        // Phase 2's session-close path) re-runs the reload once via performPendingConfigReloadIfNeeded.
        if (session?.isCapturing ?? false) || (editSessionOpenProbe?() ?? false) {
            pendingConfigReload = true
            DiagnosticLogger.shared.log("Config: reload deferred — dictation or edit session in flight")
            return
        }

        // In noModel state: only restart full setup if the user has now downloaded a model.
        // Without this check, opening Settings (which calls reloadConfig on save) would
        // re-trigger the welcome dialog even though the user deliberately skipped it.
        guard isSetupComplete else {
            let freshConfig = Config.load()
            let engineID = ProcessInfo.processInfo.environment["SPEAKFREE_ENGINE"]
                ?? freshConfig.engine ?? "whisper"
            let modelAvailable: Bool
            if engineID == "parakeet" {
                // nil model here = legacy config that hasn't been through the launch
                // prompt yet (resolveLegacyParakeetModel). Keep the historical v3
                // fallback for this transient window — silently flipping a legacy
                // v3 user to v2 mid-session would be a surprise model change.
                let modelID = freshConfig.parakeetModel ?? "parakeet-tdt-0.6b-v3"
                modelAvailable = ParakeetModelManager.shared.isModelDownloaded(modelID)
            } else {
                modelAvailable = Transcriber.modelExists(modelSize: freshConfig.modelSize)
                    || findAnyDownloadedModel() != nil
            }
            if modelAvailable {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.setup() }
            }
            return
        }

        config = Config.load()

        // Parakeet: no ggml-on-disk gate (FluidAudio downloads/validates its own cache).
        // Rebuild only when the engine, model, or language changes.
        if effectiveEngineID == "parakeet" {
            // Same transient-window fallback as above — see resolveLegacyParakeetModel.
            let modelID = config.parakeetModel ?? "parakeet-tdt-0.6b-v3"
            switch Self.parakeetReloadDecision(
                modelID: modelID,
                isModelDownloaded: ParakeetModelManager.shared.isModelDownloaded(modelID)) {
            case .rebuild(let id):
                finishReloadConfig(modelID: id)
            case .keepCurrent:
                // Model not downloaded yet — keep the current transcriber usable rather than
                // swapping the hotkey onto an engine that can't transcribe. The Settings
                // Parakeet download banner drives the fetch; a later save rebuilds onto it.
                print("Parakeet model \(modelID) not downloaded — keeping current engine (\(activeEngineID))")
                reloadHotkeyAndSettings()
            }
            return
        }

        var effectiveModelSize = config.modelSize
        if config.language != "en" && WhisperLanguage.isEnglishOnly(config.modelSize) {
            effectiveModelSize = WhisperLanguage.multilingualModel(for: config.modelSize)
            print("Language \(config.language) requires multilingual model — using \(effectiveModelSize)")
        }

        // If we're already on whisper and the model isn't on disk, keep running. But if we're
        // switching FROM parakeet TO whisper, rebuild regardless so the engine actually swaps.
        let switchingFromParakeet = activeEngineID != "whisper"
        if !switchingFromParakeet && !Transcriber.modelExists(modelSize: effectiveModelSize) {
            // Don't auto-download — keep the current transcriber running.
            // The settings UI shows the download prompt inline.
            print("Model \(effectiveModelSize) not on disk — keeping current model (\(activeModelSize))")
            // Still reload hotkey and other settings
            reloadHotkeyAndSettings()
            return
        }

        finishReloadConfig(modelID: effectiveModelSize)
    }

    private func finishReloadConfig(modelID: String) {
        let needsNewEngine = transcriber == nil || activeEngineID != effectiveEngineID
            || transcriber.modelID != modelID || transcriber.language != config.language
        if needsNewEngine {
            let old = transcriber
            let engine = EngineFactory.make(config: config)
            transcriber = Transcriber(engine: engine, modelID: modelID, language: config.language)
            wireSecondOpinionStatus(for: transcriber)
            activeEngineID = effectiveEngineID
            if let old { Task { await old.unloadModel() } }
        }
        transcriber.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

        // Spoken Only on Parakeet: Parakeet ignores suppressAutoPunctuation, and the spoken-word
        // substitution is now identically guarded across Spoken Only and Automatic & Spoken, so the
        // two modes are behaviorally identical here. We do NOT rewrite the stored mode (a user who
        // switches back to Whisper keeps Spoken Only); log one line for observability.
        if effectiveEngineID == "parakeet" && config.spokenPunctuation == .spoken {
            DiagnosticLogger.shared.log(
                "Punctuation: Spoken Only on Parakeet behaves as Automatic & Spoken "
                + "(Parakeet cannot suppress its own auto-punctuation); stored mode left unchanged.")
        }

        // Configure model persistence
        transcriber.keepModelLoaded = config.keepModelLoaded ?? "auto"
        transcriber.startMemoryPressureMonitoring()
        if needsNewEngine { warmUpEngine(effectiveEngineID) }

        reloadHotkeyAndSettings()
        print("Config reloaded: hotkey=\(KeyCodes.describe(keyCode: config.hotkey.keyCode, modifiers: config.hotkey.modifiers)) model=\(modelID) engine=\(effectiveEngineID)")
    }

    private func wireSecondOpinionStatus(for transcriber: Transcriber) {
        transcriber.onSecondOpinionStatus = { [weak self] status in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch status {
                case .rechecking:
                    self.recordingOverlay.updateStreamingText(status.message)
                case .failed:
                    self.recordingOverlay.lingerWithMessageThenHide(status.message)
                }
            }
        }
    }

    /// Warm up the Parakeet model in the background at launch / engine switch so the
    /// first dictation isn't a ~15-20s cold ANE load. Parakeet only (Whisper's cold
    /// load is fast and its memory profile differs); no-ops if assets aren't present.
    private func warmUpEngine(_ engineID: String) {
        guard let t = transcriber else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.transcriber === t else { return }
            self.statusBar.modelIsLoading = engineID == "parakeet" && !t.isLoaded
        }
        guard engineID == "parakeet" else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let start = Date()
            await t.warmUp()
            let loaded = t.isLoaded
            DiagnosticLogger.shared.log("Parakeet warm-up \(loaded ? "ready" : "failed") after \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.transcriber === t else { return }
                self.statusBar.modelIsLoading = false
                if !loaded { self.statusBar.modelLoadMessage = "Initial model load failed — dictation will retry" }
            }
        }
    }

    // MARK: - Graceful termination (2026-07-14)

    /// SIGTERM (pkill, reinstall scripts, logout) waits for an in-flight dictation to
    /// finish — and for 10 s of quiet after it — before exiting, instead of cutting the
    /// user off mid-sentence. SIGKILL is unaffected (nothing can be).
    func installGracefulTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { NSApp.terminate(nil); return }
            let busy = self.statusBar.state == .recording || self.statusBar.state == .transcribing
            if !busy {
                NSApp.terminate(nil)
                return
            }
            DiagnosticLogger.shared.log("SIGTERM: dictation in flight — waiting to exit")
            // Refuse NEW recordings while draining: a dictation started after SIGTERM
            // races the exit and its audio dies in memory (2026-07-25: recording began
            // 2s after the prior one finished, deploy force-killed it mid-capture, wav
            // on disk had 0 samples). Finishing the in-flight one, then going dark for
            // ~10s until the new instance arrives, is strictly better than eating audio.
            self.isTerminating = true
            self.terminateAfterQuiet(consecutiveIdle: 0,
                                     deadline: Date().addingTimeInterval(5 * 60))
        }
        source.resume()
        sigtermSource = source
    }

    /// Poll every 0.5 s; require 10 s of continuous idle (no recording/transcribing)
    /// before terminating. Hard deadline so a stuck state can't make the app unkillable.
    private func terminateAfterQuiet(consecutiveIdle: Int, deadline: Date) {
        let busy = statusBar.state == .recording || statusBar.state == .transcribing
        let idleCount = busy ? 0 : consecutiveIdle + 1
        if idleCount >= 20 || Date() > deadline {
            DiagnosticLogger.shared.log("SIGTERM: quiet — exiting now")
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.terminateAfterQuiet(consecutiveIdle: idleCount, deadline: deadline)
        }
    }

    /// Microphone pin plumbing for the menu-bar selector. `config` is nil until setup
    /// loads it, and StatusBarController builds its first menu BEFORE that (launch
    /// crash caught by the AX harness 2026-07-14) — both entry points must nil-tolerate.
    public func currentInputDeviceUID() -> String? { config?.inputDeviceUID }

    public func selectInputDevice(uid: String?) {
        var updated = Config.load()
        updated.inputDeviceUID = uid
        try? updated.save()
        config?.inputDeviceUID = uid
        recorder.setPinnedInputDevice(uid: uid)
        statusBar.buildMenu()
        // P2: this is an external writer of config.json. If Settings is open, its cached view
        // model now holds a stale inputDeviceUID and its next save would revert this pick — re-sync
        // it from disk. Only when visible: refreshing mid-edit would clobber the user's in-progress
        // changes (and reloadConfig must NOT drive this, to avoid refreshing during a Settings save).
        if SettingsWindowController.isWindowVisible {
            settingsViewModel?.refreshFromDisk()
        }
        DiagnosticLogger.shared.log("Microphone selector: \(uid ?? "system default")")
    }

    // MARK: - AirPods Dictation Mode (Michael 2026-08-21)

    /// The first connected Bluetooth input device, if any (AirPods-class).
    public func connectedBluetoothInput() -> AudioInputDevice? {
        AudioDeviceCatalog.cachedInputDevices.first { $0.isBluetooth }
    }

    /// Whether the current pin IS the connected Bluetooth mic (menu checkmark state).
    public func dictationModeActive() -> Bool {
        guard let bt = connectedBluetoothInput() else { return false }
        return config?.inputDeviceUID == nil || config?.inputDeviceUID == bt.uid
    }

    /// Toggle: ON pins the Bluetooth mic (remembering the previous pin for restore);
    /// OFF restores whatever was pinned before the mode engaged. A deliberate, labeled
    /// tradeoff — best mic quality in noise, output drops to call quality while on.
    public func toggleDictationMode() {
        guard let bt = connectedBluetoothInput() else { return }
        var updated = Config.load()
        if dictationModeActive() {
            let restore = updated.preDictationModeInputUID
                ?? AudioDeviceCatalog.cachedBuiltInInput?.uid
                ?? AudioDeviceCatalog.cachedInputDevices.first(where: { !$0.isBluetooth && !$0.isVirtual })?.uid
            guard let restore else { return } // No alternative mic to switch to.
            updated.preDictationModeInputUID = nil
            try? updated.save()
            config?.preDictationModeInputUID = nil
            DiagnosticLogger.shared.log("Dictation Mode: OFF — restoring input \(restore)")
            selectInputDevice(uid: restore)
        } else {
            updated.preDictationModeInputUID = updated.inputDeviceUID
            try? updated.save()
            config?.preDictationModeInputUID = config?.inputDeviceUID
            DiagnosticLogger.shared.log("Dictation Mode: ON — pinning \(bt.name)")
            selectInputDevice(uid: bt.uid)
        }
    }

    /// Reload hotkey, pre-buffer, and menu without changing the transcriber/model.
    private func reloadHotkeyAndSettings() {
        // Routing must be settled before pre-buffer can start an absent engine.
        recorder.setPinnedInputDevice(uid: config.inputDeviceUID)
        recorder.preBufferEnabled = config.preBuffer?.value ?? true

        // Update spoken punctuation on existing transcriber
        transcriber?.suppressAutoPunctuation = (config.spokenPunctuation == .spoken)

        // L1: rebuilding the HotkeyManager tears down and recreates the event tap, which would
        // lose an in-flight press's key-release. That deferral now lives at the TOP of reloadConfig
        // (the whole reload is deferred while fn is held), so this method is only ever reached when
        // fn is NOT held — the rebuild is always safe here.
        rebuildHotkeyManager()

        statusBar.buildMenu()

        syncLocalAPIServerState()
    }

    /// Tear down and recreate the HotkeyManager from the current config. Split out of
    /// reloadHotkeyAndSettings (P1) so it can be deferred past an in-flight dictation.
    private func rebuildHotkeyManager() {
        hotkeyManager?.stop()
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkey.keyCode,
            modifiers: config.hotkey.modifierFlags
        )
        hotkeyManager?.start(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() },
            onAbort: { [weak self] in self?.handleRecordingAbort() },
            onUserInteraction: { [weak self] interaction in
                self?.onMainActor { self?.session?.noteUserInteraction(interaction) }
            }
        )
    }

    /// L1: apply a config reload that was deferred because a dictation was in flight when
    /// reloadConfig was called. Called from every path that ends a dictation (the session's
    /// `captureEnded` and `cancelled`, and handleKeyUp); the guard-then-clear makes it fire once
    /// and is idempotent, so overlapping end paths don't double-reload. reloadConfig reloads fresh
    /// Config.load() state from disk. Key-up alone does not end the take: a pending post-buffer
    /// keeps the reload deferred until finalize relinquishes the capture boundary.
    private func performPendingConfigReloadIfNeeded() {
        guard pendingConfigReload, !(session?.isTrailing ?? false) else { return }
        pendingConfigReload = false
        DiagnosticLogger.shared.log("Config: applying deferred reload — dictation finished")
        reloadConfig()
    }

    /// Start or stop the LocalAPIServer based on the current config.
    /// Called from both `reloadHotkeyAndSettings` (settings-save path) and
    /// `startListening` (launch path) so the server comes up on launch when enabled.
    private func syncLocalAPIServerState() {
        let apiEnabled = config.localAPI?.value ?? false
        let apiPort = UInt16(config.localAPIPort ?? 5765)
        if apiEnabled, let t = transcriber {
            if localAPIServer == nil || localAPIServer?.port != apiPort {
                localAPIServer?.stop()
                localAPIServer = LocalAPIServer(port: apiPort)
            }
            localAPIServer?.start(transcriber: t,
                                  allowBrowser: config.localAPIAllowBrowser?.value ?? false,
                                  authToken: config.localAPIToken,
                                  allowControl: config.localAPIAllowControl?.value ?? false,
                                  control: dictationControl)
        } else {
            localAPIServer?.stop()
            localAPIServer = nil
        }
    }

    private func showTutorialPopoverIfNeeded() {
        let key = "speakfree.hasShownTutorial"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard let button = statusBar?.statusItem.button else { return }

        let vc = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 58))
        let label = NSTextField(wrappingLabelWithString:
            "Click here to access settings, updates, or quit SpeakFree.")
        label.font = NSFont.systemFont(ofSize: 13)
        label.isEditable = false; label.isBordered = false; label.backgroundColor = .clear
        label.frame = NSRect(x: 12, y: 9, width: 266, height: 40)
        view.addSubview(label)
        vc.view = view

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 290, height: 58)
        popover.behavior = .transient
        tutorialPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.tutorialPopover?.close()
            self?.tutorialPopover = nil
        }
    }

    public func showSettings() {
        if settingsViewModel == nil {
            settingsViewModel = SettingsViewModel()
            settingsViewModel?.onSave = { [weak self] in
                self?.reloadConfig()
            }
        }
        SettingsWindowController.show(viewModel: settingsViewModel!)
    }

    /// Present the recordings notice. Main-only. A dismissal without a
    /// keep/delete decision re-arms it a few hours out; a decision (persisted by the
    /// controller) reloads config so the dialog's toggle takes effect immediately.
    private func showRecordingsNotice() {
        guard recordingsNoticeController == nil else { return }
        recordingsNoticeController = RecordingsNoticeController.present(
            onResolved: { [weak self] in
                self?.recordingsNoticeTimer?.invalidate()
                self?.recordingsNoticeTimer = nil
                self?.recordingsNoticeController = nil
                self?.reloadConfig()
                // P2: external writer of saveRecordings/recordingsNoticeDecision. Re-sync an open
                // Settings view model from disk so its next save can't resurrect the stale value.
                if SettingsWindowController.isWindowVisible {
                    self?.settingsViewModel?.refreshFromDisk()
                }
            },
            onConfigChanged: { [weak self] in
                self?.reloadConfig()
                // P2: same external-writer re-sync as onResolved (window-visible only).
                if SettingsWindowController.isWindowVisible {
                    self?.settingsViewModel?.refreshFromDisk()
                }
            },
            onDismissed: { [weak self] in
                guard let self else { return }
                self.recordingsNoticeController = nil
                self.recordingsNoticeTimer?.invalidate()
                self.recordingsNoticeTimer = Timer.scheduledTimer(
                    withTimeInterval: RecordingsNotice.reshowInterval, repeats: false
                ) { [weak self] _ in
                    self?.showRecordingsNotice()
                }
            }
        )
    }

    private func handleKeyDown() {
        guard isReady, !isTerminating, let session else { return }
        let isPressed = session.isRecording

        // Resolve Key Mode through the one shared property (KeyMode.swift), never a site-local
        // `config.toggleMode?.value ?? false` — that is exactly the drift `effectiveKeyMode` and
        // `effectivePunctuationMode` exist to prevent.
        switch config.effectiveKeyMode {
        case .hold:
            guard !isPressed else { return }
            handleRecordingStart()
        case .toggle:
            if isPressed {
                handleRecordingStop()
            } else {
                handleRecordingStart()
            }
        case .edit:
            // Phase 2 owns the EditSessionController: the window, the fn-tap reducer routing
            // (EditKeyReducer), and the finalize-destination target. Until it is wired, route the
            // tap through the same toggle semantics so a manually-set keyMode:"edit" config still
            // dictates rather than bricking the hotkey. The FinalizeDestination seam keeps edit
            // finalization off the direct-insert path only once a target is captured (nil today).
            if let router = editHotkeyRouter {
                router()
            } else if isPressed {
                handleRecordingStop()
            } else {
                handleRecordingStart()
            }
        }
    }

    private func handleKeyUp() {
        // Toggle and Edit are tap-driven: the key-up is ignored (the tap already started/stopped in
        // handleKeyDown). Only Hold stops on release.
        switch config.effectiveKeyMode {
        case .toggle, .edit:
            return
        case .hold:
            handleRecordingStop()
            // The post-buffer is still part of this take. A deferred reload waits for actual
            // finalization so a re-press can continue with the same engine, route, and key mode.
            performPendingConfigReloadIfNeeded()
        }
    }

    private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "speakfree needs Accessibility access to type your dictation.\n\nClick \"Open Settings\" below, then find speakfree in the list and turn it on. Come back here when done — it will start automatically."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "I'll Do It Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    // MARK: - Dictation session

    /// Run `body` on the main actor, which owns the session: inline when already on main (every
    /// hotkey, menu and local API path), queued otherwise (setup assigns the transcriber and
    /// config off main, before listening starts).
    private func onMainActor(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    private func makeSession() {
        onMainActor { [self] in
            let session = DictationSession(recorder: recorder, inserter: inserter)
            // The control center observes first, so an API caller hears about a finished or
            // failed take before this app presents anything modal.
            dictationControl.attach(to: session)
            session.addObserver { [weak self] _, event in self?.present(event) }
            session.transcriber = transcriber
            if let config { session.configuration = DictationConfiguration(config: config) }
            session.engineID = activeEngineID
            self.session = session
            updateSessionAvailability()
        }
    }

    private func updateSessionAvailability() {
        let enabled = isReady && !isTerminating
        onMainActor { [weak self] in self?.session?.isEnabled = enabled }
    }

    func handleRecordingStart() {
        onMainActor { [weak self] in self?.session?.start(destination: .cursor) }
    }

    func handleRecordingStop() {
        onMainActor { [weak self] in self?.session?.stopRecording() }
    }

    /// A real key was pressed while fn was held — this is a keyboard shortcut, not dictation.
    /// Cancel the press silently and let the shortcut pass through (see `abortPress`).
    func handleRecordingAbort() {
        onMainActor { [weak self] in _ = self?.session?.abortPress() }
    }

    func resetRecordingUIAfterAbort() {
        statusBar.state = .idle
        recordingOverlay.hide()
        statusBar.buildMenu()
    }

    /// Test-only bridge — exercises the failure-presentation path without a live
    /// DictationSession. Not called by production code.
    func presentFailureForTesting(_ failure: DictationFailure) {
        presentFailure(failure)
    }

    /// Present one session event: menu-bar state, the recording overlay, alerts.
    private func present(_ event: DictationEvent) {
        switch event {
        case .preparing:
            // A stale Secure-Input retry must never fire mid-take or after a newer dictation —
            // starting a new recording supersedes the parked text.
            cancelSecureInputRetry()
            // Verify all subsystems before every recording
            verifySubsystems(context: "pre-recording")
        case .starting:
            statusBar.state = .recording
            recordingOverlay.style = min(5, max(1, config.overlayStyle ?? 5))
            recordingOverlay.placement = config.effectiveOverlayPlacement
            recordingOverlay.show(state: .recording, recorder: recorder)
        case .partialText(let text):
            recordingOverlay.updateStreamingText(text)
        case .partialTextCleared:
            recordingOverlay.clearStreamingText()
        case .audioStalled:
            recordingOverlay.show(
                state: .error("Mic went silent: audio is not being captured"),
                autoHideError: false)
        case .audioRecovered:
            recordingOverlay.show(state: .recording, recorder: recorder)
        case .captureEnded:
            // L1: the take's capture is over. Applying a deferred FULL reload here — before the
            // session snapshots the transcriber and configuration — means no finalize path leaves
            // it stranded, and it is the un-defer point for toggle mode (where handleKeyUp
            // returned early). The whole finalization then runs on ONE engine.
            performPendingConfigReloadIfNeeded()
        case .transcribing:
            statusBar.state = .transcribing
            recordingOverlay.update(state: .transcribing)
        case .modelLoading:
            recordingOverlay.updateStreamingText("Loading speech model…")
        case .delivering:
            recordingOverlay.hide()
        case .deliveryFallback(let fallback):
            presentDeliveryFallback(fallback)
        case .finished(let result):
            presentFinished(result)
        case .failed(let failure):
            presentFailure(failure)
        case .cancelled:
            resetRecordingUIAfterAbort()
            // L1: the dictation ended (aborted) — apply any config reload deferred while fn was held.
            performPendingConfigReloadIfNeeded()
        case .recording, .resumed, .released, .retargeted, .inputLevel:
            break
        }
    }

    private func presentFinished(_ result: DictationResult) {
        switch result.delivery {
        case .editSession:
            // The edit session owns the segment; nothing was typed or shown.
            statusBar.state = .idle
        case .returnedToCaller:
            if result.recordingKept {
                statusBar.noteFinishedRecording(url: result.audioURL, text: result.styled)
            }
            statusBar.state = .idle
        case .inserted, .copiedToClipboard:
            if result.recordingKept {
                statusBar.noteFinishedRecording(url: result.audioURL, text: result.styled)
            }
            lastTranscription = result.styled
            UsageStats.shared.recordDictation(
                characters: result.styled.count, audioSeconds: result.audioDuration)
            if result.delivery == .inserted {
                statusBar.state = .idle
                statusBar.buildMenu()
            }
        case .nothingToInsert:
            if result.recordingKept {
                statusBar.noteFinishedRecording(url: result.audioURL, text: result.styled)
            }
            showTransientState(.noSpeech, for: 4)
        }
    }

    private func presentDeliveryFallback(_ fallback: DictationDeliveryFallback) {
        switch fallback {
        case .mayHaveCommitted:
            // The AX write MAY have landed — never prompt a paste or auto-retry
            // here, both risk a duplicate. Checkmark only.
            statusBar.state = .secureInputCopied
            statusBar.buildMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.statusBar.state = .idle
                self.statusBar.buildMenu()
            }
        case .secureInput(let text):
            // Definitely NOT inserted: show the retry dialog (Michael 2026-08-12)
            // and auto-insert the moment Secure Input clears.
            statusBar.state = .secureInputCopied
            statusBar.buildMenu()
            beginSecureInputRetry(text: text)
        case .focusLost:
            if statusBar.state != .secureInputCopied {
                statusBar.state = .copiedToClipboard
                statusBar.buildMenu()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
        }
    }

    private func presentFailure(_ failure: DictationFailure) {
        switch failure {
        case .recordingFailed:
            statusBar.state = .idle
            // LOUD failure (2026-07-25): the overlay used to flash for one frame and
            // hide — the user pressed the key, spoke, and got nothing. Now a red
            // center-screen banner says so (auto-hides).
            recordingOverlay.show(state: .error("Recording failed: check your microphone"))
        case .captureFailed:
            statusBar.state = .captureFailed
            statusBar.buildMenu()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.statusBar.state == .captureFailed {
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
            recordingOverlay.show(state: .error("Capture failed: please try again"))
            showCaptureFailureAlert()
        case .silent:
            // The user held the key and spoke into a dead mic — say so (F12:
            // gate failures were a silent no-op; the empty-transcript fix
            // didn't cover this path).
            showTransientState(.noSpeech, for: 4)
            recordingOverlay.show(state: .error("No speech captured: check your mic"))
        case .noAudio, .tooShort, .engineNotReady:
            statusBar.state = .idle
            recordingOverlay.hide()
        case .modelMissing:
            recordingOverlay.hide()
            let message = "Parakeet model not downloaded — open Settings to download."
            print("Error: \(message)")
            DiagnosticLogger.shared.log(message)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Model Not Downloaded"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                showSettings()
            }
            statusBar.state = .idle
            statusBar.buildMenu()
        case .transcriptionFailed(let reason, let recordingKept):
            recordingOverlay.hide()
            // Throttle the modal: a persistently broken engine fails EVERY
            // dictation, and one focus-stealing alert per attempt is hostile.
            // The session logs every failure regardless.
            let now = Date()
            if lastTranscriptionFailureAlert.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                lastTranscriptionFailureAlert = now
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Transcription Failed"
                let recordingNote = recordingKept
                    ? "Your recording was kept and can be transcribed from the recordings folder."
                    : "The recording was discarded (saving recordings is off)."
                alert.informativeText = "The engine reported an error. \(recordingNote)"
                    + "\n\n\(reason)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            statusBar.state = .idle
            statusBar.buildMenu()
        case .notReady, .busy, .microphoneUnavailable, .notRecording, .cancelled:
            break
        }
    }

    /// Show `state` in the menu bar, returning to idle after `seconds` unless something else
    /// changed it meanwhile.
    private func showTransientState(_ state: StatusBarController.State, for seconds: TimeInterval) {
        statusBar.state = state
        statusBar.buildMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.statusBar.state == state {
                self.statusBar.state = .idle
                self.statusBar.buildMenu()
            }
        }
    }

    // MARK: - Secure-Input retry dialog (Michael 2026-08-12)
    //
    // "A little box that says secure input activated, hit Command V to paste your
    // dictation … keeps retrying, and if it gets it, it shuts down the box."
    // The dialog reuses the center-screen overlay banner; the retry polls every 0.5s and
    // lives exactly as long as the concealed clipboard hold (secureInputClipboardClearDelay),
    // so the box never promises a paste the clipboard can no longer deliver.

    private var secureInputRetryTimer: Timer?

    private func beginSecureInputRetry(text: String) {
        cancelSecureInputRetry()
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let generalPasteboard = NSPasteboard.general
        let heldChangeCount = generalPasteboard.changeCount
        let deadline = Date().addingTimeInterval(inserter.secureInputClipboardClearDelay)
        let holder = TextInserter.secureInputHolderName()
        let blocker = holder.map { " (\($0))" } ?? ""
        recordingOverlay.show(
            state: .error("Secure Input\(blocker) blocked dictation — press ⌘V to paste"),
            autoHideError: false)
        DiagnosticLogger.shared.log(
            "SecureInputRetry: dialog shown, holder=\(holder ?? "unknown"), retrying for "
            + "\(Int(inserter.secureInputClipboardClearDelay))s")
        secureInputRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let action = TextInserter.secureInputRetryAction(
                secureInputActive: self.inserter.isSecureInputActive(),
                clipboardMoved: generalPasteboard.changeCount != heldChangeCount,
                frontmostMatchesTarget:
                    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetBundleID,
                deadlinePassed: Date() >= deadline)
            switch action {
            case .wait:
                break
            case .dismiss:
                DiagnosticLogger.shared.log(
                    "SecureInputRetry: dismissed without auto-insert (clipboard moved or hold expired)")
                self.cancelSecureInputRetry()
            case .insert:
                self.cancelSecureInputRetry()
                DiagnosticLogger.shared.log("SecureInputRetry: Secure Input cleared — auto-inserting")
                self.inserter.insert(text: text)
                self.statusBar.state = .idle
                self.statusBar.buildMenu()
            }
        }
    }

    private func cancelSecureInputRetry() {
        guard secureInputRetryTimer != nil else { return }
        secureInputRetryTimer?.invalidate()
        secureInputRetryTimer = nil
        recordingOverlay.hide()
        if statusBar.state == .secureInputCopied {
            statusBar.state = .idle
            statusBar.buildMenu()
        }
    }

    /// Shows a blocking NSAlert describing the capture failure.
    /// Separated from `showCaptureFailureAlert` so it can be replaced by a seam in
    /// tests (mirrors `_alertPresenter` for setup failures).
    var _captureFailureAlertPresenter: (() -> Void)?

    private func showCaptureFailureAlert() {
        let now = Date()
        guard lastTranscriptionFailureAlert.map({ now.timeIntervalSince($0) > 300 }) ?? true else {
            return
        }
        lastTranscriptionFailureAlert = now
        if let presenter = _captureFailureAlertPresenter {
            presenter()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Capture Failed"
        alert.informativeText = "No audio reached the recorder. Please try again. "
            + "If this repeats, check that the selected microphone is connected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Background auto-recovery: transcribe each orphan serially, but only START one
    /// while the app is idle — the engines serialize inference, so a recovery chunk in
    /// flight would queue a live dictation behind it. Busy → poll again in 30s.
    private func autoRecoverOrphans(_ urls: [URL]) {
        var queue = urls
        func next() {
            guard let url = queue.first else { return }
            let busy = (session?.isRecording ?? false) || statusBar.state == .recording || statusBar.state == .transcribing
            if busy {
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { next() }
                return
            }
            queue.removeFirst()
            guard let transcriber = self.transcriber else { return }
            guard let activityLease = try? RecordingActivity.shared.acquireReading(url) else {
                DiagnosticLogger.shared.log("Recovery: skipped a recording currently claimed by maintenance")
                DispatchQueue.main.async { next() }
                return
            }
            Task.detached(priority: .utility) { [weak self, activityLease] in
                defer { activityLease.release() }
                do {
                    let text = try await transcriber.transcribeFile(
                        url: url, progressHandler: { _, _, _ in }, isCancelled: { false })
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    RecordingStore.saveTranscription(text: trimmed, for: url)
                    DiagnosticLogger.shared.log(
                        "Recovery: auto-transcribed \(url.lastPathComponent) (\(trimmed.count) chars)"
                        + (trimmed.isEmpty ? " — silent/room tone" : " — in Recent Dictations"))
                } catch {
                    DiagnosticLogger.shared.log(
                        "Recovery: auto-transcribe FAILED for \(url.lastPathComponent): \(error.localizedDescription) — will retry next launch")
                }
                await MainActor.run { [weak self] in
                    guard self != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { next() }
                }
            }
        }
        DispatchQueue.main.async { next() }
    }

    /// MANUAL crash recovery (2026-07-25): transcribe the orphaned wav through the chunked
    /// file path (no 30-min cap), save the transcript sidecar (so the orphan leaves the
    /// sweep and appears in Recent Dictations), and copy the text to the clipboard.
    /// Superseded by autoRecoverOrphans for the launch path; kept for explicit invocations.
    public func recoverOrphan(audioURL: URL) {
        guard statusBar.state == .idle || statusBar.state == .ready else {
            // Busy (recording/transcribing). The menu entry persists — retry later.
            DiagnosticLogger.shared.log("Recovery: busy (\(statusBar.state)) — try again when idle")
            return
        }
        guard let transcriber = transcriber else {
            DiagnosticLogger.shared.log("Recovery: no transcriber loaded — cannot recover")
            return
        }
        let activityLease: RecordingActivity.Lease
        do { activityLease = try RecordingActivity.shared.acquireReading(audioURL) }
        catch {
            DiagnosticLogger.shared.log("Recovery: recording is currently claimed by maintenance")
            recordingOverlay.show(state: .error(error.localizedDescription))
            return
        }
        statusBar.state = .transcribing
        statusBar.buildMenu()
        Task.detached { [weak self, activityLease] in
            defer { activityLease.release() }
            do {
                let text = try await transcriber.transcribeFile(
                    url: audioURL, progressHandler: { _, _, _ in }, isCancelled: { false })
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    guard let self = self else { return }
                    // A dictation may have started during a long recovery (review #7):
                    // only touch shared UI state and the clipboard if the status is
                    // still OUR .transcribing; the transcript sidecar is saved either
                    // way and reachable via Recent Dictations.
                    let stillOurs = self.statusBar.state == .transcribing
                    if trimmed.isEmpty {
                        DiagnosticLogger.shared.log(
                            "Recovery: \(audioURL.lastPathComponent) transcribed EMPTY (silent capture)")
                        // Sidecar the emptiness too, so the sweep stops re-offering it.
                        RecordingStore.saveTranscription(text: "", for: audioURL)
                        self.statusBar.clearCrashRecovery()
                        guard stillOurs else { return }
                        self.statusBar.state = .noSpeech
                        self.statusBar.buildMenu()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if self.statusBar.state == .noSpeech {
                                self.statusBar.state = .idle
                                self.statusBar.buildMenu()
                            }
                        }
                        return
                    }
                    RecordingStore.saveTranscription(text: trimmed, for: audioURL)
                    self.statusBar.clearCrashRecovery()
                    guard stillOurs else {
                        DiagnosticLogger.shared.log(
                            "Recovery: transcribed \(audioURL.lastPathComponent) (\(trimmed.count) chars) while a dictation was active; text is in Recent Dictations")
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(trimmed, forType: .string)
                    self.lastTranscription = trimmed
                    DiagnosticLogger.shared.log(
                        "Recovery: transcribed \(audioURL.lastPathComponent) — \(trimmed.count) chars, copied to clipboard")
                    self.statusBar.state = .copiedToClipboard
                    self.statusBar.buildMenu()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.statusBar.state == .copiedToClipboard {
                            self.statusBar.state = .idle
                            self.statusBar.buildMenu()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    DiagnosticLogger.shared.log(
                        "Recovery FAILED for \(audioURL.lastPathComponent): \(error.localizedDescription)")
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
        }
    }

    public func reprocess(audioURL: URL) {
        // `.ready` is the state before the first dictation of a session, so gating on `.idle`
        // alone made every Recent Dictations click a silent no-op until you had dictated once
        // (2026-08-01). Both states mean "not busy"; the busy ones below are the real exclusion.
        guard statusBar.state == .idle || statusBar.state == .ready else {
            DiagnosticLogger.shared.log(
                "Reprocess: ignored — status bar is \(statusBar.state), not idle/ready")
            return
        }

        // Read saved transcription text — no need to re-transcribe
        guard let activityLease = try? RecordingActivity.shared.acquireReading(audioURL) else {
            recordingOverlay.show(state: .error("This recording is being moved. Please try again afterward."))
            return
        }
        defer { activityLease.release() }
        let textURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        guard let text = try? String(contentsOf: textURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Reprocess: no saved transcription for \(audioURL.lastPathComponent)")
            return
        }

        lastTranscription = text

        // Insert into the frontmost window (Michael, 2026-07-25 — was clipboard-only).
        // The status-bar menu has just closed; give macOS a beat to return key focus
        // to the user's app before the AX read / synthetic paste, or the insert
        // targets the dying menu session. Clipboard remains the fallback whenever
        // insertion can't land (no focused element, focus lost, secure input).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            let copyFallback = {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.statusBar.state = .copiedToClipboard
                self.statusBar.buildMenu()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.statusBar.state = .idle
                    self.statusBar.buildMenu()
                }
            }
            let inserted = self.inserter.insert(text: text, onFocusLost: copyFallback)
            if inserted {
                DiagnosticLogger.shared.log(
                    "Reprocess: inserted \(text.count) chars from recent dictation")
            } else if self.statusBar.state != .copiedToClipboard {
                copyFallback()
            }
        }
    }

    /// Find the LARGEST downloaded whisper model on disk, returning the model size
    /// string (e.g. "base.en"). Largest-by-file-size, never directory order — used
    /// only as an availability check; model selection itself never silently
    /// substitutes (see the no-silent-fallback rule in setupInner).
    private func findAnyDownloadedModel() -> String? {
        let modelsDir = Config.configDir.appendingPathComponent("models")
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(atPath: modelsDir.path))?
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .max(by: { a, b in
                let sizeA = (try? fm.attributesOfItem(atPath: modelsDir.appendingPathComponent(a).path))?[.size] as? Int ?? 0
                let sizeB = (try? fm.attributesOfItem(atPath: modelsDir.appendingPathComponent(b).path))?[.size] as? Int ?? 0
                return sizeA < sizeB
            })
            .map { String($0.dropFirst(5).dropLast(4)) }  // "ggml-base.en.bin" → "base.en"
    }
}
