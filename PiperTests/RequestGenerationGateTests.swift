// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperTTSLogic

final class RequestGenerationGateTests: XCTestCase {

    func testInitialGenerationIsZero() {
        let gate = RequestGenerationGate()
        XCTAssertEqual(gate.currentGeneration, 0)
        XCTAssertTrue(gate.isCurrent(0))
    }

    func testBeginReturnsIncreasingGenerations() {
        let gate = RequestGenerationGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertGreaterThan(second, first)
    }

    func testBeginInvalidatesPreviousGeneration() {
        let gate = RequestGenerationGate()
        let stale = gate.begin()
        let current = gate.begin()
        XCTAssertFalse(gate.isCurrent(stale))
        XCTAssertTrue(gate.isCurrent(current))
        XCTAssertEqual(gate.currentGeneration, current)
    }

    func testCancelInvalidatesCurrentGeneration() {
        let gate = RequestGenerationGate()
        let active = gate.begin()
        XCTAssertTrue(gate.isCurrent(active))
        gate.cancel()
        XCTAssertFalse(gate.isCurrent(active))
    }

    func testCancelWithoutBeginIsSafe() {
        let gate = RequestGenerationGate()
        gate.cancel()
        XCTAssertEqual(gate.currentGeneration, 1)
        XCTAssertTrue(gate.isCurrent(1))
    }

    func testStaleCallbackDroppedAfterCancelAndNewBegin() {
        // Simulates the rapid-navigation race: request 1 starts, the user moves on
        // (cancel), request 2 starts. Late callbacks tagged with request 1's
        // generation must be rejected so stale samples never reach the new request.
        let gate = RequestGenerationGate()
        let firstRequest = gate.begin()
        gate.cancel()
        let secondRequest = gate.begin()
        XCTAssertFalse(gate.isCurrent(firstRequest))
        XCTAssertTrue(gate.isCurrent(secondRequest))
        XCTAssertEqual(gate.currentGeneration, secondRequest)
    }

    func testConcurrentBeginKeepsMonotonicCount() {
        let gate = RequestGenerationGate()
        let iterations = 1000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            gate.begin()
        }
        XCTAssertEqual(gate.currentGeneration, UInt64(iterations))
    }

    func testConcurrentReadsNeverCrash() {
        let gate = RequestGenerationGate()
        let current = gate.begin()
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            _ = gate.isCurrent(current)
            _ = gate.currentGeneration
        }
        XCTAssertTrue(gate.isCurrent(current))
    }

    // MARK: - Chunk append validation (bug 2: stale audio after cancel/resume)
    //
    // The AudioUnit used to validate an arriving chunk with
    // `gate.isCurrent(activeGeneration)`, reading the MUTABLE slot at append time.
    // Once a new request begins, the slot holds the new generation, so that check
    // passes for any late chunk - including one produced by the cancelled request.
    // `shouldAcceptChunk(producedUnder:forActiveRequest:)` is the pinned decision
    // the AudioUnit now uses instead: the producer callback stamps the chunk with
    // the active request's generation when the chunk arrives, and the append
    // validates that stamp.

    func testValidatingTheLiveSlotCannotRejectAStaleChunk() {
        // Documents the hazard in the old expression: after cancel + new begin,
        // isCurrent(slot) is true no matter which request produced the chunk.
        let gate = RequestGenerationGate()
        _ = gate.begin() // request A pins the slot
        gate.cancel()
        let slotAfterNewBegin = gate.begin() // request B overwrites the slot
        XCTAssertTrue(gate.isCurrent(slotAfterNewBegin),
                      "Slot validation is vacuous once any request is active - the reason a stamp is required")
    }

    func testChunkProducedByCancelledRequestRejectedAfterNewRequestBegins() {
        let gate = RequestGenerationGate()
        let requestA = gate.begin()
        let stampA = requestA // producer callback stamps the chunk on arrival
        gate.cancel()
        let requestB = gate.begin()
        XCTAssertFalse(gate.shouldAcceptChunk(producedUnder: stampA, forActiveRequest: requestB),
                       "A chunk produced by the cancelled request must never be appended to the new request")
        XCTAssertTrue(gate.shouldAcceptChunk(producedUnder: requestB, forActiveRequest: requestB))
    }

    func testChunkProducedByCancelledRequestRejectedEvenIfSlotNotYetOverwritten() {
        // The AudioUnit does not reset activeGeneration on cancel, so the slot can
        // still hold the cancelled request's generation. Slot equality alone would
        // accept the chunk; the gate must also have moved past the stamp.
        let gate = RequestGenerationGate()
        let requestA = gate.begin()
        gate.cancel()
        XCTAssertFalse(gate.shouldAcceptChunk(producedUnder: requestA, forActiveRequest: requestA))
    }

    func testChunkAcceptedWhileProducingRequestIsStillActive() {
        let gate = RequestGenerationGate()
        let requestA = gate.begin()
        XCTAssertTrue(gate.shouldAcceptChunk(producedUnder: requestA, forActiveRequest: requestA),
                      "The non-cancel path must be unchanged: chunks of the active request still append")
    }

    func testQueuedAudioOfCancelledRequestNeverRendersIntoNextRequest() {
        // Logic-level end-to-end, mirroring the AudioUnit's composition:
        // FloatRingBuffer is the output queue, the gate plus shouldAcceptChunk
        // decide appends, and cancel = gate invalidation + buffer flush
        // (removeRequestAndCleanOutputData in PiperTTSAudioUnit).
        let gate = RequestGenerationGate()
        var buffer = FloatRingBuffer()

        // Request A synthesizes several-x realtime; the surplus is appended.
        let requestA = gate.begin()
        if gate.shouldAcceptChunk(producedUnder: requestA, forActiveRequest: requestA) {
            buffer.append(contentsOf: [Float](repeating: 1, count: 4096))
        }
        XCTAssertEqual(buffer.count, 4096)

        // User cancels mid-sentence: invalidation + flush of queued audio.
        gate.cancel()
        buffer.clear()

        // Meanwhile request B begins and its first chunk appends.
        let requestB = gate.begin()
        if gate.shouldAcceptChunk(producedUnder: requestB, forActiveRequest: requestB) {
            buffer.append(contentsOf: [Float](repeating: 2, count: 2048))
        }

        // A chunk of A was in flight (inside the resampler) across the cancel and
        // only now reaches the append. It must be dropped.
        if gate.shouldAcceptChunk(producedUnder: requestA, forActiveRequest: requestB) {
            buffer.append(contentsOf: [Float](repeating: 1, count: 512))
        }

        XCTAssertEqual(buffer.count, 2048, "Only the new request's audio may be queued")
        XCTAssertTrue(buffer.snapshot.allSatisfy { $0 == 2 },
                      "No stale samples from the cancelled request may render into the next one")
    }
}
