// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

/// Wait gate for a render pull that finds the synthesis buffer starved.
///
/// Why this exists: PR #96 made a starved pull return full-size silence
/// immediately, to stop the host re-pulling the same timestamp on a short
/// buffer and doubling the audio. That is correct for a realtime host,
/// which only plays the silence briefly. An offline host
/// (AVSpeechSynthesizer.write, system voice preview) RECORDS every pull
/// into its file, and it pulls in a tight loop, not on a realtime clock -
/// so thousands of immediate silence pulls become minutes of recorded
/// silence before the voice.
///
/// The fix is not to restore the short buffer. It is to wait, BEFORE the
/// drain, until the buffer can actually render, and only then drain with
/// the unchanged full-size contract. The drain itself still never waits.
///
/// The caller supplies `isReady` (buffered enough, synthesis completed,
/// or request gone) and the waiter re-checks it in short slices, so a
/// missed signal, a completion with no final chunk, or a cancel can never
/// strand a pull past the timeout. `signal()` is a prompt wake-up only;
/// correctness does not depend on it.
public final class RenderPullWaiter {
    private let condition = NSCondition()

    /// How long a single wait slice lasts, in seconds. Short enough that
    /// completion or cancel are noticed promptly even if no signal arrives.
    public static let sliceSeconds: TimeInterval = 0.02

    public init() {}

    public func signal() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    /// Waits until `isReady()` is true, or `timeoutSeconds` elapses.
    /// Returns true when ready, false on timeout. `isReady` is evaluated
    /// outside the condition lock, so it may take the caller's own lock.
    @discardableResult
    public func waitUntilReady(timeoutSeconds: TimeInterval, isReady: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while true {
            if isReady() {
                return true
            }
            if Date() >= deadline {
                return false
            }
            let sliceEnd = min(Date(timeIntervalSinceNow: Self.sliceSeconds), deadline)
            condition.lock()
            _ = condition.wait(until: sliceEnd)
            condition.unlock()
        }
    }
}
