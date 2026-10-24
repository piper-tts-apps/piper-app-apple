// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

#if DEBUG
import Foundation
import OSLog

/// Issue #94 bug-1 request tracing, DEBUG builds only (compiled out of
/// Release). Counts speech requests reaching the AudioUnit and flags a
/// request that arrives while the previous one is still active - the
/// discriminator for the whole-sentence repeat on iPhone 17: one play must
/// produce exactly one "request begin" line. In Console.app, filter by
/// category "AURequestTrace" to see AudioUnit and host lines together.
/// Every line is .default (or .fault) level so it also persists into
/// logarchives; the per-request "request summary" line at request end is
/// the 1x-vs-2x verdict: its appended totals cover exactly one synthesis
/// of the request's text, so a doubled sentence shows up as ~2x samples.
enum AURequestTrace {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "dev.ihor-shevchuk.piper", category: "AURequestTrace")

    static func requestBegin(generation: UInt64, textLength: Int) {
        os_log("request begin gen=%{public}llu textLength=%{public}ld", log: log, type: .default, generation, textLength)
    }

    static func requestArrivedWhileActive(activeGeneration: UInt64, newGeneration: UInt64) {
        os_log("REQUEST WHILE ACTIVE activeGen=%{public}llu newGen=%{public}llu", log: log, type: .fault, activeGeneration, newGeneration)
    }

    static func synthesizeStart(generation: UInt64) {
        os_log("synthesize start gen=%{public}llu", log: log, type: .default, generation)
    }

    static func chunkAppended(generation: UInt64, samples: Int, totalSamples: Int) {
        os_log("chunk append gen=%{public}llu samples=%{public}ld totalSamples=%{public}ld", log: log, type: .default, generation, samples, totalSamples)
    }

    static func chunkRejected(stampedGeneration: UInt64, activeGeneration: UInt64, samples: Int) {
        os_log("chunk REJECTED stampedGen=%{public}llu activeGen=%{public}llu samples=%{public}ld", log: log, type: .default, stampedGeneration, activeGeneration, samples)
    }

    static func chunkDroppedEarly(stampedGeneration: UInt64, samples: Int) {
        os_log("chunk dropped early stampedGen=%{public}llu samples=%{public}ld", log: log, type: .default, stampedGeneration, samples)
    }

    static func cancel(generation: UInt64) {
        os_log("cancelSpeechRequest activeGen=%{public}llu", log: log, type: .default, generation)
    }

    static func requestEnd(generation: UInt64) {
        os_log("request end gen=%{public}llu", log: log, type: .default, generation)
    }

    static func requestSummary(generation: UInt64, appendedChunks: Int, appendedSamples: Int, droppedChunks: Int, droppedSamples: Int) {
        os_log("request summary gen=%{public}llu appendedChunks=%{public}ld appendedSamples=%{public}ld droppedChunks=%{public}ld droppedSamples=%{public}ld",
               log: log, type: .default, generation, appendedChunks, appendedSamples, droppedChunks, droppedSamples)
    }
}

/// Per-instance AURequestTrace state for PiperTTSAudioUnit (DEBUG only):
/// the begun-but-not-ended request generation plus its appended/dropped
/// chunk counters, totalled into the "request summary" line at request end.
final class AURequestTracer {
    private var activeGeneration: UInt64?
    private var appendedChunks: Int = 0
    private var appendedSamples: Int = 0
    private var droppedChunks: Int = 0
    private var droppedSamples: Int = 0

    func begin(generation: UInt64, textLength: Int) {
        if let activeGeneration {
            AURequestTrace.requestArrivedWhileActive(activeGeneration: activeGeneration, newGeneration: generation)
        }
        activeGeneration = generation
        resetCounters()
        AURequestTrace.requestBegin(generation: generation, textLength: textLength)
    }

    func end() {
        if let activeGeneration {
            AURequestTrace.requestEnd(generation: activeGeneration)
            AURequestTrace.requestSummary(generation: activeGeneration,
                                          appendedChunks: appendedChunks,
                                          appendedSamples: appendedSamples,
                                          droppedChunks: droppedChunks,
                                          droppedSamples: droppedSamples)
        }
        activeGeneration = nil
        resetCounters()
    }

    func cancel() {
        AURequestTrace.cancel(generation: activeGeneration ?? 0)
    }

    func synthesizeStart(generation: UInt64) {
        AURequestTrace.synthesizeStart(generation: generation)
    }

    func chunk(stampedGeneration: UInt64, samples: Int, accepted: Bool, activeGeneration: UInt64) {
        if accepted {
            appendedChunks += 1
            appendedSamples += samples
            AURequestTrace.chunkAppended(generation: stampedGeneration, samples: samples, totalSamples: appendedSamples)
        } else {
            countDrop(stampedGeneration: stampedGeneration, samples: samples)
            AURequestTrace.chunkRejected(stampedGeneration: stampedGeneration, activeGeneration: activeGeneration, samples: samples)
        }
    }

    func chunkDroppedEarly(stampedGeneration: UInt64, samples: Int) {
        countDrop(stampedGeneration: stampedGeneration, samples: samples)
        AURequestTrace.chunkDroppedEarly(stampedGeneration: stampedGeneration, samples: samples)
    }

    /// A drop counts toward the summary only while the dropped chunk's own
    /// generation is still the active one; chunks racing in after end()
    /// (bug 2's tail) are logged individually but belong to no live request.
    private func countDrop(stampedGeneration: UInt64, samples: Int) {
        guard stampedGeneration == activeGeneration else { return }
        droppedChunks += 1
        droppedSamples += samples
    }

    private func resetCounters() {
        appendedChunks = 0
        appendedSamples = 0
        droppedChunks = 0
        droppedSamples = 0
    }
}
#endif
