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
enum AURequestTrace {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "dev.ihor-shevchuk.piper", category: "AURequestTrace")

    static func requestBegin(generation: UInt64, textLength: Int) {
        os_log("request begin gen=%{public}llu textLength=%{public}ld", log: log, type: .default, generation, textLength)
    }

    static func requestArrivedWhileActive(activeGeneration: UInt64, newGeneration: UInt64) {
        os_log("REQUEST WHILE ACTIVE activeGen=%{public}llu newGen=%{public}llu", log: log, type: .fault, activeGeneration, newGeneration)
    }

    static func chunkAppended(generation: UInt64, samples: Int, totalSamples: Int) {
        os_log("chunk append gen=%{public}llu samples=%{public}ld totalSamples=%{public}ld", log: log, type: .debug, generation, samples, totalSamples)
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
}

/// Per-instance AURequestTrace state for PiperTTSAudioUnit (DEBUG only):
/// the begun-but-not-ended request generation and its appended-sample total.
final class AURequestTracer {
    private var activeGeneration: UInt64?
    private var appendedSamples: Int = 0

    func begin(generation: UInt64, textLength: Int) {
        if let activeGeneration {
            AURequestTrace.requestArrivedWhileActive(activeGeneration: activeGeneration, newGeneration: generation)
        }
        activeGeneration = generation
        appendedSamples = 0
        AURequestTrace.requestBegin(generation: generation, textLength: textLength)
    }

    func end() {
        if let activeGeneration {
            AURequestTrace.requestEnd(generation: activeGeneration)
        }
        activeGeneration = nil
        appendedSamples = 0
    }

    func cancel() {
        AURequestTrace.cancel(generation: activeGeneration ?? 0)
    }

    func chunk(stampedGeneration: UInt64, samples: Int, accepted: Bool, activeGeneration: UInt64) {
        if accepted {
            appendedSamples += samples
            AURequestTrace.chunkAppended(generation: stampedGeneration, samples: samples, totalSamples: appendedSamples)
        } else {
            AURequestTrace.chunkRejected(stampedGeneration: stampedGeneration, activeGeneration: activeGeneration, samples: samples)
        }
    }

    func chunkDroppedEarly(stampedGeneration: UInt64, samples: Int) {
        AURequestTrace.chunkDroppedEarly(stampedGeneration: stampedGeneration, samples: samples)
    }
}
#endif
