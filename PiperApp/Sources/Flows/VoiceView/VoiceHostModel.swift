// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import Combine
import PiperAppUtils

class VoiceHostModel: @unchecked Sendable, ObservableObject {
    @Published var viewModel: VoiceViewModel
    private var playingCancellable: AnyCancellable?
    private var updatesCancellable: AnyCancellable?
    private var downloadsCancellable: AnyCancellable?
    let piper: PiperManager
    /// The catalog entry for this installed voice, when the screen
    /// was reached from a catalog row: it enables the update flow.
    /// Nil for installed-only entries (e.g. ungrouped models).
    let voice: Voice?
    let loader: VoiceLoader?
    weak var delegate: ModelChangeDelegate?

    init(piper: PiperManager,
         modelPaths: FileManager.ModelPaths,
         delegate: ModelChangeDelegate?,
         voice: Voice? = nil,
         loader: VoiceLoader? = nil) {
        self.piper = piper
        viewModel = VoiceViewModel(paths: modelPaths,
                                   modelInfo: modelPaths.info)
        self.delegate = delegate
        self.voice = voice
        self.loader = loader
        updateSample()
        playingCancellable = piper.$isPlaying.sink { [weak self] isPlaying in
            guard let self = self else {
                return
            }
            self.viewModel.isPlaying = isPlaying
        }
        if let voice, let loader {
            updatesCancellable = loader.$updateAvailableKeys.sink { [weak self] keys in
                self?.viewModel.updateAvailable = keys.contains(voice.key)
            }
            downloadsCancellable = loader.$downloadProgress.sink { [weak self] downloads in
                guard let self = self else {
                    return
                }
                if let progress = downloads[voice.key] {
                    self.viewModel.isUpdating = true
                    self.viewModel.updateProgress = progress
                } else {
                    self.viewModel.isUpdating = false
                    self.viewModel.updateProgress = 0
                }
            }
        }
    }

    /// Downloads the catalog build of this voice over the installed
    /// one, through the loader's shared session registry (the same
    /// flow as the row's Update button): the installed model stays
    /// in place until the new files are complete and installed.
    func downloadUpdate() {
        guard let voice, let loader else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let session = await loader.beginDownload(for: voice.key)
            guard let session else { return }
            defer {
                Task { await loader.endDownload(for: voice.key, session: session) }
            }
            do {
                for try await event in loader.download(voice: voice, session: session) {
                    switch event {
                    case .progress(let value):
                        await loader.updateDownloadProgress(value, for: voice.key)

                    case .finished(let modelPath):
                        await self.piper.installDownloaded(paths: modelPath, catalogKey: voice.key)
                        self.delegate?.modelDidChange()
                    }
                }
            } catch let error as URLError where error.code == .cancelled {
                Log.debug("Update cancelled for voice: \(voice.key)")
            } catch is CancellationError {
                Log.debug("Update cancelled for voice: \(voice.key)")
            } catch {
                Log.error("Failed to update voice: \(error)")
            }
        }
    }

    func cancelUpdate() {
        guard let voice, let loader else {
            return
        }
        Task {
            await loader.cancelDownload(for: voice.key)
        }
    }

    deinit {
        let piper = self.piper
        Task {
            await piper.stopPlaying()
        }
    }

    func updateSample() {
        guard let language = viewModel.paths.info?.language,
              let sample = DemoText.text(for: language) else {
            return
        }
        viewModel.demoText = sample
    }

    func uninstall() {
        Task {
            await piper.stopPlaying()
        }
        piper.unstall(paths: viewModel.paths)
        delegate?.modelDidChange()
    }

    func play() {
        guard let modelInfo = viewModel.modelInfo else {
            return
        }
        let demoText = viewModel.demoText
        let piper = self.piper
        let isPlaying = self.viewModel.isPlaying
        let speakerId = self.viewModel.selectedSpeaker
        Task {
            if isPlaying {
                await piper.stopPlaying()
            } else {
                await piper.playSample(demoText: demoText,
                                            speakerId: speakerId,
                                            modelInfo: modelInfo)
            }
        }
    }
}

extension VoiceHostModel: VoiceFileSyntehesizer {

    enum Error: Swift.Error {
        case modelIsNotAvailable
    }

    var fileName: String {
        guard let modelInfo = viewModel.modelInfo else {
           return UUID().uuidString
        }
        return "\(modelInfo.name)_\(Int.random(in: 0...10000))"
    }

    func syntehesize(text: String, to file: String) async throws {
        guard let modelInfo = viewModel.modelInfo else {
            throw Error.modelIsNotAvailable
        }

        try await self.piper.synthesizeToFile(text: viewModel.demoText,
                                              to: file,
                                              speakerId: self.viewModel.selectedSpeaker,
                                              modelInfo: modelInfo)
    }
}
