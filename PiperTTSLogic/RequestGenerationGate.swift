// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

/// Monotonic generation counter that invalidates stale async work.
///
/// Every new speech request (or cancel) bumps the generation. In-flight engine
/// callbacks and render passes capture the generation they started with and
/// drop their work once it no longer matches, so samples from a cancelled
/// request can never leak into the next one.
public final class RequestGenerationGate {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init() {}

    /// The latest generation. Thread-safe.
    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Starts a new generation, invalidating all previous ones. Returns the new value.
    @discardableResult
    public func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    /// Invalidates the current generation without starting a new request.
    public func cancel() {
        begin()
    }

    /// True while `generation` is still the current one.
    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation
    }

    /// Whether a chunk stamped with `producingGeneration` at production time may
    /// still be appended to the output queue of the request whose pinned
    /// generation is `activeGeneration`.
    ///
    /// True only while the producing request IS the active request and its
    /// generation has not been invalidated by a cancel or a newer request.
    /// Validating the live slot value instead (`isCurrent(activeGeneration)`
    /// evaluated at append time) cannot reject stale chunks: once a newer
    /// request begins, the slot holds the new generation, so the check passes
    /// for any chunk that arrives late - including one produced by the
    /// cancelled request.
    public func shouldAcceptChunk(producedUnder producingGeneration: UInt64, forActiveRequest activeGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return producingGeneration == activeGeneration && producingGeneration == generation
    }
}
