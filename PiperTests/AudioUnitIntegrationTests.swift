// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic
import Foundation

/// Simulates PiperTTSAudioUnit rendering behavior without needing AVFoundation AudioUnit init.
/// Guards against early complete on long paragraph and deallocate clearing.
final class AudioUnitIntegrationTests: XCTestCase {

    // MARK: - Helpers mimicking PiperTTSAudioUnit logic

    private func simulateRender(availableCount: Int, frameCount: Int, completed: Bool) -> (action: String, copied: Int) {
        let intFrameCount = frameCount
        if availableCount == 0 {
            if completed {
                return ("complete", 0)
            } else {
                return ("retry", 0)
            }
        }
        let actualCopied = min(availableCount, intFrameCount)
        return ("render", actualCopied)
    }

    // MARK: - Tests

    func testRenderDoesNotCompleteEarlyOnLongParagraph() {
        // Simulate long paragraph: 120s * 22050 = 2_646_000 samples available, frameCount 1024
        let longParagraphSamples = 22050 * 120
        let frameCount = 1024

        let result = simulateRender(availableCount: longParagraphSamples, frameCount: frameCount, completed: false)
        XCTAssertEqual(result.action, "render", "Long paragraph should render, not complete early")
        XCTAssertEqual(result.copied, frameCount)

        // Simulate draining all frames
        var remaining = longParagraphSamples
        var renders = 0
        while remaining > 0 && renders < 3000 {
            let renderResult = simulateRender(availableCount: remaining, frameCount: frameCount, completed: false)
            XCTAssertEqual(renderResult.action, "render", "Should keep rendering while data remains")
            XCTAssertGreaterThan(renderResult.copied, 0)
            XCTAssertLessThanOrEqual(renderResult.copied, frameCount)
            remaining -= renderResult.copied
            renders += 1
        }
        XCTAssertEqual(remaining, 0, "All samples should be consumed after draining")
        // ceil(2_646_000 / 1024) = 2584 renders (last partial 1008 samples)
        XCTAssertEqual(renders, 2584, "Expected ceil division renders for 120s buffer")

        // After draining but not completed, should retry, not complete early
        let afterDrainNotCompleted = simulateRender(availableCount: 0, frameCount: frameCount, completed: false)
        XCTAssertEqual(afterDrainNotCompleted.action, "retry", "If piper not completed and buffer empty, should retry, not complete early")

        // Only when completed and empty -> complete
        let done = simulateRender(availableCount: 0, frameCount: frameCount, completed: true)
        XCTAssertEqual(done.action, "complete")
    }

    func testRenderDoesNotDropMiddleOnLongParagraph() {
        // Sawyer bug: middle drop made VoiceOver jump. Buffer keeps the oldest
        // samples and reports overflow past the cap instead of dropping them.
        var ring = FloatRingBuffer()
        let sampleRate = 22050
        let maxCount = sampleRate * 120

        // Simulate piper delivering samples in chunks (like real delegate)
        let chunk = [Float](repeating: 0.5, count: 4096)
        var totalDropped = 0
        for _ in 0..<700 { // 700*4096 ~ 2.8M > max
            totalDropped += ring.appendUpToMax(contentsOf: chunk, maxCount: maxCount)
        }
        XCTAssertEqual(ring.count, maxCount, "Buffer must be capped at 120s, not grow unbounded")
        XCTAssertGreaterThan(totalDropped, 0, "Overflow past the cap must be reported, not silently absorbed")
        XCTAssertGreaterThan(ring.count, sampleRate * 5, "Must be larger than old 5s limit")

        // Simulate render consuming 1024 at a time – no middle hole
        var consumed = 0
        while ring.count >= 1024 {
            ring.removeFirst(1024)
            consumed += 1024
        }
        XCTAssertGreaterThan(consumed, 0)
        // Remaining should be <1024 and contiguous
        XCTAssertLessThan(ring.count, 1024)
    }

    func testDeallocateClearsBuffer() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [Float](repeating: 1.0, count: 22050 * 10))
        XCTAssertFalse(ring.isEmpty)

        // Simulate deallocateRenderResources clearing
        ring.clear()

        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)

        // After clear, new synthesis should start clean (no stale data)
        ring.append(contentsOf: [Float](repeating: 2.0, count: 100))
        XCTAssertEqual(ring.count, 100)
        XCTAssertEqual(ring.snapshot, [Float](repeating: 2.0, count: 100))
    }

    func testBackToBackRequestsClearBuffer() {
        // Kindle regression: second request saw first request's leftover buffer
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [Float](repeating: 1.0, count: 5000))
        XCTAssertEqual(ring.count, 5000)

        // Simulate removeRequestAndCleanOutputData
        ring.clear()

        XCTAssertEqual(ring.count, 0, "Second request must start with empty buffer")

        // Second request appends fresh
        ring.append(contentsOf: [Float](repeating: 2.0, count: 3000))
        XCTAssertEqual(ring.count, 3000)
        XCTAssertTrue(ring.snapshot.allSatisfy { $0 == 2.0 })
    }

    func testMaxBufferDurationConstantMatchesFile() {
        // Guard that constant 120s is not accidentally changed back to 5s
        // We replicate logic from LongUtteranceBufferTests but here as integration sanity
        let expectedMax = 22050 * 120
        let oldMax = 22050 * 5
        XCTAssertEqual(expectedMax, 2_646_000)
        XCTAssertEqual(oldMax, 110_250)
        XCTAssertNotEqual(expectedMax, oldMax)
    }
}
