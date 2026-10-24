// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import SwiftUI
import PiperAppUtils

struct SettingsView: View {

    @StateObject var hostModel: SettingsHostModel
    @AppStorage(ModelFormat.userDefaultsKey) private var modelFormat: ModelFormat = .standard
    @AppStorage(StreamingVoices.userDefaultsKey) private var streamingVoices: Bool = true

#if os(iOS)
    private let platform = "iOS"
#elseif(os(macOS))
    private let platform = "macOS"
#else
#error("Unsupported platform")
#endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("model_format", selection: $modelFormat) {
                        Text("model_format_standard").tag(ModelFormat.standard)
                        Text("model_format_compact").tag(ModelFormat.compact)
                    }
                    .pickerStyle(.menu)
                    Toggle("streaming_voices", isOn: $streamingVoices)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("model_format_description")
                        Text("streaming_voices_description")
                    }
                }

                Section {
                    NavigationLink {
                        ImportVoiceHostModelView(hostModel: ImportVoiceHostModel(piper: hostModel.piper,
                                                                                 delegate: hostModel.modelChangeDelegate))
                    } label: {
                        Text("update_model_in_app")
                    }
                }

                Section("credits_and_legal") {
                    VStack {
                        Text("license_audio_unit_title").font(.headline)
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                        HStack {
                            Spacer()
                            AboutLibView(libTitle: "Piper1-GPL",
                                         url: "https://github.com/OHF-Voice/piper1-gpl",
                                         description: String(localized: "license_piper_description"))

                            Spacer()
                            Divider()
                            Spacer()
                            AboutLibView(libTitle: "eSpeak-NG",
                                         url: "https://github.com/espeak-ng/espeak-ng-spm",
                                         description: String(localized: "license_espeak_ng_description"))
                            Spacer()
                        }
                        .padding(.bottom)
                        Text("license_audio_unit_description")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    HStack {
                        Spacer()
                        AboutLibView(libTitle: String(localized: "license_main_app_\(platform)_title"),
                                     url: "https://github.com/piper-tts-apps/piper-app-apple",
                                     description: String(localized: "license_main_app_description"))
                        Spacer()
                    }
                }

                NavigationLink {
                    VoiceLicensesView(hostModel: VoiceLicensesHostModel())
                } label: {
                    Text("voice_licenses")
                }

                InfoViewRow(title: "audio_unit_status".localized, value: hostModel.viewModel.connectionStatus.string)
                if hostModel.viewModel.connectionStatus != .connected {
                    Button {
                        hostModel.connect()
                    } label: {
                        CenteredContent {
                            Text("connect")
                        }
                    }
                }

                InfoViewRow(title: "app_version".localized, value: hostModel.viewModel.appVersion)

                if let feedbackURL = URL(string: "mailto:piper-feedback@ihor-shevchuk.dev?subject=Piper%20feedback") {
                    Link("share_feedback", destination: feedbackURL)
                }
            }
            .navigationTitle("settings")
        } // NavigationStack
    }
}
