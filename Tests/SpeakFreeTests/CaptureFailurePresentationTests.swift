// T: capture-failure presentation must not clear its own timed state
//
// `AppDelegate.presentFailure(.captureFailed)` puts the status bar into the timed
// `.captureFailed` state (a 4s auto-reset) and shows a red overlay banner, then shows
// a blocking alert. The alert used to be followed by an unconditional
// `statusBar.state = .idle; recordingOverlay.hide()`, which meant the timed failure
// state and banner were only ever visible while the alert itself was open — they were
// wiped the instant the alert closed, regardless of the 4s design.

import XCTest
@testable import SpeakFreeLib

final class CaptureFailurePresentationTests: XCTestCase {

    /// Build a minimal AppDelegate with the headless seams wired up so the capture
    /// failure path can run without a live DictationSession or a visible NSAlert.
    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.statusBar = StatusBarController()
        delegate._captureFailureAlertPresenter = { /* no-op: skip the blocking NSAlert */ }
        return delegate
    }

    /// After the capture-failure alert is dismissed, the status bar must still be in
    /// its timed `.captureFailed` state — not forced back to `.idle` — so the
    /// existing 4s auto-reset runs as designed instead of being pre-empted.
    func test_captureFailed_leavesTimedStatusAfterAlertDismissed() {
        let delegate = makeDelegate()

        delegate.presentFailureForTesting(.captureFailed)

        XCTAssertEqual(
            delegate.statusBar.state, .captureFailed,
            "status bar must remain .captureFailed once the alert is dismissed, " +
            "so its own 4s timer (not the alert callback) governs the reset")
    }
}
