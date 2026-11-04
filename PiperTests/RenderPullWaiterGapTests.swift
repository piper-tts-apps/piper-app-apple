// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// Wait-gate regression tests for gaps and stalls: a pull that lands
/// in a producer gap must wait, not record silence, and a stalled
/// synthesis must fall back to at most one silence pull per timeout.
final class RenderPullWaiterGapTests: XCTestCase {

    func testMidUtteranceGapRecordsNoSilencePulls() {
        // First chunk, then a producer gap, then a second chunk. The
        // pull that lands in the gap must wait for the second chunk
        // and drain it, not record a silence pull in the meantime.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        let frameCount = 1024
        let primeThreshold = 275
        var isPriming = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            box.append([Float](repeating: 0.5, count: 4096))
            waiter.signal()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
            box.append([Float](repeating: 0.75, count: 4096))
            waiter.signal()
        }

        var pulls = 0
        var silencePulls = 0
        var copiedTotal = 0
        while copiedTotal < 8192 && pulls < 20 {
            let ready = waiter.waitUntilReady(timeoutSeconds: 2.0) {
                (isPriming && box.count >= primeThreshold) || (!isPriming && !box.isEmpty)
            }
            XCTAssertTrue(ready, "next chunk must arrive inside the timeout")
            let (outcome, _) = drainWaiterPull(
                box: box, frameCount: frameCount, completed: false,
                isPriming: isPriming, primeThreshold: primeThreshold)
            pulls += 1
            isPriming = outcome.isPrimingPull
            if case let .rendered(copied, _, _, _, _) = outcome {
                copiedTotal += copied
            } else {
                silencePulls += 1
            }
        }
        XCTAssertEqual(copiedTotal, 8192, "both chunks must be drained in full")
        XCTAssertEqual(pulls, 8, "each chunk is 4 pulls of 1024, no extra pulls in the gap")
        XCTAssertEqual(silencePulls, 0, "the gap must record no silence pulls")
    }

    func testStallPastTimeoutFallsBackToOneSilencePullPerTimeout() {
        // A stalled synthesis must not spin: each timeout produces at
        // most one full-size silence pull, then the next pull waits
        // again. When the chunk finally arrives, it is recovered intact.
        // A short test timeout stands in for the AudioUnit's 5 s
        // timeout, so the test stays fast; the rate, not the 5 s, is
        // what is asserted here.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        let frameCount = 1024
        let timeout = 0.25
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            box.append([Float](repeating: 0.5, count: 2048))
            waiter.signal()
        }

        var silencePulls = 0
        let start = Date()
        var recovered = false
        while silencePulls < 10 && !recovered {
            let ready = waiter.waitUntilReady(timeoutSeconds: timeout) { !box.isEmpty }
            if ready {
                let (outcome, destination) = drainWaiterPull(
                    box: box, frameCount: frameCount, completed: false,
                    isPriming: false, primeThreshold: 0)
                if case let .rendered(copied, _, _, _, _) = outcome {
                    XCTAssertGreaterThan(copied, 0)
                    XCTAssertEqual(destination[0], 0.5, "recovered chunk starts at its first sample")
                    recovered = true
                } else {
                    XCTFail("recovery pull must drain real samples, got \(outcome)")
                }
            } else {
                let (outcome, destination) = drainWaiterPull(
                    box: box, frameCount: frameCount, completed: false,
                    isPriming: false, primeThreshold: 0)
                if case let .rendered(copied, zeroFilled, byteSize, _, _) = outcome {
                    XCTAssertEqual(copied, 0)
                    XCTAssertEqual(zeroFilled, frameCount)
                    XCTAssertEqual(byteSize, frameCount * 4, "fallback silence stays full-size")
                    XCTAssertTrue(destination.allSatisfy { $0 == 0 })
                    silencePulls += 1
                } else {
                    XCTFail("timeout fallback must be a rendered silence pull, got \(outcome)")
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(recovered, "chunk must arrive and be recovered after the stall")
        XCTAssertGreaterThanOrEqual(elapsed, 0.75, "stall must span several timeouts")
        XCTAssertGreaterThanOrEqual(silencePulls, 3, "a 1 s stall at 0.25 s timeouts must yield several fallbacks")
        XCTAssertLessThanOrEqual(silencePulls, 5, "one silence pull per timeout, never a tight loop of them")
    }

    func testPrimingBoundary274HoldsAnd275Drains() {
        // The threshold is count >= 275: one frame below it must hold
        // in both the wait and the drain, one frame at it must drain.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        let primeThreshold = 275
        box.append([Float](repeating: 0.5, count: 274))
        let below = waiter.waitUntilReady(timeoutSeconds: 0.2) { box.count >= primeThreshold }
        XCTAssertFalse(below, "274 frames must not satisfy the 275-frame threshold")
        let (held, _) = drainWaiterPull(
            box: box, frameCount: 1024, completed: false,
            isPriming: true, primeThreshold: primeThreshold)
        if case let .primingSilence(_, buffered) = held {
            XCTAssertEqual(buffered, 274, "priming drain consumes nothing below threshold")
        } else {
            XCTFail("below threshold the drain must answer priming silence, got \(held)")
        }
        XCTAssertEqual(box.count, 274, "nothing is consumed below threshold")

        box.append([Float](repeating: 0.5, count: 1))
        let atThreshold = waiter.waitUntilReady(timeoutSeconds: 1.0) { box.count >= primeThreshold }
        XCTAssertTrue(atThreshold, "275 frames must satisfy the threshold immediately")
        let (drained, _) = drainWaiterPull(
            box: box, frameCount: 1024, completed: false,
            isPriming: true, primeThreshold: primeThreshold)
        XCTAssertEqual(
            drained,
            .rendered(copied: 275, zeroFilled: 749, byteSize: 1024 * 4, remaining: 0, isFinal: false))
        XCTAssertFalse(drained.isPrimingPull, "the threshold pull latches priming off")
    }

    func testNonPrimingSingleSampleDrainsImmediately() {
        // Once priming has latched off, any sample is enough: the wait
        // must not hold for a threshold, and the drain must not pad
        // the pull with a priming-silence answer.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        box.append([0.5])
        let start = Date()
        let ready = waiter.waitUntilReady(timeoutSeconds: 1.0) { !box.isEmpty }
        XCTAssertTrue(ready)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        let (outcome, _) = drainWaiterPull(
            box: box, frameCount: 1024, completed: false,
            isPriming: false, primeThreshold: 0)
        XCTAssertEqual(
            outcome,
            .rendered(copied: 1, zeroFilled: 1023, byteSize: 1024 * 4, remaining: 0, isFinal: false))
    }
}
