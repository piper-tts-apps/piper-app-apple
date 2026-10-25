// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// The render-drain contract, pinned at the seam the AudioUnit's
/// render block is built on (FloatRingBuffer.drainForRender): a pull
/// during an active request ALWAYS returns a full-size render
/// immediately - real samples first, silence for the shortfall - and
/// completion is signalled exactly once.
///
/// The contract exists because the previous render path answered a
/// starved pull by waiting on the render thread and then returning a
/// short buffer (mDataByteSize below the requested frame count); a host
/// that re-pulls the same timestamp in response doubles the audio,
/// which is the echo heard on devices where synthesis runs near
/// realtime.
///
/// Fidelity boundary: PiperTests cannot link the PiperTTS extension
/// target, so the AudioUnit's flag/byteSize wiring is not under test
/// here; the drain outcome carries byteSize and isFinal precisely so
/// the whole decision is.
final class RenderBufferDrainTests: XCTestCase {

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

    // MARK: - Starved pulls

    func testStarvedPullRendersFullSizeSilence() {
        var ring = FloatRingBuffer()
        var outcome: RenderDrainOutcome?
        let contents = withDestination(frameCount: 512) { destination in
            outcome = ring.drainForRender(into: destination, frameCount: 512, synthesisCompleted: false)
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 0, zeroFilled: 512, byteSize: 512 * 4, remaining: 0, isFinal: false),
            "a starved pull must still report the FULL byteSize - a short buffer is the echo trigger"
        )
        XCTAssertTrue(contents.allSatisfy { $0 == 0 }, "a starved pull renders silence, never stale samples")
        XCTAssertEqual(ring.count, 0)
    }

    func testPartialPullCopiesAvailableAndZeroFillsTail() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [0.25, -0.5, 0.75])
        var outcome: RenderDrainOutcome?
        let contents = withDestination(frameCount: 8) { destination in
            outcome = ring.drainForRender(into: destination, frameCount: 8, synthesisCompleted: false)
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 3, zeroFilled: 5, byteSize: 8 * 4, remaining: 0, isFinal: false)
        )
        XCTAssertEqual(contents, [0.25, -0.5, 0.75, 0, 0, 0, 0, 0],
                       "real samples first, silence for exactly the shortfall")
        XCTAssertEqual(ring.count, 0, "the pull consumes exactly the samples it copied")
    }

    func testUnderrunAccountingMatchesShortfall() {
        // The underrun accounting a caller accumulates per pull:
        // zeroFilled must equal frameCount - available, exactly.
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [Float](repeating: 0.5, count: 100))
        var outcome: RenderDrainOutcome?
        withDestination(frameCount: 471) { destination in
            outcome = ring.drainForRender(into: destination, frameCount: 471, synthesisCompleted: false)
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 100, zeroFilled: 371, byteSize: 471 * 4, remaining: 0, isFinal: false)
        )
    }

    // MARK: - Full pulls

    func testFullPullCopiesExactlyFrameCount() {
        var ring = FloatRingBuffer()
        let samples = pattern(1000)
        ring.append(contentsOf: samples)
        var outcome: RenderDrainOutcome?
        let contents = withDestination(frameCount: 256) { destination in
            outcome = ring.drainForRender(into: destination, frameCount: 256, synthesisCompleted: false)
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 256, zeroFilled: 0, byteSize: 256 * 4, remaining: 744, isFinal: false)
        )
        XCTAssertEqual(contents, Array(samples.prefix(256)))
        XCTAssertEqual(ring.snapshot, Array(samples.suffix(744)),
                       "unrendered samples stay queued, in order")
    }

    // MARK: - Completion

    func testCompletedAndDrainedSignalsCompleteWithoutTouchingBuffer() {
        var ring = FloatRingBuffer()
        var outcome: RenderDrainOutcome?
        let contents = withDestination(frameCount: 256, fill: 9) { destination in
            outcome = ring.drainForRender(into: destination, frameCount: 256, synthesisCompleted: true)
        }
        XCTAssertEqual(outcome, .complete,
                       "completed + drained is the one pull that produces no render")
        XCTAssertTrue(contents.allSatisfy { $0 == 9 },
                      "the completion pull must not write into the output buffer")
    }

    func testFinalPartialChunkCompletesOnTheSamePull() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [Float](repeating: 0.5, count: 100))
        var outcome: RenderDrainOutcome?
        let contents = withDestination(frameCount: 256) { destination in
            outcome = ring.drainForRender(into: destination, frameCount: 256, synthesisCompleted: true)
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 100, zeroFilled: 156, byteSize: 256 * 4, remaining: 0, isFinal: true),
            "the final partial chunk completes WITH its render (RHVoice-style), not via a later empty pull"
        )
        XCTAssertEqual(Array(contents.prefix(100)), [Float](repeating: 0.5, count: 100))
        XCTAssertTrue(contents.suffix(156).allSatisfy { $0 == 0 })

        // Completion is signalled exactly once: the next pull is a plain
        // completed-and-drained pull, and no sample is ever rendered twice.
        var nextOutcome: RenderDrainOutcome?
        withDestination(frameCount: 256) { destination in
            nextOutcome = ring.drainForRender(into: destination, frameCount: 256, synthesisCompleted: true)
        }
        XCTAssertEqual(nextOutcome, .complete)
    }

    func testNotCompletedDrainToEmptyIsNotFinal() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [Float](repeating: 0.5, count: 100))
        var outcome: RenderDrainOutcome?
        withDestination(frameCount: 256) { destination in
            outcome = ring.drainForRender(into: destination, frameCount: 256, synthesisCompleted: false)
        }
        XCTAssertEqual(
            outcome,
            .rendered(copied: 100, zeroFilled: 156, byteSize: 256 * 4, remaining: 0, isFinal: false),
            "an emptied buffer mid-synthesis is an underrun, not a completion"
        )
    }

    // MARK: - Timing: a pull never waits

    func testStarvedPullsReturnImmediately() {
        // The old render path blocked up to 2 s on ONE starved pull
        // (pauseUntil: 5000 us x 400) and recursed. The drain must answer
        // every pull immediately; 2000 starved pulls stay far under the
        // old single-pull worst case.
        var ring = FloatRingBuffer()
        var mismatches = 0
        let start = Date()
        for _ in 0..<2000 {
            var outcome: RenderDrainOutcome?
            withDestination(frameCount: 512) { destination in
                outcome = ring.drainForRender(into: destination, frameCount: 512, synthesisCompleted: false)
            }
            if outcome != .rendered(copied: 0, zeroFilled: 512, byteSize: 512 * 4, remaining: 0, isFinal: false) {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0, "every starved pull must render full-size silence")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0,
                          "2000 starved pulls took \(elapsed) s - the drain must never wait for synthesis")
    }

    // MARK: - Streamed synthesis accounting

    func testStreamedChunksRenderExactlyOnceInOrder() {
        // Mirrors the device-capture invariant: across an utterance whose
        // chunks arrive WHILE pulls are running, every appended sample is
        // rendered exactly once, in order, and every pull is full-size.
        var ring = FloatRingBuffer()
        let frameCount = 471
        var rendered: [Float] = []
        var sawFinal = false

        func pull(completed: Bool) -> RenderDrainOutcome {
            var drained: RenderDrainOutcome?
            let contents = withDestination(frameCount: frameCount) { destination in
                drained = ring.drainForRender(into: destination, frameCount: frameCount, synthesisCompleted: completed)
            }
            guard let outcome = drained else {
                XCTFail("the drain always produces an outcome")
                return .complete
            }
            if case let .rendered(copied, _, byteSize, _, isFinal) = outcome {
                XCTAssertEqual(byteSize, frameCount * 4, "every pull is full-size")
                rendered.append(contentsOf: contents.prefix(copied))
                sawFinal = sawFinal || isFinal
            }
            return outcome
        }

        ring.append(contentsOf: [Float](repeating: 0.5, count: 6144))
        for _ in 0..<5 { _ = pull(completed: false) }
        ring.append(contentsOf: [Float](repeating: -0.25, count: 6144))

        var lastOutcome: RenderDrainOutcome?
        var guardCounter = 0
        while !ring.isEmpty && guardCounter < 100 {
            lastOutcome = pull(completed: false)
            guardCounter += 1
        }
        XCTAssertEqual(rendered.count, 12288, "each appended sample rendered exactly once")
        XCTAssertEqual(Array(rendered.prefix(6144)), [Float](repeating: 0.5, count: 6144))
        XCTAssertEqual(Array(rendered.suffix(6144)), [Float](repeating: -0.25, count: 6144))
        XCTAssertNotEqual(lastOutcome, .complete, "not completed while synthesis is unfinished")

        // Synthesis finishes with the buffer drained: exactly one
        // completion, and it carries no samples.
        XCTAssertEqual(pull(completed: true), .complete)
        XCTAssertFalse(sawFinal, "no pull was final - the buffer drained before completion was known")
    }
}
