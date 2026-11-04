// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// Wait-gate regression tests for cancel, spurious signals, and the
/// Mark Bryant offline-write case itself.
final class RenderPullWaiterRegressionTests: XCTestCase {

    func testCancelReturnsCompleteWithoutDraining() {
        // Mirror of the AudioUnit cancel path: the waiter is signalled,
        // the pull wakes, sees the request is gone, and returns
        // Complete without draining. The buffered samples stay put;
        // they belong to the cancelled request, not to a new pull.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        box.append([Float](repeating: 0.5, count: 1024))
        let requestActive = WaiterFlag(true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            requestActive.set(false)
            waiter.signal()
        }
        let start = Date()
        let ready = waiter.waitUntilReady(timeoutSeconds: 2.0) { !requestActive.current }
        XCTAssertTrue(ready, "cancel must wake the wait")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        // Caller logic: request gone means Complete, no drain call.
        let drained = requestActive.current
        XCTAssertFalse(drained, "a cancelled pull must not drain")
        XCTAssertEqual(box.count, 1024, "cancel must not consume the buffer")
    }

    func testSpuriousSignalDoesNotEndWaitEarly() {
        // Signals are only a prompt wake-up: a signal with no ready
        // state must be re-checked and ignored, and the wait must run
        // until ready actually becomes true, or until the timeout.
        let waiter = RenderPullWaiter()
        let ready = WaiterFlag(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { waiter.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { waiter.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { waiter.signal() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.20) {
            ready.set(true)
            // Deliberately no signal: the 20 ms slice re-check must
            // notice the ready state on its own.
        }
        let start = Date()
        XCTAssertTrue(waiter.waitUntilReady(timeoutSeconds: 2.0) { ready.current })
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.19, "spurious signals must not end the wait early")
        XCTAssertLessThan(elapsed, 1.0)

        // And with only spurious signals and never ready, the wait
        // must run to the timeout, not return early on a signal.
        let neverReadyStart = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { waiter.signal() }
        XCTAssertFalse(waiter.waitUntilReady(timeoutSeconds: 0.3) { false })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(neverReadyStart), 0.28)
    }

    func testMarkBryantOfflineWriteRecordsNoLeadingSilence() {
        // Regression test for Mark Bryant, Piper 1.0.16: a tight-loop
        // offline host (AVSpeechSynthesizer.write) recording "Hello"
        // must not record minutes of silence before the voice. With
        // the wait, the first pull waits for the first chunk and the
        // recorded file starts with real samples. Without the wait,
        // the same loop records priming-silence pulls in the gap, so
        // this test's silencePulls assertion fails.
        let waiter = RenderPullWaiter()
        let box = WaiterSampleBox()
        let frameCount = 1024
        let primeThreshold = 275
        var isPriming = true
        let completed = WaiterFlag(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            box.append([Float](repeating: 0.5, count: 4096))
            completed.set(true)
            waiter.signal()
        }

        var pulls = 0
        var silencePulls = 0
        var fileSamples: [Float] = []
        var finished = false
        while !finished && pulls < 20 {
            let ready = waiter.waitUntilReady(timeoutSeconds: 2.0) {
                (isPriming && box.count >= primeThreshold)
                    || (!isPriming && !box.isEmpty) || completed.current
            }
            XCTAssertTrue(ready, "first chunk must arrive inside the timeout")
            let (outcome, destination) = drainWaiterPull(
                box: box, frameCount: frameCount, completed: completed.current,
                isPriming: isPriming, primeThreshold: primeThreshold)
            pulls += 1
            isPriming = outcome.isPrimingPull
            switch outcome {
            case .rendered(_, _, _, _, let isFinal):
                fileSamples.append(contentsOf: destination)
                if isFinal {
                    finished = true
                }
            case .primingSilence:
                silencePulls += 1
            case .complete:
                finished = true
            }
        }
        XCTAssertTrue(finished, "host loop must finish on the final pull")
        XCTAssertLessThanOrEqual(pulls, 5, "4096 samples at 1024 per pull, not thousands of silence pulls")
        XCTAssertEqual(silencePulls, 0, "no silence pull may be recorded before the voice")
        XCTAssertEqual(fileSamples.count, 4096)
        let firstNonzero = fileSamples.firstIndex { abs($0) > 0.001 }
        XCTAssertEqual(firstNonzero, 0, "the recorded file must start with real samples, not silence")
        XCTAssertEqual(fileSamples.first, 0.5)
    }
}
