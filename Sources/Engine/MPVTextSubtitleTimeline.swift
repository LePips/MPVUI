/// Builds complete presentations from native cue boundaries without sampling
/// time, which would miss short cues and cues containing a seek destination.
enum MPVTextSubtitleTimeline {
    static func snapshots(from node: MPVNodeValue?) -> [TimedTextSubtitleSnapshot]? {
        guard let values = node?.arrayValue else { return nil }
        struct Boundary {
            let time: Duration
            let cue: Int
            let begins: Bool
        }
        var boundaries: [Boundary] = []
        var regions: [TextSubtitleRegion] = []
        for value in values {
            guard let fields = value.mapValue,
                  let start = fields["start"]?.doubleValue.flatMap(Duration.init(mpvSeconds:)),
                  let end = fields["end"]?.doubleValue.flatMap(Duration.init(mpvSeconds:)),
                  start < end,
                  let region = MPVTextSubtitleParser.snapshot(from: .array([value])).regions.first
            else { return nil }
            let index = regions.count
            regions.append(region)
            boundaries.append(Boundary(time: start, cue: index, begins: true))
            boundaries.append(Boundary(time: end, cue: index, begins: false))
        }
        boundaries.sort { $0.time < $1.time }
        var active: Set<Int> = []
        var result: [TimedTextSubtitleSnapshot] = []
        var index = 0
        while index < boundaries.count {
            let start = boundaries[index].time
            repeat {
                let boundary = boundaries[index]
                if boundary.begins {
                    active.insert(boundary.cue)
                } else {
                    active.remove(boundary.cue)
                }
                index += 1
            } while index < boundaries.count && boundaries[index].time == start
            guard index < boundaries.count, !active.isEmpty else {
                continue
            }
            let end = boundaries[index].time
            let snapshot = TextSubtitleSnapshot(regions: active.sorted().map { regions[$0] })
            if let last = result.last, last.endTime == start, last.snapshot == snapshot {
                result[result.count - 1] = TimedTextSubtitleSnapshot(
                    startTime: last.startTime, endTime: end, snapshot: snapshot
                )
            } else {
                result.append(TimedTextSubtitleSnapshot(startTime: start, endTime: end, snapshot: snapshot))
            }
        }
        return result
    }
}
