// The status menu offers "Check for Updates..." only when an updater was injected, and the
// item runs that updater's check. SpeakFreeLib has no updater of its own (the speakfree app
// injects its Sparkle one), so a host that embeds the library gets no update item.

import AppKit
import XCTest
@testable import SpeakFreeLib

final class AppUpdaterMenuTests: XCTestCase {

    private final class FakeUpdater: AppUpdater {
        var starts = 0
        var checks = 0
        func start() { starts += 1 }
        func checkForUpdates() { checks += 1 }
    }

    private func updateItem(in statusBar: StatusBarController) -> NSMenuItem? {
        statusBar.statusItem.menu?.items.first { $0.title == "Check for Updates..." }
    }

    func test_noUpdater_menuHasNoUpdateItem() {
        let statusBar = StatusBarController()
        statusBar.buildMenu()
        XCTAssertNil(updateItem(in: statusBar))
    }

    func test_injectedUpdater_menuItemRunsItsCheck() throws {
        let statusBar = StatusBarController()
        let updater = FakeUpdater()
        statusBar.updater = updater

        let item = try XCTUnwrap(updateItem(in: statusBar))
        let target = try XCTUnwrap(item.target as? MenuItemTarget)
        target.invoke()

        XCTAssertEqual(updater.checks, 1)
        XCTAssertEqual(updater.starts, 0, "opening the menu must not start scheduled checks")
    }
}
