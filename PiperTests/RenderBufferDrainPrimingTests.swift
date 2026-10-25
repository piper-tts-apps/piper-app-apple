// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// The priming cushion, pinned at the same drain seam as
/// RenderBufferDrainTests (FloatRingBuffer.drainForRender).
///
/// On devices where synthesis runs at ~realtime with jitter, even with
/// the full-size render contract the buffer drains to exactly 0 at
/// chunk boundaries and pulls pad silence mid-utterance as audible
/// dropouts. While a request is priming, pulls answer full-size
/// silence WITHOUT consuming until the priming threshold of audio is
/// buffered (or synthesis completes); the cushion then absorbs the
/// boundary jitter.
///
/// The AudioUnit's part is an isPriming flag per request (reset at
/// request begin and on cleanUp) and a threshold computed from the
/// output format's sample rate at request begin; these tests drive the
/// seam with exactly that bookkeeping. Fidelity boundary as in
/// RenderBufferDrainTests: PiperTests cannot link the extension
/// target, so the AudioUnit wiring itself is not under test here.
final class RenderBufferDrainPrimingTests: XCTestCase {

    // MARK: - Helpers

    /// Runs `body` against a fresh destination buffer of `frameCount`
    /// floats pre-filled with `fill`, then returns the buffer contents.
    @discardableResult
    private func withDestination(
        frameCount: Int,
        fill: Float = 0,
        _ body: (UnsafeMutablePointer<Float>) -> Void
    ) -> [Float] {
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        destination.initialize(repeating: fill, count: frameCount)
        defer {
            destination.deinitialize(count: frameCount)
            destination.deallocate()
        }
        body(destination)
        return Array(UnsafeBufferPointer(start: destination, count: frameCount))
    }

    private func pattern(_ count: Int) -> [Float] {
        (0..<count).map { Float($0 % 89) * 0.01 - 0.44 }
    }

    func testPrimingPullRendersFullSizeSilenceWithoutConsuming() {
        var ring = FloatRingBuffer()
        let waiting = pattern(100)
        ring.append(contentsOf: waiting)
        var outcome: RenderDrainOutcome?
        let contents = withDestination(frameCount: 512, fill: 9) { destination in
            outcome = ring.drainForRender(
                into: destination, frameCount: 512, synthesisCompleted: false,
                isPriming: true, primeThresholdFrames: 11025
            )
        }
        XCTAssertEqual(
            outcome, .primingSilence(byteSize: 512 * 4, buffered: 100),
            "below the cushion the pull is a priming-silence pull, not a drain"
        )
        XCTAssertTrue(contents.allSatisfy { $0 == 0 },
                      "a priming pull writes silence over the whole frame range, never stale content")
        XCTAssertEqual(ring.count, 100, "a priming pull consumes nothing")
        XCTAssertEqual(ring.snapshot, waiting, "the buffered samples stay queued for the latched drain")
    }

    func testPrimingStaysEngagedAcrossPullsBelowThreshold() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: pattern(600))
        for _ in 0..<3 {
            var outcome: RenderDrainOutcome?
            withDestination(frameCount: 256) { destination in
                outcome = ring.drainForRender(
                    into: destination, frameCount: 256, synthesisCompleted: false,
                    isPriming: true, primeThresholdFrames: 1024
                )
            }
            XCTAssertEqual(outcome, .primingSilence(byteSize: 256 * 4, buffered: 600),
                           "600 < 1024: still priming, pull after pull")
        }
        XCTAssertEqual(ring.count, 600, "no priming pull ever consumed a sample")
    }

    func testPrimingLatchesOffAtThresholdAndRendersRealSamples() {
        // Exactly at the threshold: the pull drains normally.
        var ring = FloatRingBuffer()
        let samples = pattern(1024)
        ring.append(contentsOf: samples)
        var outcome: RenderDrainOutcome?
        let contents = withDestination(frameCount: 256) { destination in
            outcome = ring.drainForRender(
                into: destination, frameCount: 256, synthesisCompleted: false,
                isPriming: true, primeThresholdFrames: 1024
            )
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 256, zeroFilled: 0, byteSize: 256 * 4, remaining: 768, isFinal: false),
            "reaching the threshold latches priming off on THIS pull - it renders real samples"
        )
        XCTAssertEqual(contents, Array(samples.prefix(256)))

        // Above the threshold but short of a full frame range: the latch
        // still renders what exists and zero-fills the rest (the normal
        // drain rules); it does not hold out for a full frameCount.
        var shortRing = FloatRingBuffer()
        shortRing.append(contentsOf: [Float](repeating: 0.5, count: 300))
        var shortOutcome: RenderDrainOutcome?
        withDestination(frameCount: 512) { destination in
            shortOutcome = shortRing.drainForRender(
                into: destination, frameCount: 512, synthesisCompleted: false,
                isPriming: true, primeThresholdFrames: 256
            )
        }
        XCTAssertEqual(
            shortOutcome,
            .rendered(copied: 300, zeroFilled: 212, byteSize: 512 * 4, remaining: 0, isFinal: false),
            "frameCount larger than the latched buffer: copy what exists, silence for the rest"
        )
    }

    func testCompletionBelowThresholdEndsPrimingAndCompletesOnce() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [Float](repeating: 0.5, count: 100))
        var outcome: RenderDrainOutcome?
        withDestination(frameCount: 256) { destination in
            outcome = ring.drainForRender(
                into: destination, frameCount: 256, synthesisCompleted: true,
                isPriming: true, primeThresholdFrames: 11025
            )
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 100, zeroFilled: 156, byteSize: 256 * 4, remaining: 0, isFinal: true),
            "synthesis completed below the threshold: priming ends and the final partial chunk renders at once"
        )
        var nextOutcome: RenderDrainOutcome?
        withDestination(frameCount: 256) { destination in
            nextOutcome = ring.drainForRender(
                into: destination, frameCount: 256, synthesisCompleted: true,
                isPriming: true, primeThresholdFrames: 11025
            )
        }
        XCTAssertEqual(nextOutcome, .complete, "completion is still signalled exactly once")
    }

    func testStarvationAfterLatchIsNormalZeroFillNotReprime() {
        // After the latch the AudioUnit passes isPriming = false; a
        // starved pull is then an ordinary full-size silence drain (the
        // underrun the summary counts), never another priming pull - and
        // partial data IS consumed, which a re-prime would refuse to do.
        var ring = FloatRingBuffer()
        var outcome: RenderDrainOutcome?
        withDestination(frameCount: 512) { destination in
            outcome = ring.drainForRender(
                into: destination, frameCount: 512, synthesisCompleted: false,
                isPriming: false, primeThresholdFrames: 11025
            )
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 0, zeroFilled: 512, byteSize: 512 * 4, remaining: 0, isFinal: false)
        )
        ring.append(contentsOf: [0.25, -0.5, 0.75])
        var partialOutcome: RenderDrainOutcome?
        withDestination(frameCount: 512) { destination in
            partialOutcome = ring.drainForRender(
                into: destination, frameCount: 512, synthesisCompleted: false,
                isPriming: false, primeThresholdFrames: 11025
            )
        }
        XCTAssertEqual(
            partialOutcome,
            .rendered(copied: 3, zeroFilled: 509, byteSize: 512 * 4, remaining: 0, isFinal: false),
            "post-latch pulls consume what exists - priming never re-engages within a request"
        )
    }

}
