// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// Guards the explicit truncation policy: when buffered audio hits the 120s
/// cap, the request is truncated loudly instead of silently dropping the
/// oldest samples.
final class SpeechRequestTruncationTests: XCTestCase {

    // MARK: - Tracker state machine

    func testBeginsInProgress() {
        let tracker = SpeechRequestTracker()
        XCTAssertEqual(tracker.outcome, .inProgress)
    }

    func testRecordOverflowWithZeroKeepsInProgress() {
        var tracker = SpeechRequestTracker()
        XCTAssertFalse(tracker.recordOverflow(droppedSamples: 0))
        XCTAssertEqual(tracker.outcome, .inProgress)
    }

    func testRecordOverflowTruncatesExactlyOnce() {
        var tracker = SpeechRequestTracker()
        XCTAssertTrue(tracker.recordOverflow(droppedSamples: 128))
        XCTAssertEqual(tracker.outcome, .truncated(droppedSamples: 128))
        XCTAssertFalse(tracker.recordOverflow(droppedSamples: 64))
        XCTAssertEqual(tracker.outcome, .truncated(droppedSamples: 128))
    }

    func testCancelFromInProgress() {
        var tracker = SpeechRequestTracker()
        tracker.cancel()
        XCTAssertEqual(tracker.outcome, .cancelled)
    }

    func testCancelAfterTruncatedKeepsTruncated() {
        var tracker = SpeechRequestTracker()
        XCTAssertTrue(tracker.recordOverflow(droppedSamples: 10))
        tracker.cancel()
        XCTAssertEqual(tracker.outcome, .truncated(droppedSamples: 10))
    }

    func testCompleteFromInProgress() {
        var tracker = SpeechRequestTracker()
        tracker.complete()
        XCTAssertEqual(tracker.outcome, .completed)
    }

    func testCompleteAfterTruncatedKeepsTruncated() {
        var tracker = SpeechRequestTracker()
        XCTAssertTrue(tracker.recordOverflow(droppedSamples: 10))
        tracker.complete()
        XCTAssertEqual(tracker.outcome, .truncated(droppedSamples: 10))
    }

    func testBeginResetsToInProgress() {
        var tracker = SpeechRequestTracker()
        tracker.cancel()
        tracker.begin()
        XCTAssertEqual(tracker.outcome, .inProgress)
    }

    func testIsTruncatedFlag() {
        XCTAssertFalse(SpeechRequestOutcome.inProgress.isTruncated)
        XCTAssertFalse(SpeechRequestOutcome.completed.isTruncated)
        XCTAssertFalse(SpeechRequestOutcome.cancelled.isTruncated)
        XCTAssertTrue(SpeechRequestOutcome.truncated(droppedSamples: 1).isTruncated)
    }

    // MARK: - Render-loop completion decision

    func testShouldCompleteRenderingWhileDraining() {
        let tracker = SpeechRequestTracker()
        XCTAssertFalse(tracker.shouldCompleteRendering(availableSamples: 100,
                                                       engineCompleted: false,
                                                       requestActive: true))
    }

    func testShouldCompleteRenderingWhenEngineDoneAndBufferEmpty() {
        let tracker = SpeechRequestTracker()
        XCTAssertTrue(tracker.shouldCompleteRendering(availableSamples: 0,
                                                      engineCompleted: true,
                                                      requestActive: true))
    }

    func testShouldCompleteRenderingWhenRequestGone() {
        var tracker = SpeechRequestTracker()
        tracker.cancel()
        XCTAssertTrue(tracker.shouldCompleteRendering(availableSamples: 100,
                                                      engineCompleted: false,
                                                      requestActive: false))
    }

    func testShouldCompleteRenderingWhenTruncatedAndDrained() {
        // piper.cancel() makes engineCompleted false, so truncation must
        // complete on its own outcome once the buffer drains.
        var tracker = SpeechRequestTracker()
        XCTAssertTrue(tracker.recordOverflow(droppedSamples: 10))
        XCTAssertTrue(tracker.shouldCompleteRendering(availableSamples: 0,
                                                      engineCompleted: false,
                                                      requestActive: true))
        XCTAssertFalse(tracker.shouldCompleteRendering(availableSamples: 100,
                                                       engineCompleted: false,
                                                       requestActive: true))
    }

    func testShouldNotCompleteRenderingWhileWaitingForEngine() {
        let tracker = SpeechRequestTracker()
        XCTAssertFalse(tracker.shouldCompleteRendering(availableSamples: 0,
                                                      engineCompleted: false,
                                                      requestActive: true))
    }

    // MARK: - Buffer cap composition

    func testBufferCapTriggersTruncationOutcome() {
        var ring = FloatRingBuffer()
        var tracker = SpeechRequestTracker()
        let maxCount = 1000
        let chunk = [Float](repeating: 0.5, count: 300)
        var truncations = 0
        for _ in 0..<5 {
            let dropped = ring.appendUpToMax(contentsOf: chunk, maxCount: maxCount)
            if tracker.recordOverflow(droppedSamples: dropped) {
                truncations += 1
            }
        }
        XCTAssertEqual(truncations, 1, "Truncation is decided exactly once")
        XCTAssertEqual(tracker.outcome, .truncated(droppedSamples: 200))
        XCTAssertEqual(ring.count, maxCount, "Buffer stays capped, never grows unbounded")
        XCTAssertTrue(ring.snapshot.allSatisfy { $0 == 0.5 }, "Buffered audio keeps the oldest samples")
    }
}
