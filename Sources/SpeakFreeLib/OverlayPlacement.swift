import AppKit

// MARK: - OverlayPlacement

/// Where the recording indicator lives on screen (config key `overlayPosition`).
///
/// `.center` is the historical behaviour and the default: a large centered banner
/// that holds through transcription. The other placements keep every state of the
/// indicator (recording, transcribing, live preview, errors) but anchor it elsewhere:
///
///   * `.bottom` — the indicator sits just above the Dock, centered horizontally.
///   * `.notch`  — the indicator hangs from the camera housing on MacBooks that have
///                 one, drawn as a black extension of the notch. On screens without
///                 a notch it hangs from the menu bar instead.
///   * `.hidden` — no on-screen indicator at all. The menu-bar icon still reflects
///                 recording/transcribing. Error banners are still shown, because a
///                 failed recording start with no feedback at all would be worse than
///                 a briefly visible banner.
public enum OverlayPlacement: String, Codable, CaseIterable, Equatable {
    case center
    case bottom
    case notch
    case hidden

    public static let `default`: OverlayPlacement = .center

    /// Settings picker label.
    public var label: String {
        switch self {
        case .center: return "Center of Screen"
        case .bottom: return "Bottom of Screen"
        case .notch:  return "Under the Notch"
        case .hidden: return "Hidden"
        }
    }

    /// Settings footnote for the selected placement.
    public var detail: String {
        switch self {
        case .center:
            return "A large banner in the middle of the screen while you dictate."
        case .bottom:
            return "A compact indicator just above the Dock."
        case .notch:
            return "Hangs from the camera notch on MacBooks that have one; otherwise from the menu bar."
        case .hidden:
            return "No on-screen indicator. The menu bar icon still shows when you are recording; errors are still shown."
        }
    }

    /// Lenient decode: an unknown or malformed value must never make the whole
    /// config.json unparseable (Config.load resets EVERY setting to defaults on a decode
    /// failure). A few aliases are accepted so hand-edited configs read naturally.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = OverlayPlacement.parse(raw) ?? .default
    }

    /// Parse a user-facing string ("center", "bottom", "notch", "hidden", plus the
    /// aliases "top" → notch and "off"/"none" → hidden). nil when unrecognised.
    public static func parse(_ raw: String) -> OverlayPlacement? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "top":           return .notch
        case "off", "none":   return .hidden
        default:              return OverlayPlacement(rawValue: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Anchors

/// Which screen edge a given overlay frame is pinned to. `.center` placement keeps the
/// historical per-state anchors (banner centered, compact pill at the bottom, expanded
/// live-preview pill centered); the other placements collapse every state onto one edge.
enum OverlayAnchor: Equatable {
    case center
    case bottom
    case top
}

extension OverlayPlacement {
    /// The anchor to use for a state whose historical anchor is `historical`.
    /// `.hidden` only ever reaches this for error banners, which keep their historical
    /// (centered) anchor.
    func anchor(historical: OverlayAnchor) -> OverlayAnchor {
        switch self {
        case .center, .hidden: return historical
        case .bottom:          return .bottom
        case .notch:           return .top
        }
    }

    /// Whether this placement shows the recording/transcribing indicator at all.
    var showsIndicator: Bool { self != .hidden }

    /// Whether the indicator is drawn as an extension of the camera housing.
    var isNotch: Bool { self == .notch }
}

// MARK: - Screen geometry

/// Pure description of one screen, so frame math is unit-testable without a display.
/// Real values come from `NSScreen`; tests build them by hand.
struct OverlayScreenGeometry: Equatable {
    var frame: NSRect
    var visibleFrame: NSRect
    /// Height of the camera-housing strip (`NSScreen.safeAreaInsets.top`); 0 without a notch.
    var notchInset: CGFloat
    /// Width of the camera housing, or nil when the screen has none.
    var notchWidth: CGFloat?

    init(frame: NSRect, visibleFrame: NSRect, notchInset: CGFloat = 0, notchWidth: CGFloat? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.notchInset = notchInset
        self.notchWidth = notchWidth
    }

    init(screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        var width: CGFloat? = nil
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let gap = right.minX - left.maxX
            if gap > 0 { width = gap }
        }
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame,
                  notchInset: inset, notchWidth: width)
    }

    var hasNotch: Bool { notchInset > 0 && (notchWidth ?? 0) > 0 }

    /// Y of the edge a top-anchored overlay hangs from: the bottom of the camera
    /// housing on a notch screen, otherwise the bottom of the menu bar (which is the
    /// screen's top edge when the menu bar is hidden, e.g. in full screen).
    var topAnchorY: CGFloat {
        hasNotch ? frame.maxY - notchInset : visibleFrame.maxY
    }
}

