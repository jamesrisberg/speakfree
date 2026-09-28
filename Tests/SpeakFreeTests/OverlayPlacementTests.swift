// Unit tests for the recording indicator's placement (config `overlayPosition`).
//
// Everything under test is pure: OverlayPlacement parsing/decoding, the anchor each
// placement resolves to, and OverlayLayout's frame math against hand-built screen
// geometry (no NSScreen, no display attached).

import XCTest
@testable import SpeakFreeLib

final class OverlayPlacementTests: XCTestCase {

    // A 1512×982 MacBook Pro 14" screen: 37pt menu bar / camera housing, Dock at the bottom.
    private let notchScreen = OverlayScreenGeometry(
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: NSRect(x: 0, y: 80, width: 1512, height: 982 - 80 - 37),
        notchInset: 37, notchWidth: 180)

    // An external 1920×1080 display: 25pt menu bar, no notch, Dock at the bottom.
    private let plainScreen = OverlayScreenGeometry(
        frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 0, y: 70, width: 1920, height: 1080 - 70 - 25))

    private let pill = NSSize(width: 125, height: 38)

    // MARK: - Config decoding

    func testConfigDecodesEachPlacement() throws {
        for placement in OverlayPlacement.allCases {
            let json = """
            {"hotkey": {"keyCode": 63, "modifiers": []}, "modelSize": "base.en", "language": "en",
             "overlayPosition": "\(placement.rawValue)"}
            """.data(using: .utf8)!
            let config = try Config.decode(from: json)
            XCTAssertEqual(config.overlayPosition, placement)
            XCTAssertEqual(config.effectiveOverlayPlacement, placement)
        }
    }

    func testMissingPlacementResolvesToCenter() throws {
        let json = """
        {"hotkey": {"keyCode": 63, "modifiers": []}, "modelSize": "base.en", "language": "en"}
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        XCTAssertNil(config.overlayPosition)
        XCTAssertEqual(config.effectiveOverlayPlacement, .center)
    }

    /// A bad value must not make the whole config unparseable — Config.load() would
    /// reset every other setting to defaults.
    func testUnknownPlacementDecodesLeniently() throws {
        let json = """
        {"hotkey": {"keyCode": 63, "modifiers": []}, "modelSize": "base.en", "language": "en",
         "overlayPosition": "sideways"}
        """.data(using: .utf8)!
        let config = try Config.decode(from: json)
        XCTAssertEqual(config.effectiveOverlayPlacement, .center)
        XCTAssertEqual(config.modelSize, "base.en")

        let wrongType = """
        {"hotkey": {"keyCode": 63, "modifiers": []}, "modelSize": "base.en", "language": "en",
         "overlayPosition": 3}
        """.data(using: .utf8)!
        XCTAssertEqual(try Config.decode(from: wrongType).effectiveOverlayPlacement, .center)
    }

    func testPlacementRoundTripsThroughEncoder() throws {
        var config = Config.defaultConfig
        config.overlayPosition = .notch
        let data = try JSONEncoder().encode(config)
        let decoded = try Config.decode(from: data)
        XCTAssertEqual(decoded.overlayPosition, .notch)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"overlayPosition\""))
        XCTAssertTrue(text.contains("\"notch\""))
    }

    func testParseAcceptsAliasesAndCase() {
        XCTAssertEqual(OverlayPlacement.parse("Bottom"), .bottom)
        XCTAssertEqual(OverlayPlacement.parse(" top "), .notch)
        XCTAssertEqual(OverlayPlacement.parse("off"), .hidden)
        XCTAssertEqual(OverlayPlacement.parse("none"), .hidden)
        XCTAssertNil(OverlayPlacement.parse("elsewhere"))
    }

    func testSettingsViewModelRoundTripsPlacement() {
        var config = Config.defaultConfig
        config.overlayPosition = .bottom
        let vm = SettingsViewModel(config: config)
        XCTAssertEqual(vm.overlayPlacement, .bottom)
        vm.overlayPlacement = .hidden
        XCTAssertEqual(vm.toConfig().overlayPosition, .hidden)
    }

    // MARK: - Anchors

    func testCenterPlacementKeepsHistoricalAnchors() {
        XCTAssertEqual(OverlayPlacement.center.anchor(historical: .center), .center)
        XCTAssertEqual(OverlayPlacement.center.anchor(historical: .bottom), .bottom)
    }

    func testOtherPlacementsCollapseToOneAnchor() {
        for historical in [OverlayAnchor.center, .bottom, .top] {
            XCTAssertEqual(OverlayPlacement.bottom.anchor(historical: historical), .bottom)
            XCTAssertEqual(OverlayPlacement.notch.anchor(historical: historical), .top)
        }
    }

    func testHiddenShowsNoIndicatorButKeepsErrorAnchor() {
        XCTAssertFalse(OverlayPlacement.hidden.showsIndicator)
        XCTAssertTrue(OverlayPlacement.center.showsIndicator)
        XCTAssertEqual(OverlayPlacement.hidden.anchor(historical: .center), .center)
    }

    // MARK: - Frame math

    func testCenterFrameIsScreenCentered() {
        let f = OverlayLayout.frame(size: pill, anchor: .center, on: plainScreen)
        XCTAssertEqual(f.midX, 960, accuracy: 0.001)
        XCTAssertEqual(f.midY, 540, accuracy: 0.001)
        XCTAssertEqual(f.size, pill)
    }

    func testBottomFrameSitsAboveTheDock() {
        let f = OverlayLayout.frame(size: pill, anchor: .bottom, on: plainScreen)
        XCTAssertEqual(f.minY, 70 + OverlayLayout.bottomMargin)
        XCTAssertEqual(f.midX, 960, accuracy: 0.001)
    }

    func testTopFrameHangsFromTheNotch() {
        let f = OverlayLayout.frame(size: pill, anchor: .top, on: notchScreen)
        // Top edge flush with the bottom of the camera housing.
        XCTAssertEqual(f.maxY, 982 - 37)
        XCTAssertEqual(f.midX, 756, accuracy: 0.001)
    }

    func testTopFrameHangsFromTheMenuBarWithoutANotch() {
        let f = OverlayLayout.frame(size: pill, anchor: .top, on: plainScreen)
        XCTAssertEqual(f.maxY, plainScreen.visibleFrame.maxY)
        XCTAssertFalse(plainScreen.hasNotch)
    }

    func testTopFrameUsesScreenEdgeWhenMenuBarIsHidden() {
        // Full-screen app on a plain display: visibleFrame reaches the top edge.
        let fullscreen = OverlayScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        let f = OverlayLayout.frame(size: pill, anchor: .top, on: fullscreen)
        XCTAssertEqual(f.maxY, 1080)
    }

    func testFramesOnSecondaryScreenUseThatScreensOrigin() {
        let secondary = OverlayScreenGeometry(
            frame: NSRect(x: 1920, y: 200, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 1920, y: 200, width: 1920, height: 1055))
        let bottom = OverlayLayout.frame(size: pill, anchor: .bottom, on: secondary)
        XCTAssertEqual(bottom.minY, 200 + OverlayLayout.bottomMargin)
        XCTAssertEqual(bottom.midX, 1920 + 960, accuracy: 0.001)
        let top = OverlayLayout.frame(size: pill, anchor: .top, on: secondary)
        XCTAssertEqual(top.maxY, 200 + 1055)
    }

    // MARK: - Resizing in place

    func testResizeKeepsTheAnchoredEdge() {
        let current = NSRect(x: 100, y: 500, width: 340, height: 110)
        let smaller = NSSize(width: 240, height: 56)

        let centered = OverlayLayout.resized(current, to: smaller, anchor: .center)
        XCTAssertEqual(centered.midX, current.midX, accuracy: 0.001)
        XCTAssertEqual(centered.midY, current.midY, accuracy: 0.001)

        let bottom = OverlayLayout.resized(current, to: smaller, anchor: .bottom)
        XCTAssertEqual(bottom.minY, current.minY)
        XCTAssertEqual(bottom.midX, current.midX, accuracy: 0.001)

        let top = OverlayLayout.resized(current, to: smaller, anchor: .top)
        XCTAssertEqual(top.maxY, current.maxY)
        XCTAssertEqual(top.size, smaller)
    }

    // MARK: - Notch body

    func testNotchWindowIsNeverNarrowerThanTheHousing() {
        let padded = OverlayLayout.notchWindowSize(content: pill, on: notchScreen)
        XCTAssertEqual(padded.width, 180)
        XCTAssertEqual(padded.height, pill.height)

        let wide = NSSize(width: 400, height: 56)
        XCTAssertEqual(OverlayLayout.notchWindowSize(content: wide, on: notchScreen).width, 400)
        // No housing: the content size is used as-is.
        XCTAssertEqual(OverlayLayout.notchWindowSize(content: pill, on: plainScreen), pill)
    }

    func testNotchGeometryDetectsHousingFromAuxiliaryAreas() {
        XCTAssertTrue(notchScreen.hasNotch)
        XCTAssertEqual(notchScreen.topAnchorY, 982 - 37)
        // An inset without a measurable housing width is not treated as a notch.
        let insetOnly = OverlayScreenGeometry(frame: notchScreen.frame, visibleFrame: notchScreen.visibleFrame,
                                              notchInset: 37, notchWidth: nil)
        XCTAssertFalse(insetOnly.hasNotch)
        XCTAssertEqual(insetOnly.topAnchorY, insetOnly.visibleFrame.maxY)
    }

    func testNotchBodyTopCornersAreSquareOnlyWhenFlushWithTheHousing() {
        let bounds = NSRect(x: 0, y: 0, width: 180, height: 38)
        // Flush: the path's top edge spans the full width — its top-left corner is a real point.
        let flush = OverlayLayout.notchBodyPath(bounds: bounds, notchWidth: 180)
        XCTAssertTrue(flush.contains(CGPoint(x: 0.5, y: 37.5)))
        // Wider than the housing: the top corners are rounded, so that point is outside.
        let wide = OverlayLayout.notchBodyPath(bounds: NSRect(x: 0, y: 0, width: 400, height: 38), notchWidth: 180)
        XCTAssertFalse(wide.contains(CGPoint(x: 0.5, y: 37.5)))
        XCTAssertTrue(wide.contains(CGPoint(x: 200, y: 37.5)))
        // No housing at all: rounded too.
        let plain = OverlayLayout.notchBodyPath(bounds: bounds, notchWidth: nil)
        XCTAssertFalse(plain.contains(CGPoint(x: 0.5, y: 37.5)))
        // Bottom corners are always rounded.
        XCTAssertFalse(flush.contains(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertTrue(flush.contains(CGPoint(x: 90, y: 0.5)))
    }

    func testNotchErrorContentIsSizedToItsMessage() {
        let short = OverlayContentView.notchContentSize(for: .error("Mic failed"))
        let long = OverlayContentView.notchContentSize(for: .error("Recording failed: check your microphone and try again"))
        XCTAssertEqual(short.height, 44)
        XCTAssertLessThan(short.width, long.width)
        XCTAssertLessThanOrEqual(long.width, 480)
        // Non-error states share the pill's sizing.
        XCTAssertEqual(OverlayContentView.notchContentSize(for: .recording),
                       OverlayContentView.pillSize(for: .recording))
    }
}
