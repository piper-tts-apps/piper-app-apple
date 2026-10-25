// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// Issue #94 bug 1 - HIGH voices echo on devices where synthesis runs
/// slower than realtime.
///
/// The old doPerformRender answered a starved pull by BLOCKING the render
/// thread in pauseUntil (up to 2 s per pull, pumping a run loop) and
/// recursing up to 400 deep; when the retries exhausted it returned a
/// SHORT buffer (mDataByteSize below the requested frame count) with a
/// plain Render flag. The host's reaction to those short/stalled renders
/// is the echo's trigger: 39 "Rendering in progress no data" retries fired
/// inside a single traced play whose own sample accounting was exact.
///
/// These tests pin the replacement contract at the drain seam
/// (FloatRingBuffer.drainForRender), the decision the AudioUnit's render
/// block is built on: a pull during an active request ALWAYS returns a
/// full-size render immediately - real samples first, silence for the
/// shortfall - and completion is signalled exactly once.
///
/// Fidelity boundary: PiperTests cannot link the PiperTTS extension
/// target, so the AudioUnit's flag/byteSize wiring is not under test here;
/// the drain outcome carries byteSize and isFinal precisely so the whole
/// decision is. The wiring is verified by the device protocol (no
/// "Rendering in progress no data" lines, request summary underrun
/// counts, no echo).
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
        // The numbers the AURequestTrace summary accumulates per pull:
        // zeroFilledFrames must equal frameCount - available, exactly.
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

    // MARK: - Priming cushion
    //
    // Follow-up to the underrun fix: on Ihor's phone HIGH synthesis runs
    // at ~realtime with jitter, so even with full-size renders the buffer
    // drained to exactly 0 at most chunk boundaries and 52 pulls padded
    // silence mid-utterance (gen=25 summary: zeroFilledFrames=22,759).
    // The priming cushion holds the start of each request silent -
    // consuming nothing - until 0.5 s of audio is buffered (or synthesis
    // completes), so the boundary jitter lands in the cushion instead.
    // These tests pin that decision at the same drain seam; the
    // AudioUnit's part (an isPriming flag reset per request, the
    // threshold computed from the output format's sample rate at request
    // begin) is driven here exactly the way the unit drives it.

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

    func testPrimingLifecycleLatchStarvationAndNextRequestReprimes() {
        // The full per-request lifecycle, driven the way the AudioUnit
        // drives it: an isPriming flag passed into every pull, cleared by
        // any outcome that is not .primingSilence, reset at request begin.
        var ring = FloatRingBuffer()
        var auIsPriming = true
        let threshold = 1024

        func pull(completed: Bool) -> RenderDrainOutcome {
            var outcome: RenderDrainOutcome?
            withDestination(frameCount: 256) { destination in
                outcome = ring.drainForRender(
                    into: destination, frameCount: 256, synthesisCompleted: completed,
                    isPriming: auIsPriming, primeThresholdFrames: threshold
                )
            }
            guard let outcome else {
                XCTFail("the drain always produces an outcome")
                return .complete
            }
            switch outcome {
            case .primingSilence:
                break // still priming: the AudioUnit flag stays set
            default:
                auIsPriming = false
            }
            return outcome
        }

        ring.append(contentsOf: [Float](repeating: 0.5, count: 600))
        XCTAssertEqual(pull(completed: false), .primingSilence(byteSize: 256 * 4, buffered: 600))
        XCTAssertTrue(auIsPriming)
        XCTAssertEqual(ring.count, 600)

        ring.append(contentsOf: [Float](repeating: 0.5, count: 424))
        XCTAssertEqual(
            pull(completed: false),
            .rendered(copied: 256, zeroFilled: 0, byteSize: 256 * 4, remaining: 768, isFinal: false),
            "600 + 424 = 1024 = threshold: this pull latches and renders"
        )
        XCTAssertFalse(auIsPriming)

        // Drain the rest, then starve: ordinary zero-fill, no re-prime.
        while !ring.isEmpty { _ = pull(completed: false) }
        XCTAssertEqual(
            pull(completed: false),
            .rendered(copied: 0, zeroFilled: 256, byteSize: 256 * 4, remaining: 0, isFinal: false)
        )
        XCTAssertFalse(auIsPriming, "priming must not re-engage mid-request")

        // Cancel during priming reaches the same seam state as any end:
        // the next request's begin resets the flag, and it re-primes.
        XCTAssertEqual(pull(completed: true), .complete)
        auIsPriming = true
        ring.append(contentsOf: [Float](repeating: -0.25, count: 100))
        XCTAssertEqual(
            pull(completed: false), .primingSilence(byteSize: 256 * 4, buffered: 100),
            "a new request primes again from scratch"
        )
        XCTAssertEqual(ring.count, 100)
    }

    func testPrimingAndUnderrunAccountingStaySeparate() {
        // The classification PiperTTSAudioUnit applies to each outcome
        // for the request summary: .primingSilence feeds primingPulls /
        // primingFrames (frameCount per pull); a .rendered shortfall
        // feeds zeroFilledPulls / zeroFilledFrames. The tracer itself
        // lives in the extension target, which PiperTests cannot link, so
        // this pins the classification at the outcome level - exactly
        // where the AudioUnit's switch performs it - and the device
        // protocol verifies the summary line end to end.
        var ring = FloatRingBuffer()
        var auIsPriming = true
        let frameCount = 256
        let threshold = 1024
        var primingPulls = 0
        var primingFrames = 0
        var zeroFilledPulls = 0
        var zeroFilledFrames = 0

        func pull(completed: Bool) -> RenderDrainOutcome {
            var outcome: RenderDrainOutcome?
            withDestination(frameCount: frameCount) { destination in
                outcome = ring.drainForRender(
                    into: destination, frameCount: frameCount, synthesisCompleted: completed,
                    isPriming: auIsPriming, primeThresholdFrames: threshold
                )
            }
            guard let outcome else {
                XCTFail("the drain always produces an outcome")
                return .complete
            }
            switch outcome {
            case .primingSilence:
                primingPulls += 1
                primingFrames += frameCount
            case let .rendered(_, zeroFilled, _, _, _):
                auIsPriming = false
                if zeroFilled > 0 {
                    zeroFilledPulls += 1
                    zeroFilledFrames += zeroFilled
                }
            case .complete:
                auIsPriming = false
            }
            return outcome
        }

        ring.append(contentsOf: [Float](repeating: 0.5, count: 600))
        _ = pull(completed: false)
        _ = pull(completed: false)
        XCTAssertEqual(primingPulls, 2)
        XCTAssertEqual(primingFrames, 2 * frameCount)
        XCTAssertEqual(zeroFilledPulls, 0, "priming silence is NOT underrun - it precedes the speech")
        XCTAssertEqual(zeroFilledFrames, 0)

        // Latch (1024 buffered), drain to empty, starve once: exactly one
        // underrun pull, and the priming counters never move again.
        ring.append(contentsOf: [Float](repeating: 0.5, count: 424))
        while !ring.isEmpty { _ = pull(completed: false) }
        _ = pull(completed: false)
        XCTAssertEqual(primingPulls, 2)
        XCTAssertEqual(primingFrames, 2 * frameCount)
        XCTAssertEqual(zeroFilledPulls, 1)
        XCTAssertEqual(zeroFilledFrames, frameCount)
    }

    func testShortUtteranceUnderThresholdPlaysToCompletion() {
        // A one-line utterance synthesizes completely (300 frames, far
        // under the 11025-frame cushion) BEFORE the first pull arrives:
        // it must play immediately - priming must not hold finished
        // audio - and every sample renders exactly once, with completion
        // signalled exactly once.
        var ring = FloatRingBuffer()
        let samples = pattern(300)
        ring.append(contentsOf: samples)
        var rendered: [Float] = []
        var finals = 0

        func pull() -> RenderDrainOutcome {
            var outcome: RenderDrainOutcome?
            let contents = withDestination(frameCount: 256) { destination in
                outcome = ring.drainForRender(
                    into: destination, frameCount: 256, synthesisCompleted: true,
                    isPriming: true, primeThresholdFrames: 11025
                )
            }
            guard let outcome else {
                XCTFail("the drain always produces an outcome")
                return .complete
            }
            if case let .rendered(copied, _, _, _, isFinal) = outcome {
                rendered.append(contentsOf: contents.prefix(copied))
                if isFinal { finals += 1 }
            }
            return outcome
        }

        XCTAssertEqual(
            pull(),
            .rendered(copied: 256, zeroFilled: 0, byteSize: 256 * 4, remaining: 44, isFinal: false),
            "completed synthesis bypasses priming even far below the threshold"
        )
        XCTAssertEqual(
            pull(),
            .rendered(copied: 44, zeroFilled: 212, byteSize: 256 * 4, remaining: 0, isFinal: true)
        )
        XCTAssertEqual(pull(), .complete)
        XCTAssertEqual(rendered, samples, "the whole short utterance, exactly once, in order")
        XCTAssertEqual(finals, 1, "completion signalled exactly once")
    }

    func testPrimeThresholdConversion() {
        XCTAssertEqual(RenderPriming.primeDurationSeconds, 0.5)
        XCTAssertEqual(RenderPriming.thresholdFrames(sampleRate: 22050), 11025)
        XCTAssertEqual(RenderPriming.thresholdFrames(sampleRate: 16000), 8000)
        XCTAssertEqual(RenderPriming.thresholdFrames(sampleRate: 44100), 22050)
    }
}
