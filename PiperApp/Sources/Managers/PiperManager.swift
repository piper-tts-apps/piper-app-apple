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
    
    func playSample(demoText: String,
                    speakerId: Int,
                    modelInfo: ModelInfo) async {
#if os(iOS)
        activatePlaybackMode()
        setAudioSession(active: true)
#endif
        await setIsPlaying(true)
        if modelInfo.installedPath?.isInstalled == true {
            let piperVoiceId = if modelInfo.numberOfSpeakers > 1 {
                "\(modelInfo.voiceId)\(Constants.speakerIdSeparator)\(speakerId)"
            } else {
                modelInfo.voiceId
            }
            if let voice = AVSpeechSynthesisVoice(identifier: "dev.ihor-shevchuk.piperapp.pipertts.\(piperVoiceId)") {
                syntheser = SpeechSynthesizer()
                await syntheser?.speak(demoText, voice: voice)
            } else {
                await audioUnit.play(text: demoText,
                                     piperVoiceId: piperVoiceId)
            }
        }
        
        await stopPlaying()
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
        let piperVoiceId = if modelInfo.numberOfSpeakers > 1 {
            "\(modelInfo.voiceId)\(Constants.speakerIdSeparator)\(speakerId)"
        } else {
            modelInfo.voiceId
        }
        
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
