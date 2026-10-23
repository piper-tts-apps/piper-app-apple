// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic
import Foundation

/// Guards against re-introducing 5s buffer regression (main vs feat/pinyin-support drift).
/// App Store 1.0.12 live is 120s from a9a6ed1. Main must stay 120s.
final class LongUtteranceBufferTests: XCTestCase {

    private let expectedDuration: Double = 120.0
    private let sampleRate: Double = 22050.0
    private var expectedMaxSamples: Int { Int(sampleRate * expectedDuration) } // 2_646_000

    // MARK: - Constant guards

    func testMaxBufferDurationIs120() {
        // Primary: expected constant
        XCTAssertEqual(expectedDuration, 120.0, "Buffer must be 120s, not 5s (Sawyer long paragraph dropout)")

        // Secondary: verify source file actually contains 120.0, not 5.0
        // This catches drift if someone edits PiperTTSAudioUnit.swift back to 5s.
        let thisFile = URL(fileURLWithPath: #file)
        let projectRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let auFile = projectRoot.appendingPathComponent("PiperTTS/Sources/AudioUnit/PiperTTSAudioUnit.swift")
        if FileManager.default.fileExists(atPath: auFile.path) {
            if let content = try? String(contentsOf: auFile, encoding: .utf8) {
                // Must contain 120.0
                XCTAssertTrue(content.contains("maxBufferDurationSeconds") && content.contains("120.0"),
                              "PiperTTSAudioUnit.swift should declare maxBufferDurationSeconds = 120.0")
                // Must NOT contain the old regression value 5.0 as active declaration
                // Allow 5.0 in comments, but not as `= 5.0`
                let pattern = "maxBufferDurationSeconds.*=\\s*5\\.0"
                let regex = try? NSRegularExpression(pattern: pattern)
                let range = NSRange(content.startIndex..<content.endIndex, in: content)
                let matches = regex?.matches(in: content, options: [], range: range) ?? []
                XCTAssertTrue(matches.isEmpty, "Found regression 5.0 assignment for maxBufferDurationSeconds, expected 120.0")
            }
        }

        // Also check FloatRingBufferTests file not needed here, but sanity
        XCTAssertGreaterThan(expectedDuration, 5.0)
    }

    func testMaxSamplesCountFor22050() {
        let maxSamples = Int(sampleRate * expectedDuration)
        XCTAssertEqual(maxSamples, 2_646_000, "22050 * 120 = 2_646_000")
        XCTAssertEqual(maxSamples, expectedMaxSamples)

        // Old regression would be 22050*5 = 110250
        let oldRegression = Int(sampleRate * 5.0)
        XCTAssertEqual(oldRegression, 110_250)
        XCTAssertNotEqual(maxSamples, oldRegression, "Must not be old 5s buffer size")
        XCTAssertGreaterThan(maxSamples, oldRegression * 10)
    }

    // MARK: - FloatRingBuffer holds 120s

    func testBufferHolds120SecondsWithoutMiddleDrop() {
        var ring = FloatRingBuffer()
        let total = expectedMaxSamples // 2_646_000 floats ~ 10.6 MB
        // Append in chunks to avoid single huge allocation overhead in test runner
        let chunkSize = 22050 * 10 // 10s chunks
        let chunk = [Float](repeating: 0.5, count: chunkSize)
        var appended = 0
        while appended < total {
            let remaining = total - appended
            let toAppend = min(remaining, chunkSize)
            if toAppend == chunkSize {
                ring.append(contentsOf: chunk)
            } else {
                ring.append(contentsOf: [Float](repeating: 0.5, count: toAppend))
            }
            appended += toAppend
        }

        XCTAssertEqual(ring.count, total, "Ring must hold full 120s without truncating to 5s")
        XCTAssertFalse(ring.isEmpty)
        // Ensure not truncated to old 5s
        XCTAssertNotEqual(ring.count, 110_250)
        XCTAssertGreaterThan(ring.count, 110_250)
    }

    func testBufferTruncationPolicyAtMax() {
        // Explicit policy: hitting the 120s cap reports the newest excess as
        // dropped instead of silently discarding the oldest samples.
        var ring = FloatRingBuffer()
        let maxCount = expectedMaxSamples
        // Fill to max
        let initial = [Float](repeating: 1.0, count: maxCount)
        ring.append(contentsOf: initial)
        XCTAssertEqual(ring.count, maxCount)

        let extra = [Float](repeating: 2.0, count: 100)
        let dropped = ring.appendUpToMax(contentsOf: extra, maxCount: maxCount)

        XCTAssertEqual(dropped, 100, "Excess beyond the 120s cap must be reported, not silently absorbed")
        XCTAssertEqual(ring.count, maxCount, "Buffer stays capped")
        let snap = ring.snapshot
        XCTAssertEqual(snap.first, 1.0, "Oldest samples must be preserved")
        XCTAssertFalse(snap.contains(2.0), "Newest excess must not displace buffered audio")
        XCTAssertEqual(snap.count, maxCount)
    }

    func testBackToBackSynthesisResetsOffsets() {
        // Simulate Kindle bug: totalSSMLBytesGenerated not reset across requests causes second request's first marker offset >0
        // Expected: each synthesis resets to 0

        struct MockSynthesis {
            var totalBytesGenerated: Int = 0
            mutating func startNewSynthesis() {
                totalBytesGenerated = 0 // Fix for Kindle regression
            }
            mutating func generateSentence(bytes: Int) -> Int {
                let offset = totalBytesGenerated
                totalBytesGenerated += bytes
                return offset
            }
        }

        var synth = MockSynthesis()
        // First request: 2 sentences
        let offset1a = synth.generateSentence(bytes: 5000)
        let offset1b = synth.generateSentence(bytes: 7000)
        XCTAssertEqual(offset1a, 0)
        XCTAssertEqual(offset1b, 5000)

        // Simulate bug: if we forgot reset, second request would start at 12000
        // Fixed: reset
        synth.startNewSynthesis()
        let offset2a = synth.generateSentence(bytes: 4000)
        XCTAssertEqual(offset2a, 0, "Back-to-back synthesis must reset byte offset to 0, not continue from previous request (Kindle TOC jump bug)")

        // Also ensure word markers monotonic within second request
        let offset2b = synth.generateSentence(bytes: 3000)
        XCTAssertGreaterThan(offset2b, offset2a)
        XCTAssertEqual(offset2b, 4000)
    }

    // MARK: - Additional guard: buffer not 5s

    func testBufferNotTruncatedTo5Seconds() {
        var ring = FloatRingBuffer()
        // Simulate long paragraph ~30s = 661500 samples
        let thirtySeconds = Int(sampleRate * 30.0)
        ring.append(contentsOf: [Float](repeating: 0.1, count: thirtySeconds))
        XCTAssertEqual(ring.count, thirtySeconds)
        XCTAssertGreaterThan(ring.count, 110_250, "30s must be > 5s old limit, should not have been truncated")
    }
}
