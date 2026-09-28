/// Checks for and installs app updates. SpeakFreeLib has no updater of its own: the
/// speakfree app injects its Sparkle updater, and hosts that embed dictation inject none,
/// so the library never links Sparkle.
public protocol AppUpdater: AnyObject {
    /// Begins scheduled update checks. Called once, on the main thread, from the app's
    /// launch path.
    func start()
    /// Runs a user-initiated update check.
    func checkForUpdates()
}
