// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

/// Outcome of a single render pull against the synthesis buffer.
///
/// The render contract (issue #94 bug 1): while a request is active a pull
/// ALWAYS produces a full-size render - `byteSize` is the full
/// `frameCount * 4`, with any shortfall reported as `zeroFilled` silence
/// frames - and it produces it immediately, without waiting for synthesis.
/// A short buffer (byteSize below the requested frame count) invites the
/// host to re-pull the same timestamp, which is what doubled the audio.
public enum RenderDrainOutcome: Equatable {
    /// Synthesis is complete and the buffer is already drained: the caller
    /// signals completion without touching the output buffer.
    case complete
    /// The pull rendered a full-size buffer: `copied` real samples followed
    /// by `zeroFilled` silence frames. `remaining` is the number of samples
    /// left in the buffer after the pull. `isFinal` is true when this pull
    /// copied the last samples of a completed synthesis, so the caller
    /// signals completion together with this render instead of waiting for
    /// one more empty pull.
    case rendered(copied: Int, zeroFilled: Int, byteSize: Int, remaining: Int, isFinal: Bool)
}

extension FloatRingBuffer {
    /// Drains up to `frameCount` samples into `destination`, zero-filling
    /// the rest of the frame range, and reports exactly what the pull did.
    ///
    /// `synthesisCompleted` is the producer's completion state sampled by
    /// the caller at pull entry; the buffer count is read here, under the
    /// caller's lock, so copy + removeFirst stay one atomic step.
    public mutating func drainForRender(
        into destination: UnsafeMutablePointer<Float>,
        frameCount: Int,
        synthesisCompleted: Bool
    ) -> RenderDrainOutcome {
        if synthesisCompleted && isEmpty {
            return .complete
        }
        let copied = min(count, frameCount)
        if copied > 0 {
            copyFirst(into: destination, count: copied)
            removeFirst(copied)
        }
        let zeroFilled = frameCount - copied
        if zeroFilled > 0 {
            destination.advanced(by: copied).update(repeating: 0, count: zeroFilled)
        }
        // The full-size guarantee: byteSize always covers the whole frame
        // range (real samples + silence), never just the copied prefix.
        // When this pull drained the last samples of a completed synthesis
        // it is also the final one, so completion rides along with the
        // render (RHVoice-style) instead of needing a later empty pull.
        return .rendered(
            copied: copied,
            zeroFilled: zeroFilled,
            byteSize: frameCount * MemoryLayout<Float>.size,
            remaining: count,
            isFinal: synthesisCompleted && isEmpty
        )
    }
}
