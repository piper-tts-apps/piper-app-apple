// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import AVFoundation
import PiperAppUtils

/// The system voice registry (what VoiceOver and Spoken Content read)
/// vs the app's own installed models. A voice is "visible" when
/// AVSpeechSynthesisVoice resolves its identifier; nil means the system
/// has not (re-)registered the provider voice, which usually happens
/// after updating the app, and VoiceOver cannot use it until the system
/// picks it up again (a re-scan, or a device restart).
enum SystemVoiceVisibility {
    /// The namespace the system puts in front of a provider voice id.
    static let identifierPrefix = "dev.ihor-shevchuk.piperapp.pipertts."

    /// The provider voice id for a model, with the speaker suffix for
    /// multi-speaker models. Same construction as PiperManager's
    /// playback path; kept here so the two can never drift apart.
    static func piperVoiceId(for modelInfo: ModelInfo, speakerId: Int) -> String {
        if modelInfo.numberOfSpeakers > 1 {
            "\(modelInfo.voiceId)\(Constants.speakerIdSeparator)\(speakerId)"
        } else {
            modelInfo.voiceId
        }
    }

    /// The full identifier the system registry knows the voice under.
    static func systemIdentifier(for modelInfo: ModelInfo, speakerId: Int) -> String {
        identifierPrefix + piperVoiceId(for: modelInfo, speakerId: speakerId)
    }

    /// The live probe. `lookup` is injectable so tests can answer
    /// without the system registry.
    static func isVisible(
        modelInfo: ModelInfo,
        speakerId: Int,
        lookup: (String) -> Bool = { AVSpeechSynthesisVoice(identifier: $0) != nil }
    ) -> Bool {
        lookup(systemIdentifier(for: modelInfo, speakerId: speakerId))
    }

    /// Asks the system to re-scan the provider voices. The re-scan is
    /// asynchronous: callers re-probe after a short delay.
    static func requestRescan() {
        AVSpeechSynthesisProviderVoice.updateSpeechVoices()
    }
}
