// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

final class FloatRingBufferTests: XCTestCase {

    func testAppendAndCount() {
        var ring = FloatRingBuffer()
        XCTAssertTrue(ring.isEmpty)
        ring.append(contentsOf: [1, 2, 3])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.snapshot, [1, 2, 3])
    }

    func testRemoveFirst() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [1, 2, 3, 4, 5])
        ring.removeFirst(2)
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.snapshot, [3, 4, 5])
    }

    func testClear() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [1, 2, 3])
        ring.clear()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.count, 0)
    }

    func testWithUnsafeBufferPointer() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [10, 20, 30])
        let sum = ring.withUnsafeBufferPointer { buf in
            buf.reduce(0, +)
        }
        XCTAssertEqual(sum, 60)
    }

    // MARK: - appendUpToMax: explicit truncation, oldest samples never dropped

    func testAppendUpToMaxArrayKeepsOldest() {
        var ring = FloatRingBuffer()
        let dropped = ring.appendUpToMax(contentsOf: [1, 2, 3, 4, 5], maxCount: 3)
        XCTAssertEqual(dropped, 2, "Newest excess must be reported as dropped")
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.snapshot, [1, 2, 3], "Oldest samples must be preserved")
    }

    func testAppendUpToMaxArrayNoOverflow() {
        var ring = FloatRingBuffer()
        let dropped = ring.appendUpToMax(contentsOf: [1, 2, 3], maxCount: 3)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(ring.snapshot, [1, 2, 3])
    }

    func testAppendUpToMaxArrayWhenFullDropsAllNew() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [1, 2, 3])
        let dropped = ring.appendUpToMax(contentsOf: [4, 5], maxCount: 3)
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(ring.snapshot, [1, 2, 3])
    }

    func testAppendUpToMaxBufferPointerKeepsOldest() {
        var ring = FloatRingBuffer()
        let src: [Float] = [10, 20, 30, 40]
        var dropped = 0
        src.withUnsafeBufferPointer { buf in
            dropped = ring.appendUpToMax(contentsOf: buf, maxCount: 2)
        }
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring.snapshot, [10, 20])
    }

    func testAppendUpToMaxNeverExceedsCap() {
        var ring = FloatRingBuffer()
        let initial = (0..<800).map { Float($0) }
        ring.append(contentsOf: initial)
        let dropped = ring.appendUpToMax(contentsOf: [Float](repeating: 10000, count: 100), maxCount: 800)
        XCTAssertEqual(dropped, 100)
        XCTAssertEqual(ring.count, 800, "Buffer must stay capped")
        let snap = ring.snapshot
        XCTAssertEqual(snap.first, 0, "Oldest sample must be intact")
        XCTAssertEqual(snap.last, 799)
        XCTAssertFalse(snap.contains(10000), "Newest excess must not displace buffered audio")
    }

    func testAppendUpToMaxAt120sCap() {
        var ring = FloatRingBuffer()
        let maxCount = 22050 * 120
        ring.append(contentsOf: [Float](repeating: 1.0, count: maxCount - 50))
        let dropped = ring.appendUpToMax(contentsOf: [Float](repeating: 2.0, count: 100), maxCount: maxCount)
        XCTAssertEqual(dropped, 50)
        XCTAssertEqual(ring.count, maxCount)
        XCTAssertTrue(ring.snapshot.suffix(50).allSatisfy { $0 == 2.0 })
        XCTAssertEqual(ring.snapshot.first, 1.0, "Oldest samples must survive the cap")
    }

    func testCopyFirstIntoDestination() {
        var ring = FloatRingBuffer()
        ring.append(contentsOf: [1, 2, 3, 4])
        var dest = [Float](repeating: 0, count: 2)
        dest.withUnsafeMutableBufferPointer { destBuf in
            ring.copyFirst(into: destBuf.baseAddress!, count: 2)
        }
        XCTAssertEqual(dest, [1, 2])
        XCTAssertEqual(ring.count, 4)
    }

    func testCompactDoesNotLoseData() {
        var ring = FloatRingBuffer()
        // Fill and drain to force head > 1024 threshold
        for _ in 0..<5 {
            ring.append(contentsOf: [Float](repeating: 1, count: 500))
            ring.removeFirst(400)
        }
        XCTAssertFalse(ring.isEmpty)
        // snapshot should match withUnsafeBufferPointer
        let snap = ring.snapshot
        let bufSum = ring.withUnsafeBufferPointer { $0.reduce(0, +) }
        XCTAssertEqual(Float(snap.count), bufSum)
    }

    func testAppendSlice() {
        var ring = FloatRingBuffer()
        let full = [1, 2, 3, 4, 5] as [Float]
        ring.append(contentsOf: full[1...3])
        XCTAssertEqual(ring.snapshot, [2, 3, 4])
    }

    // MARK: - 1.0.12 regression guards (120s)

    func testAppendLarge120s() {
        var ring = FloatRingBuffer()
        let sampleRate = 22050
        let maxSamples = sampleRate * 120 // 2_646_000
        // Use chunked append to avoid single 10MB alloc in one go on CI
        let chunk = [Float](repeating: 0.9, count: sampleRate * 10)
        for _ in 0..<12 {
            ring.append(contentsOf: chunk)
        }
        XCTAssertEqual(ring.count, maxSamples)
        XCTAssertGreaterThan(ring.count, 110_250, "Must hold more than old 5s limit")
    }
}
