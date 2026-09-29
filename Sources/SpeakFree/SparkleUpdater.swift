import Sparkle
import SpeakFreeLib

/// The app's `AppUpdater`: Sparkle lives in the executable so SpeakFreeLib never links it.
final class SparkleUpdater: AppUpdater {
    // Sparkle auto-updater — checks for updates on launch and periodically.
    // Constructed lazily and STARTED only from setupInner (the production launch
    // path), never at AppDelegate construction: with `startingUpdater: true` the
    // updater came alive inside xctest whenever a test built an AppDelegate, and
    // Sparkle's scheduled update-check prompts/errors are real modal NSAlerts on
    // the main queue — any test that then spins the run loop deadlocks forever.
    // That was the whole-suite stall found by the 2026-07-01 audit (and it is
    // time/defaults-dependent, which is why the suite was green on 06-10 and hung
    // on 07-01 with no code change). Tests route setup through _setupExecutor and
    // never reach setupInner, so the updater now stays dormant under test.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    func start() {
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
