import AppKit
import ApplicationServices
import Foundation

/// The record-start inputs the off-main cursor-context read needs. Snapshotted on main so the
/// background reader never touches main-only state.
struct CursorContextRequest {
    /// Tail of the last successful insertion and where it landed (the AX-opaque fallback).
    var lastInsertionTail: String?
    var lastInsertionBundleID: String?
    var lastInsertionAt: Date?
    var lastInsertionElement: AXUIElement?
    var lastInsertionInteractionGeneration: UInt64?
    var interactionGenerationAtStart: UInt64 = 0
    var frontmostBundleID: String?
    /// Electron-class target: no live AX context, clipboard paste.
    var electronClass = false
    /// AX-opaque or Chromium-class target: the live read is skipped entirely.
    var avoidLiveWindowContext = false
}

/// Reads the focused element and the text before the cursor at record start: the element is
/// refocused before inserting, and the text feeds the prompt, the mid-sentence lowercase and the
/// prepend-space decision.
enum CursorContextCapture {

    /// Runs off main. Returns the focused element and up to 500 characters before the cursor.
    static func read(_ request: CursorContextRequest) -> (AXUIElement?, String?) {
        var capturedElement: AXUIElement?
        var capturedContext: String?
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: CFTypeRef?
        let frontBundle = request.frontmostBundleID
        let electronClass = request.electronClass
        let avoidLiveWindowContext = request.avoidLiveWindowContext
        // Electron-class apps get the trust gates on EVERY read (2026-07-25:
        // AXManualAccessibility persists per-app once flipped, so subsequent
        // reads succeed on this FIRST attempt — the gates must not live only
        // on the unlock-retry path). Native apps keep full-fidelity context.
        let result = avoidLiveWindowContext
            ? AXError.cannotComplete
            : AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &elementRef)
        if result == .success, let element = elementRef {
            // swiftlint:disable:next force_cast
            let axElement = element as! AXUIElement
            capturedElement = axElement
            if !electronClass {
                capturedContext = liveCursorContext(
                    readTextBeforeCursor(in: axElement),
                    isElectronClass: electronClass)
            }
        }

