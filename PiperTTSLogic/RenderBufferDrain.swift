// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

/// The priming cushion a fresh request builds before real samples are
/// rendered (issue #94 bug 1 follow-up).
///
/// Synthesis streams in bursts (whole decoder windows at a time) while
/// the host drains smoothly, so on a device where synthesis runs at
/// roughly realtime the buffer grazes empty at chunk boundaries and
/// every slightly-late window starves a render pull - in the gen=25
/// device play, 52 zero-filled pulls / 22,759 frames (~1 s) of silence
/// landed mid-utterance as audible dropouts. While a request is priming,
/// pulls answer full-size silence WITHOUT consuming the buffer until it
/// holds `primeDurationSeconds` of audio (or synthesis completes); the
/// cushion then absorbs the boundary jitter for the rest of the request.
public enum RenderPriming {
    /// How much buffered audio ends priming, in seconds of samples at
    /// the render rate.
    /// Device-tuned (Ihor, on the echoing iPhone): 12.5 ms is ~276 frames
    /// at 22050 Hz - under one render pull. Priming only needs the drain
    /// to start behind the first full synthesis window instead of racing
    /// its first frames; the 0.5 s first guess added start latency
    /// without improving the audio.
    public static let primeDurationSeconds: Double = 0.0125

    /// The priming threshold in frames for a stream at `sampleRate`
    /// (22050 -> 275, 16000 -> 200, 44100 -> 551).
    public static func thresholdFrames(sampleRate: Double) -> Int {
        Int(primeDurationSeconds * sampleRate)
    }
}

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
    /// The request is still priming: the buffer holds less than the
    /// priming threshold and synthesis is unfinished, so the pull rendered
    /// a full-size silence (`byteSize` covers the whole frame range) and
    /// consumed NOTHING. `buffered` is the number of samples waiting in
    /// the buffer. The request stays priming after this pull; priming
    /// latches off on the first pull that finds the threshold reached or
    /// synthesis completed, and that pull drains normally.
    case primingSilence(byteSize: Int, buffered: Int)
    /// The pull rendered a full-size buffer: `copied` real samples followed
    /// by `zeroFilled` silence frames. `remaining` is the number of samples
    /// left in the buffer after the pull. `isFinal` is true when this pull
    /// copied the last samples of a completed synthesis, so the caller
    /// signals completion together with this render instead of waiting for
    /// one more empty pull.
    case rendered(copied: Int, zeroFilled: Int, byteSize: Int, remaining: Int, isFinal: Bool)
}

extension RenderDrainOutcome {
    /// Whether the request is still priming after this pull: only a
    /// priming-silence pull leaves priming engaged; any other outcome
    /// means it latched off (or the request ended). The AudioUnit stores
    /// this back into its per-request priming flag.
    public var isPrimingPull: Bool {
        if case .primingSilence = self {
            return true
        }
        return false
    }
}

extension FloatRingBuffer {
    /// Drains up to `frameCount` samples into `destination`, zero-filling
    /// the rest of the frame range, and reports exactly what the pull did.
    ///
    /// `synthesisCompleted` is the producer's completion state sampled by
    /// the caller at pull entry; the buffer count is read here, under the
    /// caller's lock, so copy + removeFirst stay one atomic step.
    ///
    /// `isPriming` / `primeThresholdFrames` carry the caller's per-request
    /// priming state (see RenderPriming): while priming, a pull that finds
    /// less than the threshold buffered (and synthesis unfinished) answers
    /// `.primingSilence` instead of draining. The default disables priming
    /// for callers that do not model the request lifecycle.
    public mutating func drainForRender(
        into destination: UnsafeMutablePointer<Float>,
        frameCount: Int,
        synthesisCompleted: Bool,
        isPriming: Bool = false,
        primeThresholdFrames: Int = 0
    ) -> RenderDrainOutcome {
        if synthesisCompleted && isEmpty {
            return .complete
        }
        if isPriming && !synthesisCompleted && count < primeThresholdFrames {
            // Priming: the cushion has not been reached, so hold every
            // buffered sample and answer the whole frame range with
            // silence. Nothing is consumed - when the threshold is
            // reached (or synthesis completes), the latching pull starts
            // draining from the very first sample.
            destination.update(repeating: 0, count: frameCount)
            return .primingSilence(
                byteSize: frameCount * MemoryLayout<Float>.size, buffered: count
            )
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
