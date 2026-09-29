import Foundation

/// Where a finalized dictation's text goes (C1). `insertImmediately`: the pipeline text is
/// composed and handed to the TextInserter. `returnToEditSession`: the finalized segment is
/// delivered to the open edit session and is STRUCTURALLY unable to reach the inserter (see
/// DictationSession.finalizeRecording, where the destinations are mutually-exclusive branches —
/// only insertImmediately calls deliverAtCursor). `returnToCaller`: a take whose destination is
/// `.caller` (a local API dictation with `"destination": "caller"`, or any host that asked for the
/// text back) returns its text and never types at the cursor.
///
/// The captured target for an edit session is immutable for the session's life: segments 2+ do NOT
/// re-run focus capture. That is why the destination is decided from a target token captured when
/// the segment's recording began, not re-derived at finalize.
public enum FinalizeDestination: Equatable {
    case insertImmediately
    case returnToEditSession(sessionID: UUID, segmentID: UUID)
    case returnToCaller(sessionID: UUID)

    /// Pure resolution so the routing rule is unit-testable without a live session. A segment
    /// belongs to an edit session iff a target was captured for it at record-start (nil for every
    /// hold/toggle dictation — those insert immediately, byte-identically to before Edit Mode).
    ///
    /// `callerSession` is the local-API session that asked for its text back (nil for every hotkey
    /// dictation and for API sessions with `"destination": "cursor"`). An edit target wins: the two
    /// are never set together in practice, and the edit session's no-insert guarantee must hold.
    public static func resolve(editTarget: (sessionID: UUID, segmentID: UUID)?,
                               callerSession: UUID? = nil) -> FinalizeDestination {
        if let t = editTarget {
            return .returnToEditSession(sessionID: t.sessionID, segmentID: t.segmentID)
        }
        if let id = callerSession {
            return .returnToCaller(sessionID: id)
        }
        return .insertImmediately
    }
}

/// The payload the finalize path delivers to an open edit session instead of inserting. Carries the
/// raw pre-pipeline transcript (the model's input), the pipeline text (the provisional floor and
/// the model's reference), the audio URL, and the recording meta — everything the session needs to
/// settle the segment, with no path back to the inserter.
public struct EditFinalizePayload {
    public let sessionID: UUID
    public let segmentID: UUID
    public let raw: String
    public let pipelineText: String
    public let audioURL: URL
    public let meta: RecordingStore.RecordingMeta

    public init(sessionID: UUID, segmentID: UUID, raw: String, pipelineText: String,
                audioURL: URL, meta: RecordingStore.RecordingMeta) {
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.raw = raw
        self.pipelineText = pipelineText
        self.audioURL = audioURL
        self.meta = meta
    }
}

/// The payload a `returnToCaller` finalize hands to the local API instead of inserting: the raw
/// engine transcript, the post-processed text (spoken punctuation, glossary), and the final styled
/// text that would have been typed at the cursor.
public struct CallerFinalizePayload: Equatable {
    public let sessionID: UUID
    public let raw: String
    public let processed: String
    public let styled: String

    public init(sessionID: UUID, raw: String, processed: String, styled: String) {
        self.sessionID = sessionID
        self.raw = raw
        self.processed = processed
        self.styled = styled
    }
}
