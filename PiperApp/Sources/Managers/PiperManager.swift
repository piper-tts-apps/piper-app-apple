// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils
import AVFoundation

class PiperManager {
    var installedVoices: [FileManager.ModelPaths] {
        FileManager.ModelPaths.installedModels
    }

    @Published var isPlaying: Bool = false
    @MainActor
    func setIsPlaying(_ isPlaying: Bool) {
        self.isPlaying = isPlaying
    }
    let audioUnit = PiperAudioUnit()
    private var syntheser: SpeechSynthesizer?
    
#if os(iOS)
    func activatePlaybackMode() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch let error {
            Log.error("Error happened during activating playback. Error:\(error)")
        }
    }
    
    func setAudioSession(active: Bool) {
        do {
            try AVAudioSession.sharedInstance().setActive(active)
        } catch let error {
            Log.error("Error happened during setting audio session active status:\(active)  Error:\(error)")
        }
    }
#endif
    
    /// Which engine renders a sample: the system voice when the
    /// registry lists it, otherwise local synthesis of the
    /// installed model. `lookup` is injectable so tests can
    /// answer without the system registry.
    enum PlaybackRoute {
        case systemVoice(AVSpeechSynthesisVoice)
        case localSynthesis
    }

    func playbackRoute(for modelInfo: ModelInfo,
                       speakerId: Int,
                       lookup: (String) -> AVSpeechSynthesisVoice? = { AVSpeechSynthesisVoice(identifier: $0) }) -> PlaybackRoute {
        if let voice = lookup(SystemVoiceVisibility.systemIdentifier(for: modelInfo, speakerId: speakerId)) {
            return .systemVoice(voice)
        }
        return .localSynthesis
    }

    func playSample(demoText: String,
                    speakerId: Int,
                    modelInfo: ModelInfo) async {
#if os(iOS)
        activatePlaybackMode()
        setAudioSession(active: true)
#endif
        await setIsPlaying(true)
        if modelInfo.installedPath?.isInstalled == true {
            switch playbackRoute(for: modelInfo, speakerId: speakerId) {
            case .systemVoice(let voice):
                syntheser = SpeechSynthesizer()
                await syntheser?.speak(demoText, voice: voice)
            case .localSynthesis:
                await audioUnit.play(text: demoText,
                                     piperVoiceId: SystemVoiceVisibility.piperVoiceId(for: modelInfo, speakerId: speakerId))
            }
        }
        
        await stopPlaying()
    }

    /// Plays a sample by rendering the installed model locally,
    /// never consulting the system voice registry. The voice
    /// detail screen uses this: its preview must work for an
    /// installed voice even when the system has not
    /// (re-)registered it for VoiceOver. The guard is the voice's
    /// files on disk (not the installed-models list, which the
    /// test host cannot see): playback needs the files, not the
    /// registry. Returns true when local playback was attempted,
    /// false when the voice's files are not on disk.
    @discardableResult
    func playSampleLocally(demoText: String,
                           speakerId: Int,
                           paths: FileManager.ModelPaths) async -> Bool {
        guard let modelInfo = paths.info, paths.exist else {
            return false
        }
#if os(iOS)
        activatePlaybackMode()
        setAudioSession(active: true)
#endif
        await setIsPlaying(true)
        await audioUnit.play(text: demoText,
                             piperVoiceId: SystemVoiceVisibility.piperVoiceId(for: modelInfo, speakerId: speakerId))
        await stopPlaying()
        return true
    }
    
    func stopPlaying() async {
        #if os(iOS)
        setAudioSession(active: false)
        #endif
        syntheser?.stop()
        syntheser = nil
        audioUnit.stop()
        await setIsPlaying(false)
    }
    
    func synthesizeToFile(text: String,
                          to file: String,
                          speakerId: Int,
                          modelInfo: ModelInfo) async throws {
        let piperVoiceId = SystemVoiceVisibility.piperVoiceId(for: modelInfo, speakerId: speakerId)
        
        try await audioUnit.save(text: text, piperVoiceId: piperVoiceId, to: file)
    }
    
    func install(paths: FileManager.ModelPaths?,
                 catalogKey: String? = nil,
                 encoder: URL? = nil,
                 decoder: URL? = nil) async {
        do {
            await audioUnit.disconnect()
            try FileManager.default.install(paths: paths,
                                            catalogKey: catalogKey,
                                            encoder: encoder,
                                            decoder: decoder)
            AVSpeechSynthesisProviderVoice.updateSpeechVoices()
            await audioUnit.connect()
        } catch {
            Log.error("Error happened during installing. Error:\(error)")
        }
    }
    
    /// Installs files a catalog download produced and removes the
    /// temporary download files afterwards. For a splits-only download
    /// the paths' model is an anchor with no file behind it; its split
    /// parts sit at the derived encoder/decoder URLs and are passed
    /// through so the install stores them instead of a full model.
    func installDownloaded(paths: FileManager.ModelPaths, catalogKey: String?) async {
        let splitsOnly = !FileManager.default.fileExists(atPath: paths.model.path) && paths.hasSplitModel
        await install(paths: paths,
                      catalogKey: catalogKey,
                      encoder: splitsOnly ? paths.encoder : nil,
                      decoder: splitsOnly ? paths.decoder : nil)
        try? FileManager.default.removeItem(at: paths.json)
        try? FileManager.default.removeItem(at: paths.model)
        if splitsOnly {
            try? FileManager.default.removeItem(at: paths.encoder)
            try? FileManager.default.removeItem(at: paths.decoder)
            // The downloaded parts lived in their own temporary folder
            // (see VoiceLoader); remove it once it is empty.
            try? FileManager.default.removeItem(at: paths.model.deletingLastPathComponent())
        }
    }

    func unstall(paths: FileManager.ModelPaths) {
        if !paths.exist {
            Log.debug("Nothing to uninstall")
            return
        }

        do {
            try FileManager.default.uninstall(paths: paths)
            AVSpeechSynthesisProviderVoice.updateSpeechVoices()
        } catch {
            Log.error("Error happened during uninstalling. Error:\(error)")
        }
    }
}
