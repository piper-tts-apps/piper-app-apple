// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

/// Efficient ring buffer to replace ContiguousArray<Float> + removeFirst(O(n))
public struct FloatRingBuffer {
    private var buffer: [Float] = []
    private var head: Int = 0

    public init() {}

    public var count: Int {
        buffer.count - head
    }

    public var isEmpty: Bool {
        // swiftlint:disable:next empty_count
        count == 0
    }

    public mutating func append(contentsOf newElements: [Float]) {
        buffer.append(contentsOf: newElements)
        maybeCompact()
    }

    public mutating func append(contentsOf newElements: ArraySlice<Float>) {
        buffer.append(contentsOf: newElements)
        maybeCompact()
    }

    public mutating func append(contentsOf newElements: UnsafeBufferPointer<Float>) {
        buffer.append(contentsOf: newElements)
        maybeCompact()
    }

    public mutating func removeFirst(_ countToRemove: Int) {
        precondition(countToRemove <= count, "removeFirst beyond count")
        head += countToRemove
        if head > 1024 && head > buffer.count / 2 {
            compact()
        }
    }

    public mutating func clear() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }

    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        try buffer.withUnsafeBufferPointer { ptr in
            if head >= buffer.count {
                let empty = UnsafeBufferPointer<Float>(start: nil, count: 0)
                return try body(empty)
            }
            let base = ptr.baseAddress!.advanced(by: head)
            let buf = UnsafeBufferPointer(start: base, count: count)
            return try body(buf)
        }
    }

    public func copyFirst(into destination: UnsafeMutablePointer<Float>, count elementsCount: Int) {
        precondition(elementsCount <= count)
        withUnsafeBufferPointer { src in
            guard elementsCount > 0 else { return }
            destination.update(from: src.baseAddress!, count: elementsCount)
        }
    }

    /// Appends samples without exceeding `maxCount`.
    ///
    /// The oldest samples are never discarded: only the newest excess that
    /// does not fit is dropped, so callers can surface the truncation
    /// explicitly instead of silently losing the beginning of the audio.
    /// - Returns: the number of samples that did not fit and were dropped.
    @discardableResult
    public mutating func appendUpToMax(contentsOf newElements: [Float], maxCount: Int) -> Int {
        let room = max(0, maxCount - count)
        let fittingCount = min(room, newElements.count)
        if fittingCount > 0 {
            append(contentsOf: newElements.prefix(fittingCount))
        }
        return newElements.count - fittingCount
    }

    /// Appends samples without exceeding `maxCount`.
    ///
    /// The oldest samples are never discarded: only the newest excess that
    /// does not fit is dropped, so callers can surface the truncation
    /// explicitly instead of silently losing the beginning of the audio.
    /// - Returns: the number of samples that did not fit and were dropped.
    @discardableResult
    public mutating func appendUpToMax(contentsOf newElements: UnsafeBufferPointer<Float>, maxCount: Int) -> Int {
        let room = max(0, maxCount - count)
        let fittingCount = min(room, newElements.count)
        if fittingCount > 0, let baseAddress = newElements.baseAddress {
            append(contentsOf: UnsafeBufferPointer(start: baseAddress, count: fittingCount))
        }
        return newElements.count - fittingCount
    }

    private mutating func compact() {
        if head > 0 {
            buffer.removeFirst(head)
            head = 0
        }
    }

    private mutating func maybeCompact() {
        if head > 4096 && head * 2 > buffer.count {
            compact()
        }
    }

    public var snapshot: [Float] {
        if isEmpty { return [] }
        return Array(buffer[head..<buffer.count])
    }
}
