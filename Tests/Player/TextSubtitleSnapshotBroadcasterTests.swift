@testable import MPVUI
import Testing

struct TextSubtitleSnapshotBroadcasterTests {
    @Test
    func `subscribers independently replay and receive latest snapshots`() async {
        let broadcaster = TextSubtitleSnapshotBroadcaster()
        var first = broadcaster.subscribe().makeAsyncIterator()
        var second = broadcaster.subscribe().makeAsyncIterator()

        let firstInitial = await first.next()
        let secondInitial = await second.next()
        #expect(firstInitial == TextSubtitleSnapshot())
        #expect(secondInitial == TextSubtitleSnapshot())

        let displayed = TextSubtitleSnapshot(regions: [
            TextSubtitleRegion(text: "displayed"),
        ])
        broadcaster.publish(displayed)

        let firstDisplayed = await first.next()
        let secondDisplayed = await second.next()
        #expect(firstDisplayed == displayed)
        #expect(secondDisplayed == displayed)

        var late = broadcaster.subscribe().makeAsyncIterator()
        let replayed = await late.next()
        #expect(replayed == displayed)
    }

    @Test
    func `slow subscriber keeps only newest snapshot`() async {
        let broadcaster = TextSubtitleSnapshotBroadcaster()
        var values = broadcaster.subscribe().makeAsyncIterator()
        let first = TextSubtitleSnapshot(regions: [TextSubtitleRegion(text: "first")])
        let newest = TextSubtitleSnapshot(regions: [TextSubtitleRegion(text: "newest")])

        broadcaster.publish(first)
        broadcaster.publish(newest)

        let delivered = await values.next()
        #expect(delivered == newest)
    }

    @Test
    func `termination clears active subtitle then finishes`() async {
        let broadcaster = TextSubtitleSnapshotBroadcaster()
        var values = broadcaster.subscribe().makeAsyncIterator()
        _ = await values.next()

        let displayed = TextSubtitleSnapshot(regions: [
            TextSubtitleRegion(text: "displayed"),
        ])
        broadcaster.publish(displayed)
        let received = await values.next()
        #expect(received == displayed)

        broadcaster.terminate()
        let cleared = await values.next()
        let finished = await values.next()
        #expect(cleared == TextSubtitleSnapshot())
        #expect(finished == nil)
    }

    @Test
    @MainActor
    func `player stream opts in and starts empty`() async {
        let player = MPVPlayer()
        var values = player.textSubtitleStream().makeAsyncIterator()

        let initial = await values.next()
        #expect(initial == TextSubtitleSnapshot())
        #expect(player.lastError == nil)
    }
}
