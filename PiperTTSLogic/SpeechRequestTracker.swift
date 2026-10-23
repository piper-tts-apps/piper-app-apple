// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

/// Explicit outcome of a speech request's audio buffering.
///
/// Replaces the old silent policy of discarding the oldest samples when the
/// bounded buffer filled up: hitting the cap now truncates the request loudly
/// and the outcome stays visible to the render loop and completion handling.
public enum SpeechRequestOutcome: Equatable {
    /// Request is actively buffering audio.
    case inProgress
    /// Request rendered all of its audio normally.
    case completed
    /// Buffering hit the capacity cap; the request was truncated instead of
    /// silently dropping the oldest samples. Carries the number of samples
    /// that arrived after the cap and were not stored.
    case truncated(droppedSamples: Int)
    /// Request was cancelled before finishing.
    case cancelled
}

public extension SpeechRequestOutcome {
    /// Whether the request was truncated at the buffer cap.
    var isTruncated: Bool {
        if case .truncated = self { return true }
        return false
    }
}

/// Tracks a speech request's buffering outcome.
///
/// Not thread-safe; the owner serializes access (PiperTTSAudioUnit guards it
/// with its output data lock).
public struct SpeechRequestTracker {
    public private(set) var outcome: SpeechRequestOutcome = .inProgress

    public init() {}

    /// Starts tracking a new request.
    public mutating func begin() {
        outcome = .inProgress
    }

    /// Records samples that arrived after the buffer cap was reached.
    /// - Returns: true only for the first overflow, the moment the request is truncated.
    @discardableResult
    public mutating func recordOverflow(droppedSamples: Int) -> Bool {
        guard droppedSamples > 0 else { return false }
        guard case .inProgress = outcome else { return false }
        outcome = .truncated(droppedSamples: droppedSamples)
        return true
    }

    /// Marks the request cancelled. Terminal outcomes are kept.
    public mutating func cancel() {
        guard case .inProgress = outcome else { return }
        outcome = .cancelled
    }

    /// Marks the request completed. Terminal outcomes are kept.
    public mutating func complete() {
        guard case .inProgress = outcome else { return }
        outcome = .completed
    }

    /// Whether the render loop should finish the request now.
    ///
    /// A truncated request completes once its buffered audio drains, even
    /// though the engine was cancelled (so `engineCompleted` stays false).
    public func shouldCompleteRendering(availableSamples: Int,
                                        engineCompleted: Bool,
                                        requestActive: Bool) -> Bool {
        if !requestActive { return true }
        guard availableSamples == 0 else { return false }
        if engineCompleted { return true }
        if case .truncated = outcome { return true }
        return false
    }
}
