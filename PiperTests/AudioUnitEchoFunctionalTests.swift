// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
import AVFoundation
import Accelerate
@testable import Piper
@testable import PiperAppUtils

/// Issue #94 bug 1 - functional captures that need a REAL voice.
///
/// The repo ships no .onnx fixture, and the AudioUnit cannot synthesize
/// without a model in the shared container, so these tests are gated on the
/// ECHO_CAPTURE_FUNCTIONAL environment variable (the OpenJTalk functional
/// tests use the same pattern). When enabled, the class downloads the
/// smallest fp16 HIGH voice from the live catalog (en_US-lessac-high - the
/// device repro family), installs it through the production
/// `FileManager.install` seam, and exercises the direct play path.
///
/// Staged layout: the monolith only (no split parts), so synthesis is
/// non-streaming; the device captures proved appends clean in BOTH modes -
/// the mechanisms under test here live in the host engine graph, which is
/// synthesis-mode independent. The 48 kHz converter stage the device adds
/// after the engine output node is outside this capture's sample domain.
final class AudioUnitEchoFunctionalTests: XCTestCase {

    private static let gateVariable = "ECHO_CAPTURE_FUNCTIONAL"
    private static let catalogBase = "https://huggingface.co/IhorShevchuk/piper1-voices-fp16-quantized/resolve/main"
    private static let voicePath = "en/en_US/lessac/high/en_US-lessac-high"

    private static var stagedVoiceId: String?
    private static var stagedInfo: ModelInfo?

    // MARK: - Staging

    private func requireFunctional() throws {
        guard ProcessInfo.processInfo.environment[Self.gateVariable] != nil else {
            throw XCTSkip("set \(Self.gateVariable) to run the voice-backed echo captures")
        }
    }

    /// Downloads the voice once per test run and installs it via the
    /// production seam; returns its ModelInfo voiceId.
    ///
    /// FIDELITY BOUNDARY: staging needs the shared app-group container
    /// (`ModelPaths.installNew`). In the unsigned simulator test host the
    /// group container is unavailable (the suite's own
    /// FileManagerModelPathsTests note: "In test env sharedFolder is nil,
    /// so modelsFolderURL nil, installNew nil"), `install` throws
    /// `InstallError.invalidDestinationURLs`, and the AU process likewise
    /// sees an empty registry - a real voice cannot be staged at ANY seam
    /// in this environment. Skip honestly in that case; on a signed host
    /// (device test run) the same code stages and executes for real.
    private func stageVoice() async throws -> String {
        if let staged = Self.stagedVoiceId {
            return staged
        }
        guard FileManager.ModelPaths.installNew != nil else {
            throw XCTSkip("no app-group container in this test host (ModelPaths.installNew is nil): " +
                          "a voice cannot be staged where the AudioUnit can see it; run on a signed host")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("echo-capture-voice")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let modelURL = staging.appendingPathComponent("model.onnx")
        let jsonURL = staging.appendingPathComponent("model.onnx.json")
        let modelRemote = try XCTUnwrap(URL(string: "\(Self.catalogBase)/\(Self.voicePath).onnx"))
        let jsonRemote = try XCTUnwrap(URL(string: "\(Self.catalogBase)/\(Self.voicePath).onnx.json"))
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            let (downloaded, _) = try await URLSession.shared.download(from: modelRemote)
            try FileManager.default.moveItem(at: downloaded, to: modelURL)
        }
        if !FileManager.default.fileExists(atPath: jsonURL.path) {
            let (downloaded, _) = try await URLSession.shared.download(from: jsonRemote)
            try FileManager.default.moveItem(at: downloaded, to: jsonURL)
        }
        let source = try XCTUnwrap(FileManager.ModelPaths(model: modelURL, json: jsonURL),
                                   "downloaded voice config must parse")
        let info = try XCTUnwrap(source.info, "downloaded voice config must produce ModelInfo")
        try FileManager.default.install(paths: source, catalogKey: "en_US-lessac-high")
        Self.stagedVoiceId = info.voiceId
        Self.stagedInfo = info
        return info.voiceId
    }

