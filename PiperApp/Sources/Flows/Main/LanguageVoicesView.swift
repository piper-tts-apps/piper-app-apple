// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import SwiftUI
import PiperAppUtils

/// The voices of one language, pushed both from the "Languages"
/// list and from the "Installed languages" section of the main
/// screen - the same list either way.
///
/// `voices` is the merged list: catalog voices plus installed-only
/// voices as synthetic `Voice` rows, sorted together. Installed-only
/// voices (imported / own trained voices) therefore appear in the
/// same section as catalog voices, instead of a separate section,
/// and their rows navigate to the same detail screen.
struct LanguageVoicesView: View {

    @ObservedObject var hostModel: MainHostModel
    let languageCode: String

    private var voices: [Voice] {
        hostModel.voices(for: languageCode)
    }

    var body: some View {
        List {
            if voices.isEmpty {
                Text("no_voices")
                    .font(.title2)
            } else {
                Section {
                    Text("warning_not_tested_voices")
                        .font(.title2)
                        .accessibilityHidden(false)
                }
                Section {
                    ForEach(voices, id: \.key) { voice in
                        VoiceRowView(hostModel: hostModel, voice: voice)
                    }
                }
                Section {
                    Text("warning_big_voice_files")
                        .font(.title2)
                        .accessibilityHidden(false)
                }
            }
        }
        .navigationTitle(languageCode.localizedLanguageFromCode)
    }
}
