// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import AVFAudio
import Combine
import PiperAppUtils

class PiperAudioUnit {

    enum AudioUnitError: Error {
        case notInitialized
    }

    @MainActor @Published private(set) var status: PiperAudioUnit.Status = .disconnected

    private func setStatus(_ status: PiperAudioUnit.Status) {
        DispatchQueue.main.async {
            self.status = status
        }
    }

    private var audioUnit: AVAudioUnit?
    private let engine = AVAudioEngine()
    private var messageChannel: AUMessageChannel?
    private var cancellables = Set<AnyCancellable>()
    private var healthCheckTimer: Timer?
    private let manager = AVAudioUnitComponentManager.shared()

    private func startHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, let unit = self.audioUnit?.auAudioUnit else { return }
            if !self.engine.isRunning || !unit.renderResourcesAllocated {
                self.setStatus(.disconnected)
                Task { await self.reconnect() }
            }
        }
    }

    private func invalidateHealthCheckTimer() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func handleEngineConfigurationChange() {
        if !engine.isRunning || !(audioUnit?.auAudioUnit.renderResourcesAllocated ?? false) {
            Task { await reconnect() }
        }
    }
#if !os(macOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            setStatus(.disconnected)
        case .ended:
            Task { await reconnect() }
        @unknown default:
            break
        }
    }
