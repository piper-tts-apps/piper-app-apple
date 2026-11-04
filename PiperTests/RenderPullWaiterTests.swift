// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// The wait gate the AudioUnit uses BEFORE draining, for the offline
/// `write()` regression (Mark Bryant, 1.0.16): a starved pull must not
/// answer silence in a tight loop, because an offline host records every
/// pull into its file. The gate waits, bounded, until the buffer can
/// render, and the drain itself still never waits (see
/// RenderBufferDrainTests) and still always reports full-size byteSize.
///
/// Fidelity boundary: PiperTests cannot link the PiperTTS extension
/// target, so the AudioUnit's wiring of this gate is not under test
/// here; the gate and the tight-loop host simulation below are.
/// The simulation mirrors the AudioUnit's pull logic (wait, then drain) so
/// a regression in the gate shows up as recorded silence. A regression
/// that only removes the wait call inside the AudioUnit, without
/// touching the gate, would NOT be caught here; that wiring is covered
/// only by a real-AU run (PiperWriteTest on device).
final class RenderPullWaiterTests: XCTestCase {

    func testWaitReturnsImmediatelyWhenAlreadyReady() {
        let waiter = RenderPullWaiter()
        let start = Date()
        XCTAssertTrue(waiter.waitUntilReady(timeoutSeconds: 1.0) { true })
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testWaitWakesOnSignalWhenReadyBecomesTrue() {
        let waiter = RenderPullWaiter()
        let ready = WaiterFlag(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            ready.set(true)
            waiter.signal()
        }
        let start = Date()
        XCTAssertTrue(waiter.waitUntilReady(timeoutSeconds: 2.0) { ready.current })
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.04)
        XCTAssertLessThan(elapsed, 1.0, "signal must wake the wait promptly, not at the timeout")
    }

    func testWaitTimesOutWhenNeverReady() {
        let waiter = RenderPullWaiter()
        let start = Date()
        XCTAssertFalse(waiter.waitUntilReady(timeoutSeconds: 0.2) { false })
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.19)
        XCTAssertLessThan(elapsed, 1.0)
    }

    func testWaitNoticesReadyWithoutASignal() {
        // Completion and cancel do not always carry a chunk, so they do
        // not always signal. The slice re-check must notice them anyway.
        let waiter = RenderPullWaiter()
        let ready = WaiterFlag(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            ready.set(true)
            // Deliberately no signal().
        }
        let start = Date()
        XCTAssertTrue(waiter.waitUntilReady(timeoutSeconds: 2.0) { ready.current })
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testTightLoopHostRecordsNoSilenceBeforeFirstChunk() {
        // Mirror of the AudioUnit pull: wait, then drain. A producer
        // appends the first chunk after 100 ms. Without the wait, a
        // tight-loop host would record thousands of silence pulls in
        // that gap; with it, the first pull waits and drains real samples.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        let frameCount = 1024
        let primeThreshold = 275
        var isPriming = true

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            box.append([Float](repeating: 0.5, count: 4096))
            waiter.signal()
        }

        // The first pull: priming, buffer empty, synthesis unfinished.
        // It must wait, not return priming silence.
        let ready = waiter.waitUntilReady(timeoutSeconds: 2.0) {
            (isPriming && box.count >= primeThreshold) || (!isPriming && !box.isEmpty)
        }
        XCTAssertTrue(ready, "first chunk must arrive inside the timeout")
        let (outcome, _) = drainWaiterPull(
            box: box, frameCount: frameCount, completed: false,
            isPriming: isPriming, primeThreshold: primeThreshold)
        isPriming = outcome.isPrimingPull
        if case let .rendered(copied, _, _, _, _) = outcome {
            XCTAssertGreaterThan(copied, 0, "the first pull must drain real samples, not silence")
        } else {
            XCTFail("the first pull must not record silence while synthesis is producing, got \(outcome)")
        }
        XCTAssertFalse(isPriming, "the threshold pull latches priming off and drains")
    }

    func testPrimingWaitHoldsSamplesUntilThreshold() {
        // Buffer below threshold must not be drained early: the wait
        // holds until the threshold is reached, then the pull drains
        // from the very first sample.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        box.append([Float](repeating: 0.5, count: 100))
        let primeThreshold = 275
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            box.append([Float](repeating: 0.5, count: 200))
            waiter.signal()
        }
        let ready = waiter.waitUntilReady(timeoutSeconds: 2.0) { box.count >= primeThreshold }
        XCTAssertTrue(ready)
        let (outcome, _) = drainWaiterPull(
            box: box, frameCount: 1024, completed: false,
            isPriming: true, primeThreshold: primeThreshold)
        XCTAssertEqual(
            outcome,
            .rendered(copied: 300, zeroFilled: 724, byteSize: 1024 * 4, remaining: 0, isFinal: false))
    }

}
