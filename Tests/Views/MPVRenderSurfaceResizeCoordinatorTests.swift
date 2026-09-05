import CoreGraphics
import Dispatch
@testable import MPVUI
import QuartzCore
import Testing

@Suite(.serialized)
struct MPVRenderSurfaceResizeCoordinatorTests {
    @Test
    @MainActor
    func `continuous resize commits its leading edge immediately`() async {
        let harness = makeHarness(
            timing: timing(cadence: 40_000_000, continuousFinal: 500_000_000)
        )
        harness.layer.resetAssignments()

        harness.coordinator.beginContinuousInteraction()
        #expect(
            harness.coordinator.requestResize(
                to: CGSize(width: 200, height: 120),
                contentsScale: 2,
                kind: .continuousInteractive
            )
        )

        #expect(await eventually { harness.driver.requests.count == 1 })
        let request = harness.driver.requests[0]
        #expect(request.drawableSize == CGSize(width: 200, height: 120))
        #expect(request.contentsScale == 2)
        #expect(request.geometryChangeKind == .continuousInteractive)
        #expect(harness.layer.drawableSize == defaultInitialSize)
        #expect(harness.layer.contentsScale == 2)
        #expect(harness.layer.assignments.isEmpty)
        #expect(harness.layer.contentsScaleAssignments.last?.contentsScale == 2)
        #expect(
            harness.layer.contentsScaleAssignments.last?
                .actionsWereDisabled == true
        )
        #expect(
            harness.coordinator.diagnosticSnapshot.inFlight?.identifier
                == request.identifier
        )

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize
                    == request.drawableSize
            }
        )
        harness.coordinator.deactivate()
    }

    @Test
    @MainActor
    func `continuous burst coalesces to newest pending size with one commit in flight`() async {
        let harness = makeHarness(
            timing: timing(cadence: 15_000_000, continuousFinal: 5_000_000_000)
        )

        harness.coordinator.requestResize(
            to: CGSize(width: 200, height: 120),
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })

        harness.coordinator.requestResize(
            to: CGSize(width: 300, height: 180),
            contentsScale: 1,
            kind: .continuousInteractive
        )
        harness.coordinator.requestResize(
            to: CGSize(width: 400, height: 240),
            contentsScale: 1,
            kind: .continuousInteractive
        )

        #expect(harness.driver.requests.count == 1)
        #expect(harness.driver.maximumConcurrentCommits == 1)
        #expect(
            harness.coordinator.diagnosticSnapshot.pendingDrawableSize
                == CGSize(width: 400, height: 240)
        )

        harness.driver.completeFirst(with: true)
        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(
            harness.driver.requests[1].drawableSize
                == CGSize(width: 400, height: 240)
        )
        #expect(harness.driver.maximumConcurrentCommits == 1)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.inFlight == nil
            }
        )
        harness.coordinator.deactivate()
    }

    @Test
    @MainActor
    func `continuous commits are bounded by cadence`() async throws {
        let cadence: UInt64 = 45_000_000
        let harness = makeHarness(
            timing: timing(cadence: cadence, continuousFinal: 500_000_000),
            automaticResult: true
        )

        harness.coordinator.requestResize(
            to: CGSize(width: 200, height: 120),
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        harness.coordinator.requestResize(
            to: CGSize(width: 220, height: 132),
            contentsScale: 1,
            kind: .continuousInteractive
        )

        await sleep(nanoseconds: 10_000_000)
        #expect(harness.driver.requests.count == 1)
        #expect(await eventually { harness.driver.requests.count == 2 })

        let firstSubmission = try #require(
            harness.driver.submissionTimes.first
        )
        let secondSubmission = try #require(
            harness.driver.submissionTimes.dropFirst().first
        )
        let interval = secondSubmission - firstSubmission
        #expect(interval >= 30_000_000)
        harness.coordinator.deactivate()
    }

    @Test
    @MainActor
    func `continuous inactivity performs an exact trailing final commit`() async {
        let finalSize = CGSize(width: 320, height: 180)
        let harness = makeHarness(
            timing: timing(cadence: 100_000_000, continuousFinal: 20_000_000),
            automaticResult: true
        )

        harness.coordinator.requestResize(
            to: finalSize,
            contentsScale: 2,
            kind: .continuousInteractive
        )

        #expect(
            await eventually {
                !harness.coordinator.diagnosticSnapshot.finalCommitRequired
            }
        )
        #expect(harness.driver.requests.count == 2)
        #expect(harness.driver.requests[0].geometryChangeKind == .continuousInteractive)
        #expect(harness.driver.requests[0].drawableSize == finalSize)
        #expect(harness.driver.requests[1].geometryChangeKind == .final)
        #expect(harness.driver.requests[1].drawableSize == finalSize)
        #expect(!harness.coordinator.diagnosticSnapshot.isContinuousInteraction)
    }

    @Test
    @MainActor
    func `unchanged continuous layout does not synthesize a trailing resize`() async {
        let trailingDelay: UInt64 = 20_000_000
        let harness = makeHarness(
            timing: timing(
                cadence: 0,
                continuousFinal: trailingDelay,
                discrete: 0
            ),
            automaticResult: true
        )

        #expect(
            !harness.coordinator.requestResize(
                to: defaultInitialSize,
                contentsScale: 1,
                kind: .continuousInteractive
            )
        )

        let synchronized = harness.coordinator.diagnosticSnapshot
        #expect(synchronized.event == .snapshot)
        #expect(!synchronized.isContinuousInteraction)
        #expect(!synchronized.finalCommitRequired)
        #expect(!synchronized.hasContinuousFinalFallback)
        #expect(synchronized.pendingDrawableSize == nil)

        await sleep(nanoseconds: trailingDelay * 2)
        #expect(harness.driver.requests.isEmpty)
        #expect(harness.diagnostics.events.contains(.alreadySynchronized))
        #expect(!harness.diagnostics.events.contains(.continuousFinalScheduled))
    }

    @Test
    @MainActor
    func `explicit continuous end supersedes in-flight geometry with authoritative final`() async {
        let trailingDelay: UInt64 = 500_000_000
        let harness = makeHarness(
            timing: timing(
                cadence: 200_000_000,
                continuousFinal: trailingDelay
            )
        )

        harness.coordinator.requestResize(
            to: CGSize(width: 200, height: 120),
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        harness.coordinator.requestResize(
            to: CGSize(width: 220, height: 132),
            contentsScale: 1,
            kind: .continuousInteractive
        )
        harness.coordinator.endContinuousInteraction(
            finalSize: CGSize(width: 240, height: 144),
            contentsScale: 1
        )

        #expect(
            harness.coordinator.diagnosticSnapshot.pendingDrawableSize
                == CGSize(width: 240, height: 144)
        )
        harness.driver.completeFirst(with: true)
        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(harness.driver.requests[1].geometryChangeKind == .final)
        #expect(
            harness.driver.requests[1].drawableSize
                == CGSize(width: 240, height: 144)
        )

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize
                    == CGSize(width: 240, height: 144)
            }
        )
        #expect(!harness.coordinator.diagnosticSnapshot.finalCommitRequired)

        let requestCountAfterFinal = harness.driver.requests.count
        await sleep(nanoseconds: trailingDelay + 100_000_000)
        #expect(harness.driver.requests.count == requestCountAfterFinal)
        #expect(
            !harness.diagnostics.events.contains(.continuousFinalScheduled)
        )
    }

    @Test
    @MainActor
    func `aborting continuous interaction clears queued state but preserves in-flight work`() async {
        let inFlightSize = CGSize(width: 200, height: 120)
        let pendingSize = CGSize(width: 240, height: 144)
        let harness = makeHarness(
            timing: timing(cadence: 200_000_000, continuousFinal: 100_000_000)
        )

        harness.coordinator.requestResize(
            to: inFlightSize,
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        harness.coordinator.requestResize(
            to: pendingSize,
            contentsScale: 2,
            kind: .continuousInteractive
        )

        let beforeAbort = harness.coordinator.diagnosticSnapshot
        let inFlightIdentifier = beforeAbort.inFlight?.identifier
        #expect(beforeAbort.pendingDrawableSize == pendingSize)
        #expect(beforeAbort.contentsScale == 2)
        #expect(harness.layer.contentsScale == 1)
        #expect(beforeAbort.isContinuousInteraction)
        #expect(beforeAbort.finalCommitRequired)
        #expect(beforeAbort.hasContinuousFinalFallback)

        harness.coordinator.abortContinuousInteraction()

        let aborted = harness.coordinator.diagnosticSnapshot
        #expect(aborted.activeLayerAddress == beforeAbort.activeLayerAddress)
        #expect(aborted.committedDrawableSize == beforeAbort.committedDrawableSize)
        #expect(aborted.inFlight?.identifier == inFlightIdentifier)
        #expect(aborted.inFlight?.drawableSize == inFlightSize)
        #expect(aborted.inFlight?.contentsScale == 1)
        #expect(aborted.inFlight?.geometryChangeKind == .continuousInteractive)
        #expect(aborted.surfaceGeneration == beforeAbort.surfaceGeneration)
        #expect(aborted.contentsScale == 1)
        #expect(harness.layer.contentsScale == 1)
        #expect(aborted.latestRequestedDrawableSize == nil)
        #expect(aborted.pendingDrawableSize == nil)
        #expect(!aborted.isContinuousInteraction)
        #expect(!aborted.finalCommitRequired)
        #expect(!aborted.hasScheduledCommit)
        #expect(!aborted.hasAnimatedFallback)
        #expect(!aborted.hasContinuousFinalFallback)

        await sleep(nanoseconds: 200_000_000)
        #expect(harness.driver.requests.count == 1)
        let afterFallbackDeadline = harness.coordinator.diagnosticSnapshot
        #expect(afterFallbackDeadline.pendingDrawableSize == nil)
        #expect(!afterFallbackDeadline.finalCommitRequired)
        #expect(!afterFallbackDeadline.isContinuousInteraction)
        #expect(!afterFallbackDeadline.hasContinuousFinalFallback)
        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.inFlight == nil
            }
        )
        #expect(
            harness.coordinator.diagnosticSnapshot.committedDrawableSize
                == inFlightSize
        )
        #expect(harness.driver.requests.count == 1)
    }

    @Test
    @MainActor
    func `non-final layout cannot replace authoritative final queued behind interactive commit`()
        async
    {
        let finalSize = CGSize(width: 240, height: 144)
        let harness = makeHarness(
            timing: timing(cadence: 200_000_000, continuousFinal: 5_000_000_000)
        )

        harness.coordinator.requestResize(
            to: finalSize,
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        #expect(
            harness.coordinator.endContinuousInteraction(
                finalSize: finalSize,
                contentsScale: 1
            )
        )

        #expect(
            !harness.coordinator.requestResize(
                to: finalSize,
                contentsScale: 1,
                kind: .discrete
            )
        )
        let preserved = harness.coordinator.diagnosticSnapshot
        #expect(preserved.pendingDrawableSize == finalSize)
        #expect(preserved.geometryChangeKind == .final)
        #expect(preserved.finalCommitRequired)
        #expect(
            harness.diagnostics.events.contains(.authoritativeFinalPreserved)
        )

        harness.driver.completeFirst(with: true)
        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(harness.driver.requests[1].geometryChangeKind == .final)
        #expect(harness.driver.requests[1].drawableSize == finalSize)
        #expect(harness.driver.maximumConcurrentCommits == 1)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize
                    == finalSize
                    && !harness.coordinator.diagnosticSnapshot.finalCommitRequired
            }
        )
    }

    @Test
    @MainActor
    func `newer discrete scale remains authoritative behind in-flight commit`() async {
        let firstSize = CGSize(width: 200, height: 120)
        let originalFinalSize = CGSize(width: 240, height: 144)
        let harness = makeHarness(
            timing: timing(cadence: 200_000_000, continuousFinal: 5_000_000_000)
        )

        harness.coordinator.requestResize(
            to: firstSize,
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        #expect(
            harness.coordinator.endContinuousInteraction(
                finalSize: originalFinalSize,
                contentsScale: 1
            )
        )

        #expect(
            harness.coordinator.requestResize(
                to: originalFinalSize,
                contentsScale: 2,
                kind: .discrete
            )
        )
        let promoted = harness.coordinator.diagnosticSnapshot
        #expect(promoted.pendingDrawableSize == originalFinalSize)
        #expect(promoted.geometryChangeKind == .final)
        #expect(promoted.finalCommitRequired)

        harness.driver.completeFirst(with: true)
        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(harness.driver.requests[1].drawableSize == originalFinalSize)
        #expect(harness.driver.requests[1].contentsScale == 2)
        #expect(harness.driver.requests[1].geometryChangeKind == .final)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize
                    == originalFinalSize
                    && harness.coordinator.diagnosticSnapshot.committedContentsScale
                    == 2
                    && !harness.coordinator.diagnosticSnapshot.finalCommitRequired
            }
        )
    }

    @Test
    @MainActor
    func `animated transition retains drawable until completion`() async {
        let harness = makeHarness(
            timing: timing(animatedFallback: 500_000_000)
        )
        let retainedSize = harness.layer.drawableSize
        let finalSize = CGSize(width: 300, height: 180)

        harness.coordinator.requestResize(
            to: finalSize,
            contentsScale: 2,
            kind: .animatedTransition
        )
        await sleep(nanoseconds: 10_000_000)
        #expect(harness.driver.requests.isEmpty)
        #expect(harness.layer.drawableSize == retainedSize)
        #expect(harness.coordinator.diagnosticSnapshot.hasAnimatedFallback)

        harness.coordinator.completeAnimatedTransition(
            finalSize: finalSize,
            contentsScale: 2
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        #expect(harness.driver.requests[0].geometryChangeKind == .final)
        #expect(harness.layer.drawableSize == retainedSize)
        harness.driver.completeFirst(with: true)
    }

    @Test
    @MainActor
    func `animated transition fallback commits once when completion is missing`() async {
        let finalSize = CGSize(width: 300, height: 180)
        let harness = makeHarness(
            timing: timing(animatedFallback: 20_000_000),
            automaticResult: true
        )

        harness.coordinator.requestResize(
            to: finalSize,
            contentsScale: 1,
            kind: .animatedTransition
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        #expect(harness.driver.requests[0].geometryChangeKind == .final)

        harness.coordinator.completeAnimatedTransition(
            finalSize: finalSize,
            contentsScale: 1
        )
        await sleep(nanoseconds: 15_000_000)
        #expect(harness.driver.requests.count == 1)
        #expect(!harness.coordinator.diagnosticSnapshot.hasAnimatedFallback)
    }

    @Test
    @MainActor
    func `stale final marker cannot suppress a newer authoritative geometry`() async {
        let firstFinal = CGSize(width: 300, height: 180)
        let interveningSize = CGSize(width: 360, height: 216)
        let harness = makeHarness(
            timing: timing(discrete: 0),
            automaticResult: true
        )

        harness.coordinator.requestResize(
            to: firstFinal,
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })

        harness.coordinator.requestResize(
            to: interveningSize,
            contentsScale: 1,
            kind: .discrete
        )
        #expect(await eventually { harness.driver.requests.count == 2 })

        harness.coordinator.completeAnimatedTransition(
            finalSize: firstFinal,
            contentsScale: 1
        )
        #expect(await eventually { harness.driver.requests.count == 3 })
        #expect(harness.driver.requests[2].geometryChangeKind == .final)
        #expect(harness.driver.requests[2].drawableSize == firstFinal)
    }

    @Test
    @MainActor
    func `discrete layout burst coalesces promptly to its latest request`() async {
        let harness = makeHarness(
            timing: timing(discrete: 12_000_000),
            automaticResult: true
        )

        for size in [
            CGSize(width: 200, height: 120),
            CGSize(width: 220, height: 132),
            CGSize(width: 240, height: 144),
        ] {
            harness.coordinator.requestResize(
                to: size,
                contentsScale: 1,
                kind: .discrete
            )
        }

        await sleep(nanoseconds: 4_000_000)
        #expect(harness.driver.requests.isEmpty)
        #expect(await eventually { harness.driver.requests.count == 1 })
        #expect(
            harness.driver.requests[0].drawableSize
                == CGSize(width: 240, height: 144)
        )
    }

    @Test
    @MainActor
    func `failed resize restores committed scale without mutating drawable`() async {
        let harness = makeHarness()
        harness.layer.resetAssignments()
        let failedSize = CGSize(width: 260, height: 156)

        harness.coordinator.requestResize(
            to: failedSize,
            contentsScale: 2,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        #expect(harness.layer.drawableSize == defaultInitialSize)
        #expect(harness.layer.contentsScale == 2)

        await sleep(nanoseconds: 2_000_000)
        harness.driver.completeFirst(with: false)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.inFlight == nil
            }
        )
        let snapshot = harness.coordinator.diagnosticSnapshot
        #expect(snapshot.failedDrawableSize == failedSize)
        #expect(snapshot.committedDrawableSize == defaultInitialSize)
        #expect(snapshot.observedDrawableSize == defaultInitialSize)
        #expect(snapshot.contentsScale == 1)
        #expect(harness.layer.contentsScale == 1)
        #expect(harness.layer.assignments.isEmpty)
        #expect(harness.layer.contentsScaleAssignments.last?.contentsScale == 1)
        #expect(
            harness.layer.contentsScaleAssignments.last?
                .actionsWereDisabled == true
        )
        #expect(harness.diagnostics.events.contains(.rolledBack))
        #expect(harness.diagnostics.events.contains(.failed))
    }

    @Test
    @MainActor
    func `newer authoritative final retries after same geometry final fails`() async {
        let finalSize = CGSize(width: 260, height: 156)
        let harness = makeHarness()

        harness.coordinator.requestResize(
            to: finalSize,
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })

        harness.coordinator.requestResize(
            to: finalSize,
            contentsScale: 1,
            kind: .final
        )
        harness.driver.completeFirst(with: false)

        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(harness.driver.maximumConcurrentCommits == 1)
        #expect(harness.driver.requests[1].geometryChangeKind == .final)
        #expect(harness.driver.requests[1].drawableSize == finalSize)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize == finalSize
                    && !harness.coordinator.diagnosticSnapshot.finalCommitRequired
            }
        )
    }

    @Test
    @MainActor
    func `older final completion preserves newer animated fallback`() async {
        let firstFinal = CGSize(width: 260, height: 156)
        let newerAnimatedSize = CGSize(width: 320, height: 180)
        let harness = makeHarness(
            timing: timing(animatedFallback: 20_000_000)
        )

        harness.coordinator.requestResize(
            to: firstFinal,
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })

        harness.coordinator.requestResize(
            to: newerAnimatedSize,
            contentsScale: 1,
            kind: .animatedTransition
        )
        harness.driver.completeFirst(with: true)

        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(harness.driver.requests[1].geometryChangeKind == .final)
        #expect(harness.driver.requests[1].drawableSize == newerAnimatedSize)
        #expect(harness.driver.maximumConcurrentCommits == 1)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize
                    == newerAnimatedSize
                    && !harness.coordinator.diagnosticSnapshot.finalCommitRequired
            }
        )
    }

    @Test
    @MainActor
    func `older final completion preserves newer continuous trailing final`() async {
        let firstFinal = CGSize(width: 260, height: 156)
        let newerContinuousSize = CGSize(width: 320, height: 180)
        let harness = makeHarness(
            timing: timing(cadence: 0, continuousFinal: 20_000_000)
        )

        harness.coordinator.requestResize(
            to: firstFinal,
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })

        harness.coordinator.requestResize(
            to: newerContinuousSize,
            contentsScale: 1,
            kind: .continuousInteractive
        )
        harness.driver.completeFirst(with: true)

        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(
            harness.driver.requests[1].geometryChangeKind
                == .continuousInteractive
        )
        #expect(harness.driver.requests[1].drawableSize == newerContinuousSize)
        #expect(harness.coordinator.diagnosticSnapshot.finalCommitRequired)

        harness.driver.completeFirst(with: true)
        #expect(await eventually { harness.driver.requests.count == 3 })
        #expect(harness.driver.requests[2].geometryChangeKind == .final)
        #expect(harness.driver.requests[2].drawableSize == newerContinuousSize)
        #expect(harness.driver.maximumConcurrentCommits == 1)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                !harness.coordinator.diagnosticSnapshot.finalCommitRequired
            }
        )
    }

    @Test
    @MainActor
    func `failure does not perform a host drawable rollback`() async {
        let layer = RecordingMetalLayer()
        layer.contentsScale = 1
        layer.drawableSize = defaultInitialSize
        let layerAddress = MPVRenderSurfaceResizeCoordinator.layerAddress(of: layer)
        let failedSize = CGSize(width: 260, height: 156)
        var nativeAssignmentCount = 0
        let coordinator = MPVRenderSurfaceResizeCoordinator(
            commit: { request in
                // Simulate the native transaction writing the requested size,
                // failing, and restoring its last successful swapchain size.
                layer.drawableSize = request.drawableSize
                layer.drawableSize = defaultInitialSize
                nativeAssignmentCount = layer.assignments.count
                return false
            }
        )
        coordinator.activate(
            layer: layer,
            layerAddress: layerAddress,
            contentsScale: 1,
            committedSize: defaultInitialSize
        )
        layer.resetAssignments()

        coordinator.requestResize(
            to: failedSize,
            contentsScale: 2,
            kind: .final
        )
        #expect(
            await eventually {
                coordinator.diagnosticSnapshot.failedDrawableSize == failedSize
            }
        )

        #expect(nativeAssignmentCount == 2)
        #expect(layer.assignments.count == nativeAssignmentCount)
        #expect(layer.drawableSize == defaultInitialSize)
        #expect(layer.contentsScale == 1)
    }

    @Test
    @MainActor
    func `diagnostics measure request through acknowledgement latency`() async {
        let harness = makeHarness()
        harness.coordinator.requestResize(
            to: CGSize(width: 260, height: 156),
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })

        await sleep(nanoseconds: 3_000_000)
        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.resizeLatencyNanoseconds != nil
            }
        )

        let latency = harness.coordinator.diagnosticSnapshot
            .resizeLatencyNanoseconds
        #expect(latency != nil)
        #expect((latency ?? 0) >= 3_000_000)
        let commitDiagnostic = harness.diagnostics.snapshots.last {
            $0.event == .committed
        }
        #expect(commitDiagnostic?.resizeLatencyNanoseconds == latency)
    }

    @Test
    @MainActor
    func `invalid geometry cancels pending work without disturbing attachment or in-flight resize`()
        async
    {
        let harness = makeHarness(
            timing: timing(cadence: 5_000_000, discrete: 100_000_000)
        )

        harness.coordinator.requestResize(
            to: CGSize(width: 200, height: 120),
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        harness.coordinator.requestResize(
            to: CGSize(width: 300, height: 180),
            contentsScale: 1,
            kind: .continuousInteractive
        )

        for invalidSize in [
            CGSize.zero,
            CGSize(width: 1, height: 100),
            CGSize(width: CGFloat.infinity, height: 100),
            CGSize(width: 100, height: CGFloat.nan),
            CGSize(
                width: MPVMetalLayer.maximumDrawableDimension + 1,
                height: 100
            ),
            CGSize(
                width: 100,
                height: MPVMetalLayer.maximumDrawableDimension + 1
            ),
        ] {
            #expect(
                !harness.coordinator.requestResize(
                    to: invalidSize,
                    contentsScale: 1,
                    kind: .discrete
                )
            )
        }

        let snapshot = harness.coordinator.diagnosticSnapshot
        #expect(snapshot.activeLayerAddress == harness.layerAddress)
        #expect(snapshot.committedDrawableSize == defaultInitialSize)
        #expect(snapshot.pendingDrawableSize == nil)
        #expect(snapshot.inFlight != nil)
        #expect(!snapshot.hasScheduledCommit)

        harness.driver.completeFirst(with: true)
        await sleep(nanoseconds: 20_000_000)
        #expect(harness.driver.requests.count == 1)
        #expect(
            harness.coordinator.diagnosticSnapshot.committedDrawableSize
                == CGSize(width: 200, height: 120)
        )
    }

    @Test
    @MainActor
    func `failed in-flight resize still schedules newest pending geometry`() async {
        let harness = makeHarness(
            timing: timing(cadence: 5_000_000, continuousFinal: 500_000_000)
        )

        harness.coordinator.requestResize(
            to: CGSize(width: 200, height: 120),
            contentsScale: 1,
            kind: .continuousInteractive
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        harness.coordinator.requestResize(
            to: CGSize(width: 320, height: 180),
            contentsScale: 1,
            kind: .continuousInteractive
        )

        harness.driver.completeFirst(with: false)
        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(
            harness.driver.requests[1].drawableSize
                == CGSize(width: 320, height: 180)
        )
        #expect(harness.driver.maximumConcurrentCommits == 1)
        harness.driver.completeFirst(with: true)
        harness.coordinator.deactivate()
    }

    @Test
    @MainActor
    func `detach rejects stale completion and clears surface state`() async {
        let harness = makeHarness()

        harness.coordinator.requestResize(
            to: CGSize(width: 240, height: 144),
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        harness.coordinator.deactivate()

        let detached = harness.coordinator.diagnosticSnapshot
        #expect(detached.activeLayerAddress == nil)
        #expect(detached.committedDrawableSize == nil)
        #expect(detached.inFlight != nil)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.inFlight == nil
            }
        )
        #expect(harness.coordinator.diagnosticSnapshot.committedDrawableSize == nil)
        #expect(harness.diagnostics.events.contains(.staleCompletion))
    }

    @Test
    @MainActor
    func `superseding surface waits for stale operation before committing new generation`() async {
        let harness = makeHarness()
        harness.coordinator.requestResize(
            to: CGSize(width: 240, height: 144),
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })
        let oldRequest = harness.driver.requests[0]

        harness.coordinator.surfaceWasSuperseded()
        let replacementLayer = RecordingMetalLayer()
        let replacementInitial = CGSize(width: 150, height: 90)
        replacementLayer.drawableSize = replacementInitial
        let replacementAddress = MPVRenderSurfaceResizeCoordinator.layerAddress(
            of: replacementLayer
        )
        harness.coordinator.activate(
            layer: replacementLayer,
            layerAddress: replacementAddress,
            contentsScale: 2,
            committedSize: replacementInitial
        )
        harness.coordinator.requestResize(
            to: CGSize(width: 300, height: 180),
            contentsScale: 2,
            kind: .final
        )
        #expect(harness.driver.requests.count == 1)

        harness.driver.completeFirst(with: true)
        #expect(await eventually { harness.driver.requests.count == 2 })
        let newRequest = harness.driver.requests[1]
        #expect(newRequest.surfaceGeneration > oldRequest.surfaceGeneration)
        #expect(newRequest.layerAddress == replacementAddress)
        #expect(harness.diagnostics.events.contains(.staleCompletion))

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize
                    == CGSize(width: 300, height: 180)
            }
        )
    }

    @Test
    @MainActor
    func `layer replacement prevents old failure from mutating new layer`() async {
        let harness = makeHarness()
        harness.coordinator.requestResize(
            to: CGSize(width: 240, height: 144),
            contentsScale: 1,
            kind: .final
        )
        #expect(await eventually { harness.driver.requests.count == 1 })

        let replacementLayer = RecordingMetalLayer()
        let replacementInitial = CGSize(width: 180, height: 108)
        replacementLayer.drawableSize = replacementInitial
        let replacementAddress = MPVRenderSurfaceResizeCoordinator.layerAddress(
            of: replacementLayer
        )
        harness.coordinator.activate(
            layer: replacementLayer,
            layerAddress: replacementAddress,
            contentsScale: 1,
            committedSize: replacementInitial
        )
        harness.coordinator.requestResize(
            to: CGSize(width: 360, height: 216),
            contentsScale: 1,
            kind: .final
        )

        harness.driver.completeFirst(with: false)
        #expect(await eventually { harness.driver.requests.count == 2 })
        #expect(replacementLayer.drawableSize == replacementInitial)
        #expect(harness.coordinator.diagnosticSnapshot.failedDrawableSize == nil)

        harness.driver.completeFirst(with: true)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedDrawableSize
                    == CGSize(width: 360, height: 216)
            }
        )
    }

    @Test
    @MainActor
    func `renderer configuration change cancels scheduled resize until reactivation`() async {
        let harness = makeHarness(
            timing: timing(discrete: 40_000_000),
            automaticResult: true
        )
        harness.coordinator.requestResize(
            to: CGSize(width: 240, height: 144),
            contentsScale: 1,
            kind: .discrete
        )
        #expect(harness.coordinator.diagnosticSnapshot.hasScheduledCommit)

        harness.coordinator.rendererConfigurationDidChange()
        await sleep(nanoseconds: 60_000_000)
        #expect(harness.driver.requests.isEmpty)
        #expect(harness.coordinator.diagnosticSnapshot.activeLayerAddress == nil)
        #expect(
            harness.diagnostics.events.contains(.rendererConfigurationChanged)
        )
    }

    @Test
    @MainActor
    func `backing scale change is committed even when pixel dimensions match`() async {
        let harness = makeHarness(automaticResult: true)
        harness.coordinator.requestResize(
            to: defaultInitialSize,
            contentsScale: 2,
            kind: .discrete
        )

        #expect(await eventually { harness.driver.requests.count == 1 })
        #expect(harness.driver.requests[0].drawableSize == defaultInitialSize)
        #expect(harness.driver.requests[0].contentsScale == 2)
        #expect(
            await eventually {
                harness.coordinator.diagnosticSnapshot.committedContentsScale == 2
            }
        )
        #expect(harness.layer.contentsScale == 2)
    }

    @Test
    @MainActor
    func `commit leaves drawable write to renderer`() async {
        let layer = RecordingMetalLayer()
        layer.contentsScale = 1
        layer.drawableSize = defaultInitialSize
        let layerAddress = MPVRenderSurfaceResizeCoordinator.layerAddress(of: layer)
        let requestedSize = CGSize(width: 320, height: 180)
        var observedHostDrawableSize: CGSize?
        var observedHostContentsScale: CGFloat?
        var observedHostAssignments: [RecordingMetalLayer.Assignment] = []

        let coordinator = MPVRenderSurfaceResizeCoordinator(
            commit: { request in
                observedHostDrawableSize = layer.drawableSize
                observedHostContentsScale = layer.contentsScale
                observedHostAssignments = layer.assignments

                // Simulate MoltenVK replacing the swapchain and applying the
                // requested CAMetalLayer size inside the renderer commit.
                layer.drawableSize = request.drawableSize
                return layer.drawableSize == request.drawableSize
            }
        )
        coordinator.activate(
            layer: layer,
            layerAddress: layerAddress,
            contentsScale: 1,
            committedSize: defaultInitialSize
        )
        layer.resetAssignments()

        #expect(
            coordinator.requestResize(
                to: requestedSize,
                contentsScale: 2,
                kind: .final
            )
        )
        #expect(
            await eventually {
                coordinator.diagnosticSnapshot.committedDrawableSize == requestedSize
            }
        )

        #expect(observedHostDrawableSize == defaultInitialSize)
        #expect(observedHostContentsScale == 2)
        #expect(observedHostAssignments.isEmpty)
        #expect(layer.drawableSize == requestedSize)
        #expect(layer.contentsScale == 2)
        #expect(layer.assignments.count == 1)
        #expect(layer.assignments[0].drawableSize == requestedSize)
        #expect(!layer.assignments[0].actionsWereDisabled)
    }

    @Test
    @MainActor
    func `synchronized geometry does not rewrite drawable size`() async {
        let layer = RecordingMetalLayer()
        layer.contentsScale = 1
        layer.drawableSize = defaultInitialSize
        let layerAddress = MPVRenderSurfaceResizeCoordinator.layerAddress(of: layer)
        let diagnostics = ResizeDiagnosticRecorder()
        var commitCount = 0
        let coordinator = MPVRenderSurfaceResizeCoordinator(
            timing: timing(discrete: 0),
            commit: { _ in
                commitCount += 1
                return true
            },
            emitDiagnostic: { snapshot in
                diagnostics.snapshots.append(snapshot)
            }
        )
        coordinator.activate(
            layer: layer,
            layerAddress: layerAddress,
            contentsScale: 1,
            committedSize: defaultInitialSize
        )
        layer.resetAssignments()

        #expect(
            !coordinator.requestResize(
                to: defaultInitialSize,
                contentsScale: 1,
                kind: .discrete
            )
        )
        #expect(
            await eventually {
                diagnostics.events.contains(.alreadySynchronized)
            }
        )

        #expect(commitCount == 0)
        #expect(layer.drawableSize == defaultInitialSize)
        #expect(layer.contentsScale == 1)
        #expect(layer.assignments.isEmpty)
    }
}

