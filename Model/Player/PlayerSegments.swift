import CoreMedia
import Defaults
import Foundation

extension PlayerModel {
    func handleSegments(at time: CMTime) {
        if let segment = lastSkipped {
            if time > CMTime(seconds: segment.end + 10, preferredTimescale: 1_000_000) {
                resetLastSegment()
            }
        }
        guard let firstSegment = sponsorBlock.segments.first(where: { $0.timeInSegment(time) }) else {
            return
        }

        // find last segment in case they are 2 sec or less after each other
        // to avoid multiple skips in a row
        var nextSegments = [firstSegment]

        while let segment = sponsorBlock.segments.first(where: {
            $0.timeInSegment(CMTime(seconds: nextSegments.last!.end + 2, preferredTimescale: 1_000_000))
        }) {
            nextSegments.append(segment)
        }

        if let segmentToSkip = nextSegments.last(where: { $0.endTime <= playerItemDuration ?? .zero }),
           self.shouldSkip(segmentToSkip, at: time)
        {
            skip(segmentToSkip, at: time)
        }
    }

    private func skip(_ segment: Segment, at time: CMTime) {
        guard segment.endTime.seconds <= playerItemDuration?.seconds ?? .infinity else {
            logger.error("item time is: \(time.seconds) and trying to skip to \(playerItemDuration?.seconds ?? .infinity)")
            return
        }

        player.seek(to: segment.endTime)
        lastSkipped = segment
        segmentRestorationTime = time
        logger.info("SponsorBlock skipping to: \(segment.endTime)")
    }

    private func shouldSkip(_ segment: Segment, at time: CMTime) -> Bool {
        guard isPlaying,
              !restoredSegments.contains(segment),
              Defaults[.sponsorBlockCategories].contains(segment.category)
        else {
            return false
        }

        return time.seconds - segment.start < 2 && segment.end - time.seconds > 2
    }

    func restoreLastSkippedSegment() {
        guard let segment = lastSkipped,
              let time = segmentRestorationTime
        else {
            return
        }

        restoredSegments.append(segment)
        player.seek(to: time)
        resetLastSegment()
    }

    private func resetLastSegment() {
        lastSkipped = nil
        segmentRestorationTime = nil
    }

    func resetSegments() {
        resetLastSegment()
        restoredSegments = []
    }
}
