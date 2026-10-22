// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import SwiftUI
import PiperAppUtils

struct VoiceItemView: View {

    @StateObject var hostModel: VoiceItemHostModel
    /// Search results are a flat list without language sections, so
    /// their rows name the voice's language explicitly.
    var showsLanguage: Bool = false
    var voice: Voice {
        hostModel.viewModel.voice
    }

    @ViewBuilder
    private func imageView(systemName: String) -> some View {
        let buttonSize = 50.0
        Image(systemName: systemName)
            .imageScale(.large)
            .frame(width: buttonSize, height: buttonSize)
            .foregroundColor(.accentColor)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func playDemo() -> some View {

        if hostModel.viewModel.isPlaying {
            Button {
                hostModel.stopPlaying()
            } label: {
                imageView(systemName: "stop")
                    .accessibilityLabel("stop_playing")
                    .accessibilityHint("stop_playing_hint")
            }
            .buttonStyle(.borderless)
        } else if hostModel.viewModel.isSampleLoading {
            let size = 50.0
            ProgressView()
                .progressViewStyle(.circular)
                .frame(width: size, height: size)
                .accessibilityLabel("loading_sample")
        } else {
            Button {
                hostModel.playSample(voice: hostModel.viewModel.voice)
            } label: {
                imageView(systemName: "play")
                    .accessibilityLabel("play_sample")
                    .accessibilityHint("play_sample_hint")
            }
            .buttonStyle(.borderless)
        }
    }

    @State var unstallConfirmationShown: Bool = false

    @ViewBuilder
    private func cancelDownloadButton(size: Double) -> some View {
        Button {
            hostModel.cancelDownload(voice: voice)
        } label: {
            ZStack {
                CircularProgressView(progress: hostModel.viewModel.downloadProgress)
                    .frame(width: size, height: size)
                Image(systemName: "stop.fill")
                    .imageScale(.small)
                    .foregroundColor(.accentColor)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("cancel_download")
        .accessibilityValue("\(Int(hostModel.viewModel.downloadProgress * 100))%")
    }

    @ViewBuilder
    private func updateButton() -> some View {
        Button {
            hostModel.download(voice: voice)
        } label: {
            imageView(systemName: "arrow.down.circle.fill")
                .accessibilityLabel("update_voice")
                .accessibilityHint("update_voice_hint")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func uninstallButton() -> some View {
        Button {
            unstallConfirmationShown.toggle()
        } label: {
            imageView(systemName: "trash")
                .accessibilityLabel("uninstall_voice")
                .accessibilityHint("uninstall_voice_hint")
        }
        .buttonStyle(.borderless)
    }

    /// The row's commands, shared by the VoiceOver custom actions
    /// (surfaced through the rotor) and the long-press context menu,
    /// so each voice can be played, downloaded, updated or removed
    /// without opening its detail screen.
    @ViewBuilder
    private func voiceActions() -> some View {
        if hostModel.viewModel.isPlaying {
            Button("stop_playing") {
                hostModel.stopPlaying()
            }
        } else if !hostModel.viewModel.isSampleLoading {
            Button("play_sample") {
                hostModel.playSample(voice: voice)
            }
        }
        if hostModel.viewModel.isDownloading {
            Button("cancel_download") {
                hostModel.cancelDownload(voice: voice)
            }
        } else if hostModel.isInstalled(voice) {
            if hostModel.viewModel.updateAvailable {
                Button("update_voice") {
                    hostModel.download(voice: voice)
                }
            }
            Button("uninstall_voice", role: .destructive) {
                unstallConfirmationShown = true
            }
        } else {
            Button("download_voice") {
                hostModel.download(voice: voice)
            }
        }
    }

    @ViewBuilder
    private func downloadButton() -> some View {
        Button {
            hostModel.download(voice: voice)
        } label: {
            imageView(systemName: "square.and.arrow.down")
                .accessibilityLabel("download_voice")
                .accessibilityHint("download_voice_hint")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func download() -> some View {
        let size = 50.0
        HStack {
            // Downloading is checked first: an update is a download
            // of an installed voice, and its progress (tap to
            // cancel) must win over the installed-state controls.
            if hostModel.viewModel.isDownloading {
                cancelDownloadButton(size: size)
            } else if hostModel.isInstalled(voice) {
                if hostModel.viewModel.updateAvailable {
                    updateButton()
                } else {
                    uninstallButton()
                }
            } else {
                downloadButton()
            }
        }

    }

    var body: some View {
        let voiceTitle = voice.name.capitalized + " " + voice.quality + " "
        let languageName = voice.language.code.localizedLanguageFromCode
        let baseAccessibilityLabel = showsLanguage ? voiceTitle + languageName : voiceTitle
        let licenseSuffix = voice.license.map {
            ", \("voice_license".localized): \($0)"
        } ?? ""
        let showsUpdate = hostModel.viewModel.updateAvailable && hostModel.isInstalled(voice)
        let updateSuffix = showsUpdate ? ", \("update_available".localized)" : ""
        let isDownloading = hostModel.viewModel.isDownloading
        let downloadingSuffix = isDownloading ? ", \("downloading".localized)" : ""
        let accessibilityLabel = baseAccessibilityLabel + licenseSuffix + updateSuffix + downloadingSuffix
        let accessibilityValue = isDownloading ? "\(Int(hostModel.viewModel.downloadProgress * 100))%" : ""
        // "Double tap for details" only fits an installed voice: its
        // row is a navigation link. A catalog row has no detail screen
        // to open, so it gets no hint.
        let accessibilityHint: LocalizedStringKey = hostModel.isInstalled(voice) ? "voice_item_hint" : ""
        HStack {
            Spacer()
                .frame(width: 10)
            VStack {
                HStack {
                    Text(voiceTitle)
                        .font(.title)
                    Spacer()
                }
                HStack {
                    if showsLanguage {
                        Text(languageName + " · " + voice.voiceSizeString)
                            .font(.body)
                    } else {
                        Text(voice.voiceSizeString)
                            .font(.body)
                    }
                    Spacer()
                }
                if showsUpdate {
                    HStack {
                        Text("update_available")
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                        Spacer()
                    }
                }
                if let license = voice.license {
                    HStack {
                        Text("\("voice_license".localized): \(license)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            Spacer()
            playDemo()
            download()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityActions {
            voiceActions()
        }
        .contextMenu {
            voiceActions()
        }
        .alert("uninstall_voice", isPresented: $unstallConfirmationShown) {
            Button("uninstall_button", role: .destructive) {
                hostModel.remove(voice: voice)
            }
            Button("cancel", role: .cancel) {
                unstallConfirmationShown.toggle()
            }
        }
    }
}