    override static func tearDown() {
        // Leave no installed voice behind for other test classes / later runs.
        if let info = stagedInfo,
           let entry = FileManager.ModelPaths.installedModels.first(where: { $0.info == info }) {
            try? FileManager.default.uninstall(paths: entry)
        }
        stagedVoiceId = nil
        stagedInfo = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func engine(of sut: PiperAudioUnit) -> AVAudioEngine? {
        Mirror(reflecting: sut).children.first { $0.label == "engine" }?.value as? AVAudioEngine
    }

    private func audioUnit(of sut: PiperAudioUnit) -> AVAudioUnit? {
        Mirror(reflecting: sut).children.first { $0.label == "audioUnit" }?.value as? AVAudioUnit
    }

    private func readWAVSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func nonSilentSeconds(_ samples: [Float], sampleRate: Double) -> Double {
        let loud = samples.reduce(0) { $0 + (abs($1) > 0.02 ? 1 : 0) }
        return Double(loud) / sampleRate
    }

    /// Block-average downsample to roughly `targetRate` for correlation work.
    private func downsampled(_ samples: [Float], from sampleRate: Double, to targetRate: Double) -> [Float] {
        let factor = max(1, Int((sampleRate / targetRate).rounded()))
        guard factor > 1, !samples.isEmpty else { return samples }
        var result: [Float] = []
        result.reserveCapacity(samples.count / factor + 1)
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            var index = 0
            while index < samples.count {
                let count = min(factor, samples.count - index)
                var mean: Float = 0
                vDSP_meanv(base + index, 1, &mean, vDSP_Length(count))
                result.append(mean)
                index += count
            }
        }
        return result
    }

    /// Dot product via vDSP_vmul + vDSP_sve (vDSP_dotp is not exposed to
    /// Swift in this SDK's Accelerate overlay).
    private func dotProduct(_ lhs: [Float], _ rhs: [Float], count: Int) -> Float {
        var product = [Float](repeating: 0, count: count)
        vDSP_vmul(lhs, 1, rhs, 1, &product, 1, vDSP_Length(count))
        var sum: Float = 0
        vDSP_sve(product, 1, &sum, vDSP_Length(count))
        return sum
    }

