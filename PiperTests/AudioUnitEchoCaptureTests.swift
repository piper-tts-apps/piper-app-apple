// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
import AVFoundation
@testable import Piper
@testable import PiperTTSLogic

/// Issue #94 bug 1 - continuous echo on HIGH voices, only on one device.
///
/// Device captures already proved the synthesis side clean: one request, one
/// synthesis pass, appends exactly 1x the sentence's samples, and the AU's
/// render pulls rendered exactly those samples once each. The duplication
/// therefore happens at or after the HOST engine graph (the reader's direct
/// `PiperAudioUnit.play` path). These tests characterize the host-side
/// mechanisms that could produce it:
///
///  - T1: dual connection in the engine graph (play()'s connect step
///    re-attaching / re-connecting an already attached AudioUnit).
///  - T3: the 3 s health-check timer tearing down / replacing the AudioUnit
///    around a play.
///  - T4/T5: teardown-ordering regressions at the logic level (these pin the
///    already-landed fixes; they must PASS).
///
/// Fidelity: T1/T3 run the REAL PiperAudioUnit and a REAL AVAudioEngine in
/// the simulator test host; the AudioUnit itself is instantiated by the
/// production code path (out-of-process, from the app's own appex). What the
/// simulator cannot reproduce is the device-only timing (A19 render cadence,
/// the 48 kHz converter stage) - the graph invariants asserted here are
/// sample-rate and device independent. Private stored properties (`engine`,
/// `audioUnit`) are read through Mirror because PiperAudioUnit exposes no
/// test seam for them; nothing here modifies product code.
final class AudioUnitEchoCaptureTests: XCTestCase {

    /// A voice id that is well-formed but never installed: play() then runs
    /// its full graph sequence (stop/reset/attach/connect/start) and polls
    /// `isSynthesizing` for ~1 s before returning, without synthesizing.
    private let bogusVoiceId = "echo-capture>0<22050>0<en_US>0<1"

    // MARK: - Mirror accessors (read-only test seam)

    private func engine(of sut: PiperAudioUnit) -> AVAudioEngine? {
        Mirror(reflecting: sut).children.first { $0.label == "engine" }?.value as? AVAudioEngine
    }

    private func audioUnit(of sut: PiperAudioUnit) -> AVAudioUnit? {
        Mirror(reflecting: sut).children.first { $0.label == "audioUnit" }?.value as? AVAudioUnit
    }

    private func connectionPoints(_ engine: AVAudioEngine, _ unit: AVAudioUnit) -> [AVAudioConnectionPoint] {
        engine.outputConnectionPoints(for: unit, outputBus: 0)
    }

    // MARK: - T1: connection integrity (candidate a - dual route)

    @MainActor
    func testPlayLeavesExactlyOneConnectionPoint() async throws {
        let sut = PiperAudioUnit()
        await sut.connect()
        let engine = try XCTUnwrap(engine(of: sut))
        let unit = try XCTUnwrap(audioUnit(of: sut),
                                 "connect() must load the real AudioUnit in the test host")
        XCTAssertEqual(connectionPoints(engine, unit).count, 0,
                       "connect() attaches the AU but must not connect it anywhere")

        await sut.play(text: "Hello world.", piperVoiceId: bogusVoiceId)

        let points = connectionPoints(engine, unit)
        XCTAssertEqual(points.count, 1,
                       "play() must leave exactly ONE route out of the AU; more than one sums the same samples into the output (echo)")
        XCTAssertTrue(points.first?.node === engine.outputNode,
                      "the single route must go to the engine output node")
        await sut.disconnect()
    }

    @MainActor
    func testSecondPlayKeepsExactlyOneConnectionPoint() async throws {
        let sut = PiperAudioUnit()
        await sut.connect()
        let engine = try XCTUnwrap(engine(of: sut))
        let unit = try XCTUnwrap(audioUnit(of: sut))

        await sut.play(text: "Hello world.", piperVoiceId: bogusVoiceId)
        await sut.play(text: "Hello again.", piperVoiceId: bogusVoiceId)

        XCTAssertEqual(connectionPoints(engine, unit).count, 1,
                       "a second play must not accumulate routes (attach + reset + connect runs per play)")
        await sut.disconnect()
    }

