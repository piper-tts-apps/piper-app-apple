// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

/// Shared helpers for the RenderPullWaiter test files. The helpers
/// mirror the AudioUnit's pull logic (wait, then drain) and are kept
/// here so no single test file exceeds the lint file-length limit.

/// Lock-guarded flag, so a background producer can flip it without
/// a captured-var data race under Swift 6.
final class WaiterFlag {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

/// Lock-guarded ring buffer, for the producer/consumer simulations.
final class WaiterSampleBox {
    private let lock = NSLock()
    private var ring = FloatRingBuffer()
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ring.count
    }
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ring.isEmpty
    }
    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        ring.append(contentsOf: samples)
    }
    func drain(
        frameCount: Int, synthesisCompleted: Bool, isPriming: Bool,
        primeThresholdFrames: Int, into destination: UnsafeMutablePointer<Float>
    ) -> RenderDrainOutcome {
        lock.lock()
        defer { lock.unlock() }
        return ring.drainForRender(
            into: destination, frameCount: frameCount,
            synthesisCompleted: synthesisCompleted, isPriming: isPriming,
            primeThresholdFrames: primeThresholdFrames)
    }
}

/// Drains one frame into a fresh destination and returns both the
/// outcome and the filled destination, mirroring a single AU pull.
func drainWaiterPull(
    box: WaiterSampleBox, frameCount: Int, completed: Bool,
    isPriming: Bool, primeThreshold: Int
) -> (outcome: RenderDrainOutcome, destination: [Float]) {
    var destination = [Float](repeating: 9, count: frameCount)
    let outcome = destination.withUnsafeMutableBufferPointer { buffer in
        box.drain(
            frameCount: frameCount, synthesisCompleted: completed,
            isPriming: isPriming, primeThresholdFrames: primeThreshold,
            into: buffer.baseAddress!)
    }
    return (outcome, destination)
}