private let defaultInitialSize = CGSize(width: 100, height: 60)

@MainActor
private struct ResizeCoordinatorHarness {
    let layer: RecordingMetalLayer
    let layerAddress: Int64
    let driver: ResizeCommitDriver
    let diagnostics: ResizeDiagnosticRecorder
    let coordinator: MPVRenderSurfaceResizeCoordinator
}

@MainActor
private func makeHarness(
    timing: MPVRenderSurfaceResizeCoordinator.Timing = timing(),
    automaticResult: Bool? = nil
) -> ResizeCoordinatorHarness {
    let layer = RecordingMetalLayer()
    layer.contentsScale = 1
    layer.drawableSize = defaultInitialSize
    let layerAddress = MPVRenderSurfaceResizeCoordinator.layerAddress(of: layer)
    let driver = ResizeCommitDriver(automaticResult: automaticResult)
    let diagnostics = ResizeDiagnosticRecorder()
    let coordinator = MPVRenderSurfaceResizeCoordinator(
        timing: timing,
        commit: { request in
            await driver.commit(request)
        },
        emitDiagnostic: { snapshot in
            diagnostics.snapshots.append(snapshot)
        }
    )
    coordinator.activate(
        layer: layer,
        layerAddress: layerAddress,
        contentsScale: 1,
        committedSize: defaultInitialSize
    )
    return ResizeCoordinatorHarness(
        layer: layer,
        layerAddress: layerAddress,
        driver: driver,
        diagnostics: diagnostics,
        coordinator: coordinator
    )
}