    @MainActor
    func testPlayAfterSaveStyleMixerConnectionKeepsSingleRoute() async throws {
        // save() connects the AU to mainMixerNode; play() connects it to
        // outputNode. If a save-style route survived into a later play, the
        // engine would carry the AU twice (direct + via the mixer).
        let sut = PiperAudioUnit()
        await sut.connect()
        let engine = try XCTUnwrap(engine(of: sut))
        let unit = try XCTUnwrap(audioUnit(of: sut))

        // Replicates save()'s connect step 1:1 (same node, same format source).
        engine.connect(unit, to: engine.mainMixerNode, format: unit.outputFormat(forBus: 0))
        XCTAssertEqual(connectionPoints(engine, unit).count, 1)

        await sut.play(text: "Hello world.", piperVoiceId: bogusVoiceId)

        let points = connectionPoints(engine, unit)
        XCTAssertEqual(points.count, 1,
                       "play() must clear any pre-existing route (engine.reset) and leave exactly one")
        XCTAssertTrue(points.first?.node === engine.outputNode)
        await sut.disconnect()
    }

    @MainActor
    func testReconnectOrphansOldUnitWithNoRoutesAndRoutesNewUnitOnce() async throws {
        let sut = PiperAudioUnit()
        await sut.connect()
        let engine = try XCTUnwrap(engine(of: sut))
        let oldUnit = try XCTUnwrap(audioUnit(of: sut))
        await sut.play(text: "Hello world.", piperVoiceId: bogusVoiceId)
        XCTAssertEqual(connectionPoints(engine, oldUnit).count, 1)

        await sut.reconnect()

        let newUnit = try XCTUnwrap(audioUnit(of: sut), "reconnect() must install a fresh AudioUnit")
        XCTAssertFalse(newUnit === oldUnit, "reconnect() must replace the AudioUnit instance")
        XCTAssertEqual(connectionPoints(engine, oldUnit).count, 0,
                       "the replaced AU must keep no live route into the engine, or two AUs render into one output")
        // Characterization, printed for the record: disconnect() never calls
        // engine.detach, so replaced AUs stay attached (harmless only while
        // they hold no connection points, as asserted above).
        print("ECHO-CAPTURE attached nodes after one reconnect: \(engine.attachedNodes.count)")

        await sut.play(text: "Hello world.", piperVoiceId: bogusVoiceId)
        XCTAssertEqual(connectionPoints(engine, newUnit).count, 1,
                       "after reconnect, the new AU must be routed exactly once")
        XCTAssertEqual(connectionPoints(engine, oldUnit).count, 0,
                       "the orphaned AU must stay unrouted after later plays")
        await sut.disconnect()
    }

    // MARK: - T3a: health check cannot fire while a play is in flight