        // Electron AX unlock (2026-07-25): Electron apps ship with their AX tree
        // DISABLED and expose the app-level `AXManualAccessibility` switch to turn
        // it on without VoiceOver. Without it, typed-then-dictate in Superhuman/
        // VS Code has no cursor context, so the mid-sentence-lowercase feature
        // can't fire ("Search for X " + dictation came out capitalized). Flip the
        // switch on first failure, give the tree a beat to build, retry once.
        // We're on a background queue — the wait never touches main; pre-roll
        // covers the audio. Idempotent and harmless on non-Electron apps.
        if !electronClass, capturedContext == nil,
           let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString,
                                         kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.25)
            var retryRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(systemWide,
                                             kAXFocusedUIElementAttribute as CFString,
                                             &retryRef) == .success,
               let element = retryRef {
                // swiftlint:disable:next force_cast
                let axElement = element as! AXUIElement
                capturedElement = axElement
                capturedContext = readTextBeforeCursor(in: axElement, requireCursorAtEnd: true)
                if capturedContext != nil {
                    DiagnosticLogger.shared.log(
                        "captureFocusedElement: AXManualAccessibility unlock succeeded (cursor at end)")
                }
            }
        }

        // Repeat-value gate (2026-07-26). A live-AX context identical to the previous read
        // for this app is fixed UI chrome, not his cursor — see liveAXContextIsRepeat.
        if let live = capturedContext, liveAXContextIsRepeat(live, bundleID: frontBundle) {
            DiagnosticLogger.shared.log(
                "captureFocusedElement: discarded repeated live-AX context (\(live.count) chars, "
                + "identical to the previous read for \(frontBundle ?? "?")) — treating as no context")
            capturedContext = nil
        }

        // Electron editors (VS Code) expose no AXValue — fall back to the tail of our
        // own last insertion when it plausibly still sits before the cursor, so the
        // mid-sentence-lowercase and prepend-space features keep working there.
        var contextSource = capturedContext != nil ? "liveAX" : "none"
        if capturedContext == nil {
            let lastTail = request.lastInsertionTail
            let userInteracted = request.lastInsertionInteractionGeneration.map {
                $0 != request.interactionGenerationAtStart
            } ?? false
            let focusedElementMatches: Bool?
            if let lastElement = request.lastInsertionElement, let capturedElement {
                focusedElementMatches = CFEqual(lastElement, capturedElement)
            } else {
                focusedElementMatches = nil
            }
            let fallback = FinalizePipeline.fallbackCursorContext(
                lastInsertedTail: lastTail,
                lastInsertedBundleID: request.lastInsertionBundleID,
                lastInsertedAt: request.lastInsertionAt,
                frontmostBundleID: frontBundle,
                now: Date(),
                userInteractedSinceInsertion: userInteracted,
                focusedElementMatches: focusedElementMatches)
            if let fallback {
                capturedContext = fallback
                contextSource = "fallbackTail"
                DiagnosticLogger.shared.log(
                    "captureFocusedElement: AX gave no context — using tail of last insertion (\(fallback.count) chars)")
            } else if lastTail != nil, userInteracted {
                DiagnosticLogger.shared.log(
                    "captureFocusedElement: discarded remembered context after user interaction")
            } else if lastTail != nil, focusedElementMatches == false {
                DiagnosticLogger.shared.log(
                    "captureFocusedElement: discarded remembered context after focus changed")
            }
        }

        // When source=none, say WHY the live read produced nothing: an AX-opaque /
        // Chromium-class app has its live read deliberately skipped (context can only
        // come from the remembered insertion tail), which is a very different state from
        // a native app whose AX read was attempted and came back empty. Without this
        // distinction the "source=none len=0" line reads as "AX is failing" when the read
        // never ran (2026-08-18 bug hunt was misdirected by exactly this ambiguity).
        let noneReason = contextSource == "none"
            ? (avoidLiveWindowContext
                ? " (liveAX skipped: AX-opaque/Chromium-class \(frontBundle ?? "?"))"
                : " (liveAX attempted, empty)")
            : ""
        DiagnosticLogger.shared.log("captureFocusedElement: context source=\(contextSource) len=\(capturedContext?.count ?? 0)\(noneReason)")
        return (capturedElement, capturedContext)
    }

    /// Guards `lastLiveAXContextByApp`, written from the background capture queue.
    private static let liveAXContextLock = NSLock()
    /// bundleID -> the last live-AX cursor context we accepted for that app.
    private static var lastLiveAXContextByApp: [String: String] = [:]

    /// Record this live-AX context and report whether it is a REPEAT for the same app.
    ///
    /// 2026-07-26 — the three Electron trust gates in `readTextBeforeCursor` all reject things
    /// that are too BIG (cursor not at end, >1200 chars, >4 newlines). They were built to keep
    /// out the VS Code terminal scrollback. What actually got through was too SMALL: on 07-26,
    /// 83 of the day's reads in VS Code returned one of exactly two constant strings (22 and 32
    /// chars), while every genuine context length appeared once or twice. speakfree read that
    /// fixed UI string as "the text before your cursor" and therefore prepended a space and
    /// lowercased the first word — 57 wrongly-lowercased dictations that day, 63 the day before,
    /// and 0 on the two days before the Electron AX unlock shipped.
    ///
    /// A real cursor context changes: he types, or our own insertion lands in the field. A value
    /// byte-identical to the previous one for the same app is chrome, not his text. Rejecting it
    /// falls back to no-context, which disables exactly the two features that were misfiring,
    /// and only for the reads that were wrong.
    static func liveAXContextIsRepeat(_ context: String, bundleID: String?) -> Bool {
        let key = bundleID ?? "?"
        liveAXContextLock.lock()
        defer { liveAXContextLock.unlock() }
        let isRepeat = lastLiveAXContextByApp[key] == context
        lastLiveAXContextByApp[key] = context
        return isRepeat
    }

    /// Test seam — the table is process-global, so tests must be able to clear it.
    static func resetLiveAXContextMemory() {
        liveAXContextLock.lock()
        lastLiveAXContextByApp.removeAll()
        liveAXContextLock.unlock()
    }

    static func liveCursorContext(_ context: String?, isElectronClass: Bool) -> String? {
        isElectronClass ? nil : context
    }

    /// AX roles that can actually hold a text cursor. Everything else is chrome.
    ///
    /// 2026-07-26 — walking VS Code's full AX tree (14 windows, 20k+ nodes) found the string
    /// behind 45 of the day's bad reads: `⌘ Esc to focus or unfocus Claude`, exactly 32
    /// characters, the Claude Code panel's hint label. It carries no terminal punctuation and no
    /// trailing space, which is precisely the `prependSpace=true midSentence=true` signature the
    /// log recorded 45 times. It is a LABEL. speakfree read it as "the text before your cursor"
    /// and lowercased the first word of the dictation that followed.
    ///
    /// The size gates could never have caught this (a 32-char label is small), and the
    /// repeat-value gate only half-catches it (reads alternate between two chrome strings, so
    /// only 40 of 150 were identical to their predecessor). Asking what KIND of element it is
    /// separates a label from an input in one attribute.
    static let cursorBearingRoles: Set<String> = [
        kAXTextAreaRole as String, kAXTextFieldRole as String,
        kAXComboBoxRole as String, "AXSearchField",
    ]

    /// Reads up to 500 characters before the cursor without changing selection or focus.
    /// `requireCursorAtEnd`: trust gate for the AXManualAccessibility-unlocked
    /// Electron read (2026-07-25: VS Code's reported cursor offset can be stale/
    /// wrong, yielding context that "ends mid-sentence" and wrongly lowercasing a
    /// fresh paragraph — the engine had capitalized "As usual" correctly). When
    /// set, context is only returned if the cursor is verifiably at the END of
    /// the field — the appending flow dictation actually uses.
    static func readTextBeforeCursor(in element: AXUIElement,
                                     requireCursorAtEnd: Bool = false) -> String? {
        // Role gate, before anything else: a label, button or static text never holds a cursor,
        // so its text is never "what he typed before dictating".
        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                                 &roleRef) == .success
            ? (roleRef as? String ?? "?") : "?"
        guard cursorBearingRoles.contains(role) else {
            DiagnosticLogger.shared.log(
                "readTextBeforeCursor: ignoring focused element of role \(role) — not a text input")
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String, !fullText.isEmpty else { return nil }

        // Try to get cursor position from selected text range
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef,
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            // swiftlint:disable:next force_cast
            AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
            // range.location is a UTF-16 offset — convert via the utf16 view (AX-E).
            let cursorIndex = max(0, range.location)
            if requireCursorAtEnd {
                // Electron trust gates (2026-07-25): offset must be at field end, AND
                // the field must be input-sized — VS Code hands us the TERMINAL
                // SCROLLBACK document as the "focused element", whose tail never ends
                // in whitespace (phantom leading spaces + wrongful lowercase). Real
                // inputs (search boxes, chat prompts) are short; documents are not.
                if cursorIndex < fullText.utf16.count { return nil }
                // Input-shaped only: a VS Code TUI screen can be under 4000 chars,
                // but no search box or chat prompt is 5+ lines of text ending in a
                // shell prompt. (2026-07-25, third phantom-space report.)
                if fullText.utf16.count > 1200 { return nil }
                if fullText.filter({ $0.isNewline }).count > 4 { return nil }
            }
            if cursorIndex > 0, let before = TextInserter.textBeforeUTF16Offset(fullText, cursorIndex) {
                // Take last 500 chars to stay within whisper's prompt limits
                return String(before.suffix(500))
            }
        }

        // No cursor info: DO NOT guess from the whole field's tail (2026-07-25:
        // the AXManualAccessibility unlock opened Electron fields whose tail is
        // arbitrary document text — it rarely ends in a space, so the prepend-space
        // logic added phantom leading spaces to every dictation). nil lets the
        // last-insertion fallback chain decide, which carries real cursor knowledge.
        return nil
    }
}