private func timing(
    cadence: UInt64 = 5_000_000,
    continuousFinal: UInt64 = 100_000_000,
    animatedFallback: UInt64 = 100_000_000,
    discrete: UInt64 = 5_000_000
) -> MPVRenderSurfaceResizeCoordinator.Timing {
    MPVRenderSurfaceResizeCoordinator.Timing(
        continuousCadenceNanoseconds: cadence,
        continuousTrailingDelayNanoseconds: continuousFinal,
        animatedTransitionFallbackDelayNanoseconds: animatedFallback,
        discreteCoalescingDelayNanoseconds: discrete
    )
}

@MainActor
private final class ResizeCommitDriver {
    private struct PendingCommit {
        let continuation: CheckedContinuation<Bool, Never>
    }

    let automaticResult: Bool?
    private(set) var requests: [MPVRenderSurfaceResizeCoordinator.CommitRequest] = []
    private(set) var submissionTimes: [UInt64] = []
    private(set) var maximumConcurrentCommits = 0
    private var concurrentCommits = 0
    private var pendingCommits: [PendingCommit] = []

    init(automaticResult: Bool?) {
        self.automaticResult = automaticResult
    }

    func commit(
        _ request: MPVRenderSurfaceResizeCoordinator.CommitRequest
    ) async -> Bool {
        requests.append(request)
        submissionTimes.append(DispatchTime.now().uptimeNanoseconds)
        concurrentCommits += 1
        maximumConcurrentCommits = max(maximumConcurrentCommits, concurrentCommits)

        if let automaticResult {
            concurrentCommits -= 1
            return automaticResult
        }

        return await withCheckedContinuation { continuation in
            pendingCommits.append(
                PendingCommit(
                    continuation: continuation
                )
            )
        }
    }