    @MainActor
    func testHealthCheckPredicateStaysFalseWhilePlayInFlight() async throws {
        let sut = PiperAudioUnit()
        await sut.connect()
        let engine = try XCTUnwrap(engine(of: sut))
        let unit = try XCTUnwrap(audioUnit(of: sut))

        // The health-check timer's exact predicate (PiperAudioUnit
        // startHealthCheckTimer): reconnect iff !engine.isRunning ||
        // !unit.renderResourcesAllocated. The closure is private, so this
        // test evaluates its predicate against live in-flight state.
        let voiceId = bogusVoiceId
        let playTask = Task { await sut.play(text: "Hello world.", piperVoiceId: voiceId) }
        var inFlightSamples = 0
        var identityStable = true
        for _ in 0..<200 {
            if engine.isRunning {
                inFlightSamples += 1
                let resourcesAllocated = unit.auAudioUnit.renderResourcesAllocated
                XCTAssertTrue(resourcesAllocated,
                              "render resources must stay allocated for the whole play")
                XCTAssertFalse(!engine.isRunning || !resourcesAllocated,
                               "health-check predicate must be false while a play is in flight")
                if audioUnit(of: sut) !== unit {
                    identityStable = false
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await playTask.value

        // Fidelity gate: with an uninstalled voice id, play() cannot build
        // its speech request and returns BEFORE engine.start(), so no
        // in-flight window exists at this seam (measured: 0 running samples
        // across the whole play). Rather than fake coverage, skip: the
        // in-flight health-check capture with a real voice lives in
        // AudioUnitEchoFunctionalTests
        // (testHealthCheckDoesNotReplaceAudioUnitDuringLongPlay).
        guard inFlightSamples > 0 else {
            await sut.disconnect()
            throw XCTSkip("no in-flight window at this seam: an invalid voice makes play() return before engine.start()")
        }
        XCTAssertTrue(identityStable, "the AudioUnit must not be replaced while a play is in flight")
        await sut.disconnect()
    }

    // MARK: - T3b: characterization - the health check should replace the AU after a play

    /// CHARACTERIZATION of candidate (b)'s arming state and its trigger.
    ///
    /// Arming: play() stops the engine when the utterance finishes, so the
    /// health-check predicate (`!engine.isRunning`) becomes true on an
    /// otherwise healthy connection - the code intends the next 3 s tick to
    /// disconnect, reset and replace the AudioUnit; the timer cannot
    /// distinguish "play finished" from "unhealthy".
    ///
    /// Trigger doubt: `startHealthCheckTimer()` runs inside the
    /// non-isolated async `connect()`, whose continuations execute on the
    /// Swift concurrency cooperative pool, so `Timer.scheduledTimer`
    /// attaches to a worker thread's run loop, which is never pumped. Every
    /// production call site awaits `connect()` from a `Task`, exactly like
    /// this test. If the timer is inert the replacement never happens and
    /// this test FAILS - that failure is the capture: candidate (b) then
    /// cannot act through the timer, only through the engine-configuration
    /// and route-change handlers. (Consistent with the 2026-10-23 device
    /// capture: one AU process across five plays despite stopped-engine
    /// gaps between them.)
    ///
    /// Synchronous so the main run loop can be pumped legally; the async
    /// setup is driven through expectations.
    func testHealthCheckReplacesAudioUnitAfterPlayEnds() throws {
        let sut = PiperAudioUnit()
        let ready = expectation(description: "connect + play")
        let voiceId = bogusVoiceId
        Task {
            await sut.connect()
            await sut.play(text: "Hello world.", piperVoiceId: voiceId)
            ready.fulfill()
        }
        wait(for: [ready], timeout: 20)

        let engine = try XCTUnwrap(engine(of: sut))
        let oldUnit = try XCTUnwrap(audioUnit(of: sut))
        XCTAssertFalse(engine.isRunning, "precondition: play() stops the engine when done")
        // Note: this test deliberately does NOT read
        // oldUnit.auAudioUnit.renderResourcesAllocated here. That property
        // is a synchronous XPC call into the extension process; after a
        // previous test's disconnect recycled the extension, the call can
        // block indefinitely (observed 2026-10-24: full-suite run hung in
        // this test until the scheme timeout restarted the runner). The
        // allocated-after-play half of the predicate was verified in the
        // standalone run of this suite; the stopped engine alone is the
        // half that matters for the replacement watch below.

        // Pump the main run loop (the app's main-loop equivalent) and watch
        // for the health check to replace the unit.
        var replaced = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let current = audioUnit(of: sut), current !== oldUnit {
                replaced = true
                break
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(replaced,
                      "the health check should replace the idle AU (disconnect + reset + connect) within a timer period")
        if replaced {
            print("ECHO-CAPTURE health check replaced the AudioUnit after the play")
        }
        let done = expectation(description: "disconnect")
        Task {
            await sut.disconnect()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }

    // MARK: - T4: teardown ordering (pins the deallocateRenderResources probe fix)

    func testDeallocateTeardownSequenceRejectsLateChunks() {
        // Logic-level mirror of PiperTTSAudioUnit.deallocateRenderResources
        // AFTER the probe fix: removeRequestAndCleanOutputData() runs first
        // (requestGate.cancel() + output flush) and only then are piper/model
        // released. A chunk stamped with the torn-down generation - e.g. from
        // a producer that outlives the request - must be rejected both while
        // the slot still holds the dead generation and after a new begin.
        let gate = RequestGenerationGate()
        var buffer = FloatRingBuffer()

        let request = gate.begin()
        if gate.shouldAcceptChunk(producedUnder: request, forActiveRequest: request) {
            buffer.append(contentsOf: [Float](repeating: 1, count: 4096))
        }
        XCTAssertEqual(buffer.count, 4096)

        // Teardown sequence (gate invalidation + flush), before any release.
        gate.cancel()
        buffer.clear()

        XCTAssertFalse(gate.shouldAcceptChunk(producedUnder: request, forActiveRequest: request),
                       "a late chunk of the torn-down request must be rejected even with no new request yet")
        if gate.shouldAcceptChunk(producedUnder: request, forActiveRequest: request) {
            buffer.append(contentsOf: [Float](repeating: 1, count: 512))
        }
        XCTAssertEqual(buffer.count, 0, "nothing of the torn-down request may reach the render buffer")

        let nextRequest = gate.begin()
        XCTAssertFalse(gate.shouldAcceptChunk(producedUnder: request, forActiveRequest: nextRequest),
                       "a late chunk of the torn-down request must stay rejected after the next request begins")
    }

    func testClearWithoutGateCancelWouldStillAcceptLateChunk() {
        // Characterization of why the ordering matters: the PRE-fix
        // deallocateRenderResources only cleared the buffer and released the
        // producer reference - it never invalidated the gate. Composed that
        // way, a late chunk stamped with the still-current generation is
        // accepted and lands in the next render cycle. This test pins the
        // hazard the probe fix removes; it must keep passing as documentation.
        let gate = RequestGenerationGate()
        var buffer = FloatRingBuffer()

        let request = gate.begin()
        if gate.shouldAcceptChunk(producedUnder: request, forActiveRequest: request) {
            buffer.append(contentsOf: [Float](repeating: 1, count: 4096))
        }

        // Pre-fix teardown: flush only, no gate invalidation.
        buffer.clear()

        XCTAssertTrue(gate.shouldAcceptChunk(producedUnder: request, forActiveRequest: request),
                      "hazard documentation: without gate invalidation the dead request still validates its chunks")
    }

    // MARK: - T5: repeated allocate/deallocate cycles start clean

    func testRepeatedTeardownCyclesRenderOnlyCurrentRequestSamples() {
        // The AU logic seam the suite already uses (gate + FloatRingBuffer,
        // as in AudioUnitIntegrationTests): across repeated
        // allocate -> synthesize -> partial drain -> deallocate cycles, a new
        // request must render exactly its own samples - no leftovers from a
        // previous cycle, none dropped, none duplicated.
        let gate = RequestGenerationGate()
        var buffer = FloatRingBuffer()

        for cycle in 1...3 {
            let generation = gate.begin()
            let value = Float(cycle)
            if gate.shouldAcceptChunk(producedUnder: generation, forActiveRequest: generation) {
                buffer.append(contentsOf: [Float](repeating: value, count: 3000))
            }

            if cycle < 3 {
                // Partial drain, then deallocate cuts the request short.
                buffer.removeFirst(1000)
                gate.cancel()
                buffer.clear()
                XCTAssertTrue(buffer.snapshot.isEmpty, "deallocate must leave an empty buffer (cycle \(cycle))")
            } else {
                // Final cycle renders to completion: exactly its own samples.
                var rendered: [Float] = []
                while !buffer.snapshot.isEmpty {
                    let step = min(1024, buffer.count)
                    rendered.append(contentsOf: buffer.snapshot.prefix(step))
                    buffer.removeFirst(step)
                }
                XCTAssertEqual(rendered.count, 3000,
                               "the new request must render exactly its own sample count")
                XCTAssertTrue(rendered.allSatisfy { $0 == value },
                              "no samples from earlier cycles may leak into a later request")
                gate.cancel()
                buffer.clear()
            }
        }
    }
}