    /// Max normalized autocorrelation over lags in [minLagSeconds, duration/2].
    /// A repeated segment (sequential duplicate) drives this toward ~0.5+ at
    /// the repetition lag; clean speech stays well below.
    private func maxAutocorrelation(_ samples: [Float], sampleRate: Double,
                                    minLagSeconds: Double) -> (value: Float, lagSeconds: Double) {
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var negated = -mean
        var centered = [Float](repeating: 0, count: samples.count)
        vDSP_vsadd(samples, 1, &negated, &centered, 1, vDSP_Length(samples.count))
        let energy = dotProduct(centered, centered, count: centered.count)
        guard energy > 0 else { return (0, 0) }
        let minLag = Int(minLagSeconds * sampleRate)
        let maxLag = centered.count / 2
        guard maxLag > minLag else { return (0, 0) }
        var best: Float = 0
        var bestLag = 0
        var scratch = [Float](repeating: 0, count: centered.count)
        centered.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            for lag in minLag..<maxLag {
                let overlap = centered.count - lag
                vDSP_vmul(base, 1, base + lag, 1, &scratch, 1, vDSP_Length(overlap))
                var dot: Float = 0
                vDSP_sve(scratch, 1, &dot, vDSP_Length(overlap))
                let value = dot / energy
                if value > best {
                    best = value
                    bestLag = lag
                }
            }
        }
        return (best, Double(bestLag) / sampleRate)
    }

    /// Thread-safe float collector for the engine tap.
    private final class TapCollector {
        private let lock = NSLock()
        private(set) var samples: [Float] = []
        var sampleRate: Double = 0

        func append(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            lock.lock()
            samples.append(contentsOf: chunk)
            lock.unlock()
        }
    }

    /// Lock-protected one-shot flag for polling a Task's completion.
    private final class FinishedFlag {
        private let lock = NSLock()
        private var finished = false

        func set() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }

    // MARK: - T2: a full direct-path play must contain the sentence exactly once

    func testDirectPlayCaptureContainsNoDuplicatedAudio() async throws {
        try requireFunctional()
        let voiceId = try await stageVoice()
        let text = "The quick brown fox jumps over the lazy dog."

        // Reference: the app's own offline renderer (PiperAudioUnit.save),
        // which pulls the AU directly - no engine graph, no output node.
        let refSut = PiperAudioUnit()
        await refSut.connect()
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("echo-capture-ref.wav")
        try? FileManager.default.removeItem(at: wavURL)
        try await refSut.save(text: text, piperVoiceId: voiceId, to: wavURL.path)
        await refSut.disconnect()
        let refSamples = try readWAVSamples(wavURL)
        let refSeconds = nonSilentSeconds(refSamples, sampleRate: 22050)
        XCTAssertGreaterThan(refSeconds, 0.5,
                             "fidelity: the reference render must contain real speech (staging/registry must be visible to the AU)")

        // Capture: the real direct play path, tapped at the engine output.
#if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        defer { try? AVAudioSession.sharedInstance().setActive(false) }
#endif
        let sut = PiperAudioUnit()
        await sut.connect()
        let engine = try XCTUnwrap(engine(of: sut))
        let collector = TapCollector()
        collector.sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        engine.outputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            collector.append(buffer)
        }
        await sut.play(text: text, piperVoiceId: voiceId)
        try await Task.sleep(for: .milliseconds(300))
        engine.outputNode.removeTap(onBus: 0)
        await sut.disconnect()

        let tapSeconds = nonSilentSeconds(collector.samples, sampleRate: collector.sampleRate)
        print("ECHO-CAPTURE T2 non-silent seconds: reference \(refSeconds), play-path \(tapSeconds)")
        XCTAssertGreaterThan(tapSeconds, 0.3,
                             "fidelity: the tap must actually capture the play (an empty capture proves nothing)")
        XCTAssertLessThanOrEqual(tapSeconds, refSeconds * 1.15,
                                 "the play path must not render materially more audio than one pass of the sentence")

        let analysis = downsampled(collector.samples, from: collector.sampleRate, to: 4000)
        let correlation = maxAutocorrelation(analysis, sampleRate: 4000, minLagSeconds: 0.3)
        print("ECHO-CAPTURE T2 max autocorrelation (lag >= 0.3 s): \(correlation.value) at \(correlation.lagSeconds) s")
        XCTAssertLessThan(correlation.value, 0.5,
                          "no segment of the play-path capture may repeat (autocorrelation at lag >= 0.3 s must stay < 0.5)")
    }

    // MARK: - T3 (functional): a health-check tick must not disturb a long in-flight play

    func testHealthCheckDoesNotReplaceAudioUnitDuringLongPlay() async throws {
        try requireFunctional()
        let voiceId = try await stageVoice()
        // ~670 chars of the device session's text: tens of seconds of audio,
        // so the play stays in flight across several 3 s health-check ticks.
        let sentence = "A rainbow is a meteorological phenomenon that is caused by reflection, " +
            "refraction and dispersion of light in water droplets resulting in a spectrum " +
            "of light appearing in the sky."
        let text = Array(repeating: sentence, count: 3).joined(separator: " ")

        let sut = PiperAudioUnit()
        await sut.connect()
        let engine = try XCTUnwrap(engine(of: sut))
        let unit = try XCTUnwrap(audioUnit(of: sut))
        let connectTime = Date()

        let finished = FinishedFlag()
        let playTask = Task {
            await sut.play(text: text, piperVoiceId: voiceId)
            finished.set()
        }
        var replacedDuringPlay = false
        var predicateViolations = 0
        var polls = 0
        while !finished.isSet {
            polls += 1
            if let current = audioUnit(of: sut), current !== unit {
                replacedDuringPlay = true
                break
            }
            if engine.isRunning && !unit.auAudioUnit.renderResourcesAllocated {
                predicateViolations += 1
            }
            if Date().timeIntervalSince(connectTime) > 120 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await playTask.value
        let flightSeconds = Date().timeIntervalSince(connectTime)

        print("ECHO-CAPTURE T3 flight \(flightSeconds) s, polls \(polls), predicate violations \(predicateViolations)")
        XCTAssertGreaterThan(flightSeconds, 3.2,
                             "fidelity: the play must stay in flight across at least one 3 s health-check tick")
        XCTAssertFalse(replacedDuringPlay,
                       "the health check must not replace the AudioUnit while a play is in flight")
        await sut.disconnect()
    }
}
