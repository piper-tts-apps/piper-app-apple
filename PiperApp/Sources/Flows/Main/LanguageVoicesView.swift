// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import SwiftUI
import PiperAppUtils

/// The voices of one language, pushed both from the "Languages"
/// list and from the "Installed languages" section of the main
/// screen - the same list either way.
struct LanguageVoicesView: View {

    @ObservedObject var hostModel: MainHostModel
    let languageCode: String

    private var voices: [Voice] {
        hostModel.voices(for: languageCode)
    }

    /// Installed voices of this language with no catalog entry
    /// (imported / own trained voices): without these rows they
    /// counted in Installed languages but could not be opened.
    private var installedOnly: [FileManager.ModelPaths] {
        hostModel.installedOnlyModels(for: languageCode)
    }

    var body: some View {
        List {
            if voices.isEmpty && installedOnly.isEmpty {
                Text("no_voices")
                    .font(.title2)
            } else {
                if !voices.isEmpty {
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
                if !installedOnly.isEmpty {
                    Section {
                        ForEach(installedOnly, id: \.info?.voiceId) { model in
                            NavigationLink {
                                VoiceView(hostModel: VoiceHostModel(piper: hostModel.piper,
                                                                    modelPaths: model,
                                                                    delegate: hostModel))
                            } label: {
                                Text(model.modelTitle)
                                    .font(.title2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(languageCode.localizedLanguageFromCode)
    }
}
