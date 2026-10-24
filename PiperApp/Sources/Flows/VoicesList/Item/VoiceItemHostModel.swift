// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import Combine
import PiperAppUtils
import AVFoundation

class VoiceItemHostModel: @unchecked Sendable, ObservableObject {
    @Published var viewModel: VoiceItemViewModel
    let piper: PiperManager
    let loader: VoiceLoader
    var languages: [String: [Voice]] = [:]
    weak var delegate: ModelChangeDelegate?
    private var avPlayerRateObserver: NSKeyValueObservation!
    private var avItemStateObserver: NSKeyValueObservation!
    private var playingCancellable: AnyCancellable?
    private var downloadsCancellable: AnyCancellable?
    private var updatesCancellable: AnyCancellable?
    /// True while this row is playing a sample with the installed model
    /// itself (through PiperManager) rather than the hosted sample file.
    /// PiperManager.isPlaying is global, so rows use this flag to react
    /// only to playback they started.
    private var isPlayingInstalledSample = false

    private var audioPlayer: AVPlayer?
    init(piper: PiperManager,
         loader: VoiceLoader,
         voice: Voice,
         delegate: ModelChangeDelegate?) {
        viewModel = VoiceItemViewModel(voice: voice)
        self.piper = piper
        self.loader = loader
        self.delegate = delegate
        activatePlaybackMode()
        playingCancellable = piper.$isPlaying.sink { [weak self] isPlaying in
            guard let self = self, self.isPlayingInstalledSample else {
                return
            }
            self.viewModel.isPlaying = isPlaying
            if !isPlaying {
                self.isPlayingInstalledSample = false
            }
        }
        downloadsCancellable = loader.$downloadProgress.sink { [weak self] downloads in
            guard let self = self else { return }
            if let progress = downloads[self.viewModel.voice.key] {
                self.viewModel.isDownloading = true
                self.viewModel.downloadProgress = progress
            } else {
                self.viewModel.isDownloading = false
                self.viewModel.downloadProgress = 0
            }
        }
        updatesCancellable = loader.$updateAvailableKeys.sink { [weak self] keys in
            guard let self = self else { return }
            self.viewModel.updateAvailable = keys.contains(self.viewModel.voice.key)
        }
    }

    deinit {
        stopPlaying()
    }

    func download(voice: Voice) {
        Task { [weak self] in
            guard let self else { return }
            // The loader's registry refuses a second download of the
            // same voice; every row observes progress from there. The
            // session token scopes this download's teardown so a late
            // finish after a cancel cannot disturb a newer download.
            let session = await loader.beginDownload(for: voice.key)
            guard let session else { return }
            defer {
                Task { await self.loader.endDownload(for: voice.key, session: session) }
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
                Log.debug("Download cancelled for voice: \(voice.key)")
            } catch is CancellationError {
                Log.debug("Download cancelled for voice: \(voice.key)")
            } catch {
                Log.error("Failed to download voices: \(error)")
            }
        }
    }

    func cancelDownload(voice: Voice) {
        Task {
            await loader.cancelDownload(for: voice.key)
        }
    }

    func remove(voice: Voice) {
        guard let installed = installed(voice) else {
            return
        }
        if isPlayingInstalledSample {
            stopPlaying()
        }
        piper.unstall(paths: installed)
        delegate?.modelDidChange()
    }

    func isInstalled(_ voice: Voice) -> Bool {
        return installed(voice) != nil
    }

    private func installed(_ voice: Voice) -> FileManager.ModelPaths? {
        Self.installedPaths(for: voice, in: piper.installedVoices)
    }

    static func installedPaths(for voice: Voice,
                               in installed: [FileManager.ModelPaths]) -> FileManager.ModelPaths? {
        installed.first { modelPath in
            // Prefer the catalog key recorded at install time: some model
            // configs carry metadata that does not match the catalog entry.
            if let catalogKey = modelPath.catalogKey {
                return catalogKey == voice.key
            }
            guard let modelInfo = modelPath.info else {
                return false
            }
            return modelInfo.dataset == voice.name && modelInfo.audio.quality == voice.quality
        }
    }

    func stopPlaying() {
        if isPlayingInstalledSample {
            isPlayingInstalledSample = false
            let piper = self.piper
            Task {
                await piper.stopPlaying()
            }
        }
        NotificationCenter.default.removeObserver(self, name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil)
        audioPlayer?.pause()
        audioPlayer = nil
        avPlayerRateObserver = nil
        avItemStateObserver = nil
        viewModel.isPlaying = false
        viewModel.isSampleLoading = false
        setAudioSession(active: false)
    }

    func playSample(voice: Voice) {
        // An installed voice plays itself: synthesize the demo text with
        // the local model (the same path as the voice detail screen)
        // instead of streaming the hosted sample file.
        if let modelInfo = installed(voice)?.info {
            playInstalledSample(modelInfo: modelInfo)
            return
        }

        guard let sampleURL = loader.sampleURL(for: voice) else {
            return
        }

        NotificationCenter.default.addObserver(self, selector: #selector(self.playerItemDidPlayToEndTime(notification:)),
                                               name: AVPlayerItem.didPlayToEndTimeNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.playerItemDidPlayToEndTime(notification:)),
                                               name: AVPlayerItem.failedToPlayToEndTimeNotification,
                                               object: nil)
        playSample(voice: voice, url: sampleURL, fallbackAttempted: false)
    }

    private func playInstalledSample(modelInfo: ModelInfo) {
        stopPlaying()
        isPlayingInstalledSample = true
        let demoText = DemoText.text(for: modelInfo.language) ?? DemoText.defaultText
        let piper = self.piper
        Task {
            await piper.playSample(demoText: demoText,
                                   speakerId: 0,
                                   modelInfo: modelInfo)
        }
    }

    private func playSample(voice: Voice, url: URL, fallbackAttempted: Bool) {
        setAudioSession(active: true)
        viewModel.isSampleLoading = true

        let item = AVPlayerItem(url: url)
        audioPlayer = AVPlayer(playerItem: item)
        self.avPlayerRateObserver = audioPlayer?.observe(\.rate, options: [.new]) { [weak self] player, _ in
            self?.viewModel.isPlaying = player.rate == 1.0
        }

        self.avItemStateObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            self?.viewModel.isSampleLoading = item.status != .readyToPlay && item.status != .failed
            if item.status == .failed {
                self?.handleSampleFailure(voice: voice, fallbackAttempted: fallbackAttempted)
            }
        }
        audioPlayer?.volume = 1.0
        audioPlayer?.play()
    }

    private func handleSampleFailure(voice: Voice, fallbackAttempted: Bool) {
        // Our hosted sample may be missing; retry once with the community sample.
        if !fallbackAttempted, let fallbackURL = loader.fallbackSampleURL(for: voice) {
            audioPlayer?.pause()
            audioPlayer = nil
            avPlayerRateObserver = nil
            avItemStateObserver = nil
            playSample(voice: voice, url: fallbackURL, fallbackAttempted: true)
        } else {
            stopPlaying()
        }
    }

    @objc func playerItemDidPlayToEndTime(notification: NSNotification) {
        stopPlaying()
    }

    func activatePlaybackMode() {
#if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch let error {
            Log.error("Error happened during activating playback. Error:\(error)")
        }
#endif
    }

    func setAudioSession(active: Bool) {
#if !os(macOS)
        do {
            try AVAudioSession.sharedInstance().setActive(active)
        } catch let error {
            Log.error("Error happened during setting audio session active status:\(active)  Error:\(error)")
        }
#endif
    }
}