/// R1: a generation-guarded holder for an off-main capture result.
///
/// `begin()` opens a new generation (invalidating any in-flight prior capture) and returns
/// a token. The background reader calls `publish(_:token:)` when its work lands. The
/// consumer calls `consume(waitingUpTo:)`, which returns the published value immediately if
/// it has already arrived, or waits up to `timeout` for it — and returns `nil` on timeout,
/// matching the old "AX query timed out → no context" behavior. `publish` is always called
/// off the consumer's thread and signals a semaphore, so `consume` waiting on the consumer
/// (main) thread can never deadlock. `reset()` puts the box into a published-nil state so a
/// consume returns immediately with no value (used when a capture is skipped or invalidated).
/// Every field is guarded by `lock`, so the box is safe to hand to the background reader.
final class FocusCaptureBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var value: Value?
    private var published = false
    private var semaphore: DispatchSemaphore?
    /// When the current generation was opened. A capture is only valid within
    /// `captureDeadline` of this instant — see `publish`/`consume`.
    private var beganAt: Date?
    /// Start-relative validity window. Restores HEAD's "context is from record-START"
    /// semantics: a result that only lands (or that a consumer would only wait for) more than
    /// this long after `begin()` reflects mid-recording focus, not the focus at record-start,
    /// so it is discarded rather than accepted.
    private let captureDeadline: TimeInterval

    init(captureDeadline: TimeInterval = 0.5) {
        self.captureDeadline = captureDeadline
    }

    /// Open a new generation. Returns the token the background reader must pass to `publish`.
    func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        value = nil
        published = false
        semaphore = DispatchSemaphore(value: 0)
        beganAt = Date()
        return generation
    }

    /// Publish the captured value. Dropped if `token` is stale (a newer `begin()`/`reset()`
    /// ran), the current generation was already published, or the capture landed more than
    /// `captureDeadline` after `begin()` (a late read reflects mid-recording, not record-start).
    func publish(_ newValue: Value?, token: Int) {
        lock.lock()
        let tooLate = beganAt.map { Date().timeIntervalSince($0) > captureDeadline } ?? true
        guard token == generation, !published, !tooLate else { lock.unlock(); return }
        value = newValue
        published = true
        let sem = semaphore
        lock.unlock()
        sem?.signal()
    }

    /// Return the published value, waiting only until the start-relative deadline (and at most
    /// `timeout`) if the capture is still in flight. Never blocks the caller beyond that; `nil`
    /// on timeout (graceful degradation). Clears the stored value/element on return so the AX
    /// element and cursor-adjacent text are never retained past a single consume (privacy).
    func consume(waitingUpTo timeout: TimeInterval) -> Value? {
        lock.lock()
        if published { let v = value; value = nil; lock.unlock(); return v }
        // If the capture can no longer legally publish (past its start-relative deadline),
        // return immediately rather than blocking main on a result that will be rejected. This
        // also kills the between-dictations 0.5s block when no capture is in flight for this gen.
        let remaining: TimeInterval = beganAt.map { captureDeadline - Date().timeIntervalSince($0) } ?? 0
        if remaining <= 0 { let v = value; value = nil; lock.unlock(); return v }
        let sem = semaphore
        lock.unlock()
        _ = sem?.wait(timeout: .now() + min(timeout, remaining))
        lock.lock(); let v = value; value = nil; lock.unlock()
        return v
    }

    /// Invalidate any in-flight capture and put the box into a published-nil state so the
    /// next `consume` returns `nil` immediately (no wait).
    func reset() {
        lock.lock()
        generation += 1
        value = nil
        published = true
        semaphore = nil
        beganAt = nil
        lock.unlock()
    }
}