// MARK: - Frame math

enum OverlayLayout {
    /// Gap between the bottom-anchored pill and the top of the Dock / screen edge.
    static let bottomMargin: CGFloat = 48

    /// Screen frame for an overlay window of `size` pinned to `anchor` on `screen`.
    /// Pure: every caller (show, async screen refinement, state updates, streaming
    /// resizes) routes through here so the anchors can't drift apart.
    static func frame(size: NSSize, anchor: OverlayAnchor, on screen: OverlayScreenGeometry) -> NSRect {
        let x = screen.frame.midX - size.width / 2
        let y: CGFloat
        switch anchor {
        case .center: y = screen.frame.midY - size.height / 2
        case .bottom: y = screen.visibleFrame.origin.y + bottomMargin
        case .top:    y = screen.topAnchorY - size.height
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Frame for a resize that must not move the anchored edge: the settle-in-place
    /// compaction keeps its center when centered, its bottom edge when bottom-anchored,
    /// and its top edge when hanging from the notch.
    static func resized(_ current: NSRect, to size: NSSize, anchor: OverlayAnchor) -> NSRect {
        let x = current.midX - size.width / 2
        let y: CGFloat
        switch anchor {
        case .center: y = current.midY - size.height / 2
        case .bottom: y = current.minY
        case .top:    y = current.maxY - size.height
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Window size for the notch treatment: never narrower than the camera housing,
    /// so the black body reads as the notch itself extending downward.
    static func notchWindowSize(content: NSSize, on screen: OverlayScreenGeometry) -> NSSize {
        NSSize(width: max(content.width, screen.notchWidth ?? 0), height: content.height)
    }

    /// Radius of the notch body's bottom corners.
    static let notchCornerRadius: CGFloat = 14
    /// Radius of the body's top corners when it is wider than the housing (or there is
    /// no housing). Kept small so the top edge still reads as attached to the bezel.
    static let notchTopCornerRadius: CGFloat = 8

    /// The black body hanging beneath the camera housing. When the body is no wider
    /// than the housing its top corners are square so the shape joins the notch with
    /// no visible seam; when it is wider (status text, live preview) or the screen has
    /// no notch, the top corners get a small radius.
    static func notchBodyPath(bounds: NSRect, notchWidth: CGFloat?) -> CGPath {
        let flush = notchWidth.map { bounds.width <= $0 + 1 } ?? false
        let bottomR = min(notchCornerRadius, bounds.height / 2, bounds.width / 2)
        let topR = flush ? 0 : min(notchTopCornerRadius, bounds.height / 2, bounds.width / 2)
        let path = CGMutablePath()
        let minX = bounds.minX, maxX = bounds.maxX, minY = bounds.minY, maxY = bounds.maxY
        path.move(to: CGPoint(x: minX, y: maxY - topR))
        if topR > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + topR, y: maxY), radius: topR)
        } else {
            path.addLine(to: CGPoint(x: minX, y: maxY))
        }
        path.addLine(to: CGPoint(x: maxX - topR, y: maxY))
        if topR > 0 {
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - topR), radius: topR)
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        }
        path.addLine(to: CGPoint(x: maxX, y: minY + bottomR))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX - bottomR, y: minY), radius: bottomR)
        path.addLine(to: CGPoint(x: minX + bottomR, y: minY))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: minY + bottomR), radius: bottomR)
        path.closeSubpath()
        return path
    }
}
