// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// Priming lifecycle and accounting, driven through
/// FloatRingBuffer.drainForRender the way PiperTTSAudioUnit drives it:
/// an isPriming flag passed into every pull, cleared by any outcome
/// that is not .primingSilence, reset at request begin. See
/// RenderBufferDrainPrimingTests for the pull-level contract.
final class RenderBufferDrainPrimingLifecycleTests: XCTestCase {

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
        XCTAssertEqual(RenderPriming.primeDurationSeconds, 0.0125)
        XCTAssertEqual(RenderPriming.thresholdFrames(sampleRate: 22050), 275)
        XCTAssertEqual(RenderPriming.thresholdFrames(sampleRate: 16000), 200)
        XCTAssertEqual(RenderPriming.thresholdFrames(sampleRate: 44100), 551)
    }
}
