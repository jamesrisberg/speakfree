import Foundation

/// Turns hotkey presses and releases into dictation intents, with an optional alternate
/// gesture that sends the same recording somewhere else.
///
/// Recording always starts on the first press (`.begin(.primary)`), so no speech is lost
/// while a gesture is still ambiguous; a completed alternate gesture only changes the
/// destination (`.retarget(.alternate)`).
///
///   Toggle: tap begins primary; a second tap within `doubleTapWindow` of the first tap's
///           release retargets to alternate and keeps recording; the next tap ends.
///   Hold:   press begins primary; a release after `tapMaxDuration` ends. A quick tap
///           followed by a press within `doubleTapWindow` retargets to alternate, and that
///           press's release ends. A lone quick tap is discarded once the window lapses.
///
/// Only a first press no longer than `tapMaxDuration` opens the double-tap window, in both
/// modes. That keeps a long toggle press followed by a quick stop tap an ordinary stop, and
/// it keeps a take whose release was delayed by `HotkeyManager`'s phantom-release guard (the
/// press then appears to last until the user's next tap) from being read as a double tap.
///
/// With `alternateEnabled == false` the intents reproduce the plain hold/toggle behavior:
/// hold begins on press and ends on release, toggle alternates begin and end on each press.
///
/// Pure and single-threaded: the caller supplies monotonic timestamps and whether a
/// dictation session is currently running. `sessionActive` is authoritative, because a
/// session can end (or start) without the hotkey: a recognizer that believes a session is
/// running when the caller says none is resets to idle before handling the event, and a
/// press while idle with a session running treats that session as the one to control.
/// `sessionActive` must reflect a `.begin` by the next event.
///
/// A pending hold-mode tap needs a timer: while `deadline` is non-nil the caller calls
/// `expire(at:sessionActive:)` at or after it.
public struct KeyGestureRecognizer: Equatable {
    public enum Mode: Equatable, Sendable {
        case hold
        case toggle
    }

    public enum Target: Equatable, Sendable {
        case primary
        case alternate
    }

    public enum Intent: Equatable, Sendable {
        /// Start recording for `Target`.
        case begin(Target)
        /// Keep recording, but deliver the result to `Target`.
        case retarget(Target)
        /// Stop recording and deliver the result.
        case end
        /// Stop recording and drop it (a lone quick tap in hold mode).
        case discard
    }

    public struct Configuration: Equatable, Sendable {
        public var alternateEnabled: Bool
        /// Longest gap between the first tap's release and the second press.
        public var doubleTapWindow: TimeInterval
        /// Longest press that still counts as a tap.
        public var tapMaxDuration: TimeInterval

        public init(alternateEnabled: Bool = false,
                    doubleTapWindow: TimeInterval = 0.30,
                    tapMaxDuration: TimeInterval = 0.20) {
            self.alternateEnabled = alternateEnabled
            self.doubleTapWindow = doubleTapWindow
            self.tapMaxDuration = tapMaxDuration
        }
    }

    private enum Phase: Equatable {
        case idle
        /// The press that began the session is still down.
        case firstPress(at: TimeInterval)
        /// The first press was a quick tap; a press before `releasedAt + doubleTapWindow`
        /// completes the alternate gesture.
        case awaitingSecondPress(releasedAt: TimeInterval)
        /// A session is running with no gesture pending.
        case active
    }

    public let mode: Mode
    public let configuration: Configuration
    private var phase: Phase = .idle
    /// Mirrors the key, so a repeated press (key auto-repeat) is ignored.
    private var keyIsDown = false

    public init(mode: Mode, configuration: Configuration = Configuration()) {
        self.mode = mode
        self.configuration = configuration
    }

    /// When the caller must call `expire`: set only while a hold-mode quick tap waits for
    /// its second press. Toggle mode needs no timer, because its lapsed window has no
    /// output (the tap already began a primary session).
    public var deadline: TimeInterval? {
        guard mode == .hold, case .awaitingSecondPress(let releasedAt) = phase else { return nil }
        return releasedAt + configuration.doubleTapWindow
    }

    public mutating func keyDown(at time: TimeInterval, sessionActive: Bool) -> [Intent] {
        reconcile(sessionActive: sessionActive)
        guard !keyIsDown else { return [] }
        keyIsDown = true
        switch (mode, phase) {
        case (_, .idle):
            if sessionActive {
                // A session the hotkey did not begin: toggle stops it now, hold on release.
                if mode == .toggle { return [.end] }
                phase = .active
                return []
            }
            phase = .firstPress(at: time)
            return [.begin(.primary)]
        case (_, .awaitingSecondPress(let releasedAt)):
            if time - releasedAt < configuration.doubleTapWindow {
                phase = .active
                return [.retarget(.alternate)]
            }
            if mode == .toggle {
                phase = .idle
                return [.end]
            }
            // The window lapsed before `expire` ran: settle the lone tap, then this press
            // begins a new session.
            phase = .firstPress(at: time)
            return [.discard, .begin(.primary)]
        case (.toggle, .firstPress), (.toggle, .active):
            phase = .idle
            return [.end]
        case (.hold, .firstPress), (.hold, .active):
            return []
        }
    }

    public mutating func keyUp(at time: TimeInterval, sessionActive: Bool) -> [Intent] {
        reconcile(sessionActive: sessionActive)
        keyIsDown = false
        switch phase {
        case .firstPress(let pressedAt):
            if configuration.alternateEnabled, time - pressedAt <= configuration.tapMaxDuration {
                phase = .awaitingSecondPress(releasedAt: time)
                return []
            }
            if mode == .toggle {
                phase = .active
                return []
            }
            phase = .idle
            return [.end]
        case .active:
            if mode == .toggle { return [] }
            phase = .idle
            return [.end]
        case .idle:
            // Hold ends a running session on any release, including one whose press was not
            // seen (for example a release reconciled after an event-tap outage).
            return mode == .hold && sessionActive ? [.end] : []
        case .awaitingSecondPress:
            return []
        }
    }

    /// Settles a hold-mode quick tap whose window has lapsed. Returns nothing before the
    /// deadline, so an early timer is harmless.
    public mutating func expire(at time: TimeInterval, sessionActive: Bool) -> [Intent] {
        reconcile(sessionActive: sessionActive)
        guard let deadline, time >= deadline else { return [] }
        phase = .idle
        return [.discard]
    }

    /// The caller aborted the take (a keyboard shortcut rather than dictation). The key's
    /// release may never be reported, so the key state is cleared too.
    public mutating func abort() {
        phase = .idle
        keyIsDown = false
    }

    private mutating func reconcile(sessionActive: Bool) {
        if !sessionActive, phase != .idle { phase = .idle }
    }
}