#endif

    func loadAudioUnit(with description: AudioComponentDescription) async throws -> AVAudioUnit {
        let components = manager.components(matching: description)
        var internalError: Error = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_ExtensionNotFound), userInfo: [:])
        for component in components {
            do {
                return try await AVAudioUnit.instantiate(with: component.audioComponentDescription, options: [.loadOutOfProcess])
            } catch {
                internalError = error
            }
        }
        throw internalError
    }

    func connect() async {
        Log.debug("Connecting audio unit...")
        let componentDescription = AudioComponentDescription(componentType: kAudioUnitType_SpeechSynthesizer,
                                                             componentSubType: "pipr".audioComponentOSType,
                                                             componentManufacturer: "pipr".audioComponentOSType,
                                                             componentFlags: AudioComponentFlags([.sandboxSafe, .isV3AudioUnit]).rawValue,
                                                             componentFlagsMask: AudioComponentFlags([.sandboxSafe, .isV3AudioUnit]).rawValue
        )
        do {
            let audioUnit = try await loadAudioUnit(with: componentDescription)

            if engine.isRunning {
                engine.stop()
            }
            self.engine.attach(audioUnit)
            self.engine.isAutoShutdownEnabled = false

            self.messageChannel = audioUnit.auAudioUnit.messageChannel(for: "\(Self.Type.self)")
            self.audioUnit = audioUnit

            let unit = audioUnit.auAudioUnit
            try? unit.allocateRenderResourcesIfNeeded()

            setStatus(.connected)
            self.setUpEngineObservers()
            self.startHealthCheckTimer()
            Log.debug("Connected audio unit successfully.")
        } catch {
            Log.error("Failed to connect audio unit: \(error)")
            setStatus(.failedToConnect)
        }
    }

    func disconnect() async {
        Log.debug("Disconnecting audio unit...")
        invalidateHealthCheckTimer()
        cancellables.removeAll()
        if engine.isRunning {
            engine.stop()
        }
        self.audioUnit?.reset()
        self.audioUnit = nil
        setStatus(.disconnected)
        Log.debug("Disconnected audio unit successfully.")
    }

    func reconnect() async {
        await disconnect()
        try? await Task.sleep(for: .seconds(2.0))
        await connect()
    }

    func play(text: String,
              piperVoiceId: String) async {

        guard let audioUnit else {
            Log.error("Audio unit is nil. Can't play text.")
            return
        }

        connect(to: audioUnit, output: engine.outputNode)

        let request = AVSpeechSynthesisProviderRequest(simpeText: text, piperId: piperVoiceId)

        guard let request else {
            Log.error("Can't create request. Can't play text.")
            return
        }

        let auAudioUnit = audioUnit.auAudioUnit
        try? auAudioUnit.allocateRenderResourcesIfNeeded()

        do {
            try self.engine.start()
        } catch {
            Log.error("Failed to start audio engine: \(error)")
            await reconnect()
        }

        try? auAudioUnit.handleSpeechRequest(request)
        await withCheckedContinuation { [weak self] continuation in
            guard let self else {
                return
            }
            Task { [weak self] in
                guard let self else {
                    return
                }
                if !self.isSynthesizing {
                    try? await Task.sleep(for: .seconds(1.0))
                }
                while self.isSynthesizing {
                    try? await Task.sleep(for: .seconds(1.0))
                }
                continuation.resume()
            }
        }
        engine.stop()
    }

    private func createAudioBuffer(format: AVAudioFormat, maxFrames: AVAudioFrameCount) -> (UnsafeMutablePointer<AudioBufferList>, () -> Void) {
        let sampleSize = MemoryLayout<Float32>.size
        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        bufferListPtr.pointee.mNumberBuffers = format.channelCount

        let rawBuffer = UnsafeMutableRawPointer.allocate(byteCount: Int(maxFrames) * sampleSize, alignment: sampleSize)
        bufferListPtr.pointee.mBuffers = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(Int(maxFrames) * sampleSize),
            mData: rawBuffer
        )

        let cleanup = {
            rawBuffer.deallocate()
            bufferListPtr.deallocate()
        }
        return (bufferListPtr, cleanup)
    }

    func save(text: String,
              piperVoiceId: String,
              to file: String) async throws {
        guard let audioUnit else {
            throw AudioUnitError.notInitialized
        }
        let auAudioUnit = audioUnit.auAudioUnit

        connect(to: audioUnit, output: engine.mainMixerNode)
        try engine.start()
        let format = audioUnit.outputFormat(forBus: 0)
        let outputFile = try AVAudioFile(forWriting: URL(filePath: file), settings: format.settings)

        let maxFrames: AVAudioFrameCount = 512
        let (bufferListPtr, cleanup) = createAudioBuffer(format: format, maxFrames: maxFrames)
        defer { cleanup() }

        try auAudioUnit.allocateRenderResourcesIfNeeded()
        try auAudioUnit.handleSpeechRequest(AVSpeechSynthesisProviderRequest(simpeText: text, piperId: piperVoiceId))
        if !self.isSynthesizing {
            try? await Task.sleep(for: .seconds(1.0))
        }

        var actionFlags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()

        var isRunning = true

        while isRunning {
            let status = auAudioUnit.internalRenderBlock(&actionFlags, &timeStamp, maxFrames, 0, bufferListPtr, nil, nil)

            if status == kAudioComponentErr_InstanceInvalidated || status == AVAudioEngineManualRenderingError.initialized.rawValue {
                continue
            }

            if status != noErr {
                throw NSError(domain: "\(Self.self)", code: Int(status), userInfo: nil)
            }

            if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames) {
                pcmBuffer.frameLength = maxFrames

                if let destChannel = pcmBuffer.floatChannelData?[0],
                   let sourceChannel = bufferListPtr.pointee.mBuffers.mData {
                    memcpy(destChannel, sourceChannel, Int(bufferListPtr.pointee.mBuffers.mDataByteSize))
                }

                try outputFile.write(from: pcmBuffer)
            }

            if actionFlags.contains(.offlineUnitRenderAction_Complete) {
                isRunning = false
            }
        }
        engine.stop()
    }

    private func connect(to audioUnit: AVAudioUnit, output: AVAudioNode) {
        engine.stop()
        engine.reset()
        engine.attach(audioUnit)
        let format = audioUnit.outputFormat(forBus: 0)
        engine.connect(audioUnit, to: output, format: format)
    }

    func stop() {
        audioUnit?.engine?.stop()
        if let auAudioUnit = audioUnit?.auAudioUnit {
            if auAudioUnit.responds(to: #selector(AVSpeechSynthesisProviderAudioUnit.cancelSpeechRequest)) {
                auAudioUnit.perform(#selector(AVSpeechSynthesisProviderAudioUnit.cancelSpeechRequest), with: nil)
            }
        }
    }

}

extension PiperAudioUnit {
    enum Status {
        case connected
        case disconnected
        case failedToConnect

        var string: String {
            switch self {
            case .connected:
                return "audio_unit_status_connected".localized
            case .disconnected:
                return "audio_unit_status_disconnected".localized
            case .failedToConnect:
                return "audio_unit_status_failed".localized
            }
        }
    }

    var isSynthesizing: Bool {
        guard let messageChannel else {
            return false
        }
        guard let responseObject = messageChannel.callAudioUnit?([MessageChannelKeys.kIsSyntehizerRunning: false]) else {
            return false
        }

        return responseObject[MessageChannelKeys.kIsSyntehizerRunning] as? Bool ?? false
    }
}

// MARK: - Notification Handling
private extension PiperAudioUnit {
    func setUpEngineObservers() {
        NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .sink { [weak self] _ in
                self?.handleEngineConfigurationChange()
            }
            .store(in: &cancellables)
#if !os(macOS)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                self?.handleInterruption(note)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                self?.handleRouteChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                self?.handleMediaServicesReset()
            }
            .store(in: &cancellables)
#endif
    }

    func handleRouteChange() {
        Task { await reconnect() }
    }

    func handleMediaServicesReset() {
        Task { await reconnect() }
    }
}
