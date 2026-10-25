// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import AVFoundation

class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer!
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: AVSpeechSynthesisVoice?) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice

        // Use withCheckedContinuation to pause execution until resume() is called
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        resumeContinuation()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        resumeContinuation()
    }

    private func resumeContinuation() {
        continuation?.resume()
        continuation = nil
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
