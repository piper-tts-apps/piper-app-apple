// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import Combine
import AVFoundation
import PiperAppUtils

class VoiceHostModel: @unchecked Sendable, ObservableObject {
    @Published var viewModel: VoiceViewModel
    /// True while a system re-scan is in flight after "Check again".
    /// Kept on the host model rather than inside the view-model
    /// struct, so the view observes a plain @Published flag that
    /// flips on every tap.
    @Published var isRefreshingSystemVoices: Bool = false
    private var playingCancellable: AnyCancellable?
    private var updatesCancellable: AnyCancellable?
    private var downloadsCancellable: AnyCancellable?
    private var speakerCancellable: AnyCancellable?
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
        refreshSystemVisibility()
        // The visibility check is per speaker: re-probe when the
        // picker changes the speaker (dropFirst: init already probed).
        speakerCancellable = $viewModel.map(\.selectedSpeaker)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.refreshSystemVisibility() }
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

    /// Re-probes the system registry for the selected speaker.
    func refreshSystemVisibility() {
        guard let modelInfo = viewModel.modelInfo else {
            viewModel.isSystemVoiceVisible = true
            return
        }
        viewModel.isSystemVoiceVisible = SystemVoiceVisibility.isVisible(modelInfo: modelInfo,
                                                                          speakerId: viewModel.selectedSpeaker)
    }

    /// Asks the system to re-scan the provider voices and re-probes
    /// after a short delay: the re-scan is asynchronous, so an
    /// immediate re-probe would still see the stale registry.
    /// A tap while a re-scan is already in flight is ignored, and
    /// the refreshing flag is reset in a defer so a cancelled or
    /// failed wait can never leave the spinner stuck on.
    func refreshSystemVoices() {
        guard viewModel.modelInfo != nil else {
            return
        }
        guard !isRefreshingSystemVoices else {
            return
        }
        isRefreshingSystemVoices = true
        SystemVoiceVisibility.requestRescan()
        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRefreshingSystemVoices = false
                    self.refreshSystemVisibility()
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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
        guard viewModel.modelInfo != nil else {
            return
        }
        let demoText = viewModel.demoText
        let piper = self.piper
        let isPlaying = self.viewModel.isPlaying
        let speakerId = self.viewModel.selectedSpeaker
        let paths = viewModel.paths
        Task {
            if isPlaying {
                await piper.stopPlaying()
            } else {
                // The detail-screen preview always renders the
                // installed model locally: it must not depend on
                // the system registry, so a voice the system has
                // not (re-)registered still plays its sample.
                await piper.playSampleLocally(demoText: demoText,
                                              speakerId: speakerId,
                                              paths: paths)
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
