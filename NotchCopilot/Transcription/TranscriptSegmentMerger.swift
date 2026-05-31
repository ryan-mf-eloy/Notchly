import Foundation

struct TranscriptSegmentMerger: Sendable, Hashable {
    enum Decision: Sendable, Equatable {
        case ignore
        case append(TranscriptSegment)
        case replace(index: Int, segment: TranscriptSegment, tail: TranscriptSegment?)
    }

    private let ledger = MeetingTranscriptLedger()

    func decision(for incoming: TranscriptSegment, in segments: [TranscriptSegment]) -> Decision {
        switch ledger.decision(for: incoming, in: segments) {
        case .ignore:
            return .ignore
        case .append(let segment):
            return .append(segment)
        case .replace(let index, let segment, let tail):
            return .replace(index: index, segment: segment, tail: tail)
        }
    }
}
