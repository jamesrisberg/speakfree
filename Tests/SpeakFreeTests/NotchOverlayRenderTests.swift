// Design-review harness for the notch placement (config overlayPosition: notch):
// renders the black housing body in each state to PNGs. Skips unless HUD_RENDER_DIR
// is set — an artifact generator, not an assertion suite, like HUDVariantRenderTests.
//
// Two housings are rendered: a 185pt-wide notch (MacBook Pro 14"/16") and none
// (external display), so the flush-top vs. rounded-top join can both be judged.

import XCTest
import AppKit
@testable import SpeakFreeLib

final class NotchOverlayRenderTests: XCTestCase {

    func test_renderNotchBodyForDesignReview() throws {
        guard let outDir = ProcessInfo.processInfo.environment["HUD_RENDER_DIR"] else {
            throw XCTSkip("HUD_RENDER_DIR not set — render harness only runs on demand")
        }
        let dir = "\(outDir)/notch"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let levels: [CGFloat] = [0.3, 0.55, 0.8, 0.45, 0.9, 0.65, 0.35, 0.7,
                                 0.85, 0.5, 0.6, 0.95, 0.4, 0.75, 0.55, 0.3]
        let preview = "the quick brown fox jumps over the lazy dog and keeps going for a second line"

        typealias Phase = (name: String, state: RecordingOverlay.OverlayState, text: String, speaking: Bool)
        let phases: [Phase] = [
            ("recording-silent", .recording, "", false),
            ("recording-speaking", .recording, "", true),
            ("recording-live-preview", .recording, preview, true),
            ("transcribing", .transcribing, "", false),
            ("status", .transcribing, "Rechecking with whisper\u{2026}", false),
            ("error", .error("Recording failed: check your microphone"), "", false),
        ]

        for housing in [("notch185", CGFloat(185) as CGFloat?), ("no-notch", nil)] {
            let screen = OverlayScreenGeometry(
                frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                visibleFrame: NSRect(x: 0, y: 80, width: 1512, height: 865),
                notchInset: housing.1 == nil ? 0 : 32, notchWidth: housing.1)
            for phase in phases {
                let content = OverlayContentView.notchContentSize(for: phase.state, streamingText: phase.text)
                let size = OverlayLayout.notchWindowSize(content: content, on: screen)
                let view = OverlayContentView(frame: NSRect(origin: .zero, size: size))
                view.isNotch = true
                view.notchWidth = screen.notchWidth
                view.overlayState = phase.state
                view.streamingText = phase.text
                view.tick = 13
                view.borderWidth = 1
                if phase.speaking { view.seedLevelsForRender(levels) }

                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    XCTFail("no bitmap rep for \(phase.name)"); continue
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("no png for \(phase.name)"); continue
                }
                try png.write(to: URL(fileURLWithPath: "\(dir)/\(housing.0)-\(phase.name).png"))
            }
        }
        print("Notch body rendered to \(dir)")
    }
}