    func completeFirst(with result: Bool) {
        guard !pendingCommits.isEmpty else {
            Issue.record("Expected a pending resize commit")
            return
        }
        let pending = pendingCommits.removeFirst()
        concurrentCommits -= 1
        pending.continuation.resume(returning: result)
    }
}

@MainActor
private final class ResizeDiagnosticRecorder {
    var snapshots: [MPVRenderSurfaceResizeCoordinator.DiagnosticSnapshot] = []

    var events: [MPVRenderSurfaceResizeCoordinator.DiagnosticEvent] {
        snapshots.map(\.event)
    }
}

private final class RecordingMetalLayer: CAMetalLayer {
    struct Assignment {
        let drawableSize: CGSize
        let actionsWereDisabled: Bool
    }

    struct ContentsScaleAssignment {
        let contentsScale: CGFloat
        let actionsWereDisabled: Bool
    }

    private var recordedDrawableSize = CGSize.zero
    private var recordedContentsScale: CGFloat = 1
    private(set) var assignments: [Assignment] = []
    private(set) var contentsScaleAssignments: [ContentsScaleAssignment] = []

    override var drawableSize: CGSize {
        get { recordedDrawableSize }
        set {
            assignments.append(
                Assignment(
                    drawableSize: newValue,
                    actionsWereDisabled: CATransaction.disableActions()
                )
            )
            recordedDrawableSize = newValue
        }
    }

    override var contentsScale: CGFloat {
        get { recordedContentsScale }
        set {
            contentsScaleAssignments.append(
                ContentsScaleAssignment(
                    contentsScale: newValue,
                    actionsWereDisabled: CATransaction.disableActions()
                )
            )
            recordedContentsScale = newValue
        }
    }

    func resetAssignments() {
        assignments = []
        contentsScaleAssignments = []
    }
}

@MainActor
private func eventually(
    attempts: Int = 250,
    condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< attempts {
        if condition() {
            return true
        }
        await sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

private func sleep(nanoseconds: UInt64) async {
    try? await Task.sleep(nanoseconds: nanoseconds)
}
