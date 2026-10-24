// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ihor Shevchuk

import AVFoundation
import piper_objc
import PiperAppUtils
import PiperTTSLogic
import Accelerate

public class PiperTTSAudioUnit: AVSpeechSynthesisProviderAudioUnit {
    private var outputBus: AUAudioUnitBus
    private var _outputBusses: AUAudioUnitBusArray!

    private var request: AVSpeechSynthesisProviderRequest?

    private var format: AVAudioFormat

    var piper: Piper?
    var model: ModelInfo?

    private var outputDataLock = os_unfair_lock_s()
    internal var outputData = FloatRingBuffer()
    private var outputRecurseCallNumber = 0

    private let requestGate = RequestGenerationGate()
    /// Generation of the request currently being synthesized. Guarded by outputDataLock.
    private var activeGeneration: UInt64 = 0
#if DEBUG
    private let requestTracer = AURequestTracer()
#endif

    private let outputRecurseCallNumberMax: UInt32 = 400
    private let baseDelayMicroseconds: UInt32 = 5000
    internal let maxBufferDurationSeconds: Double = 120.0
    internal let maxSamplesCount: Int

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050.0, channels: 1, interleaved: true)!
        self.maxSamplesCount = Int(self.format.sampleRate * maxBufferDurationSeconds)

        outputBus = try AUAudioUnitBus(format: self.format)
        try super.init(componentDescription: componentDescription, options: options)
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: AUAudioUnitBusType.output, busses: [outputBus])
    }

    public override var outputBusses: AUAudioUnitBusArray {
        return _outputBusses
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        Log.debug("allocateRenderResources")
#if DEBUG
        requestTracer.allocated()
#endif
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
#if DEBUG
        requestTracer.deallocated()
#endif
        // Cancel the live synthesis before teardown, in cleanUp()'s order -
        // clearing alone orphaned the self-retained synthesis operation.
        removeRequestAndCleanOutputData()
        piper = nil
        model = nil
    }

    // MARK: - Rendering
    /*
     NOTE:- It is only safe to use Swift for audio rendering in this case, as Audio Unit Speech Extensions process offline.
     (Swift is not usually recommended for processing on the realtime audio thread)
     */
    public override var internalRenderBlock: AUInternalRenderBlock { self.performRender }

    // swiftlint:disable:next function_parameter_count
    private func performRender(
      actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
      timestamp: UnsafePointer<AudioTimeStamp>,
      frameCount: AUAudioFrameCount,
      outputBusNumber: Int,
      outputAudioBufferList: UnsafeMutablePointer<AudioBufferList>,
      renderEvents: UnsafePointer<AURenderEvent>?,
      renderPull: AURenderPullInputBlock?
    ) -> AUAudioUnitStatus {
        return doPerformRender(actionFlags: actionFlags, timestamp: timestamp, frameCount: frameCount, outputBusNumber: outputBusNumber, outputAudioBufferList: outputAudioBufferList, renderEvents: renderEvents, renderPull: renderPull)
    }

    // Made internal for unit testing – previously private
    // swiftlint:disable:next function_parameter_count function_body_length
    internal func doPerformRender(
      actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
      timestamp: UnsafePointer<AudioTimeStamp>,
      frameCount: AUAudioFrameCount,
      outputBusNumber: Int,
      outputAudioBufferList: UnsafeMutablePointer<AudioBufferList>,
      renderEvents: UnsafePointer<AURenderEvent>?,
      renderPull: AURenderPullInputBlock?
    ) -> AUAudioUnitStatus {
        let renderGeneration = requestGate.currentGeneration

        guard let piper = self.piper else {
            Log.error("Piper is nil while request for rendering came.")
            return kAudioComponentErr_InstanceInvalidated
        }

        if request == nil {
            Log.debug(type: .synthesizer, "Request is nil. Cleaning up.")
            actionFlags.pointee = .offlineUnitRenderAction_Complete
            self.cleanUp()
            return noErr
        }

        let intFrameCount = Int(frameCount)
        let availableCount: Int
        os_unfair_lock_lock(&outputDataLock)
        availableCount = outputData.count
        os_unfair_lock_unlock(&outputDataLock)

        let countToCopy = min(availableCount, intFrameCount)

        if countToCopy < intFrameCount {
            let completedRendering = piper.completed()
            if (completedRendering && availableCount == 0) || request == nil {
                Log.debug(type: .synthesizer, "Completed rendering")
                actionFlags.pointee = .offlineUnitRenderAction_Complete
                self.cleanUp()
                return noErr
            }

            outputRecurseCallNumber += 1
            if outputRecurseCallNumber < outputRecurseCallNumberMax && !completedRendering {
                Log.error(type: .synthesizer, "Rendering in progress no data. Trying one more time: \(self.outputRecurseCallNumber)")
                pauseUntil(maxDelayFactor: outputRecurseCallNumberMax) { [weak self] in
                    guard let self else { return true }
                    os_unfair_lock_lock(&self.outputDataLock)
                    let hasEnoughData = self.outputData.count >= intFrameCount
                    let isCancelled = self.request == nil || !self.requestGate.isCurrent(renderGeneration)
                    os_unfair_lock_unlock(&self.outputDataLock)
                    return piper.completed() || hasEnoughData || isCancelled
                }
                return doPerformRender(actionFlags: actionFlags, timestamp: timestamp, frameCount: frameCount, outputBusNumber: outputBusNumber, outputAudioBufferList: outputAudioBufferList, renderEvents: renderEvents, renderPull: renderPull)
            }
            Log.error(type: .synthesizer, "Tried \(self.outputRecurseCallNumber), without luck. Returning what have currently")
        }

        outputRecurseCallNumber = 0

        let actualCopied = min(availableCount, intFrameCount)
        outputAudioBufferList.pointee.mNumberBuffers = 1
        var unsafeBuffer = UnsafeMutableAudioBufferListPointer(outputAudioBufferList)[0]
        let frames = unsafeBuffer.mData!.assumingMemoryBound(to: Float32.self)
        if actualCopied < intFrameCount {
            frames.update(repeating: 0, count: intFrameCount)
        }
        unsafeBuffer.mNumberChannels = 1
        unsafeBuffer.mDataByteSize = UInt32(actualCopied * MemoryLayout<Float32>.size)

        os_unfair_lock_lock(&outputDataLock)
        if actualCopied > 0 {
            outputData.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    frames.update(from: base, count: actualCopied)
                }
            }
            outputData.removeFirst(actualCopied)
        }
        os_unfair_lock_unlock(&outputDataLock)

        actionFlags.pointee = .offlineUnitRenderAction_Render
#if DEBUG
        Log.debug(type: .synthesizer, "Rendered: \(actualCopied). Remaining buffer: \(availableCount - actualCopied)")
#endif
        return noErr
    }

    public override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        Log.debug("synthesizeSpeechRequest \(speechRequest.ssmlRepresentation)")
        guard let speakerId = speechRequest.voice.identifier.speakerId else {
            Log.error(type: .synthesizer, "Cannot parse speaker id from identifier: \(speechRequest.voice.identifier).")
            return
        }
        removeRequestAndCleanOutputData()
        let generation = requestGate.begin()
        os_unfair_lock_lock(&outputDataLock)
        self.request = speechRequest
        self.activeGeneration = generation
        os_unfair_lock_unlock(&outputDataLock)
        createPiperIfNeeded(voiceIdentifier: speechRequest.voice.identifier)
#if DEBUG
        requestTracer.begin(generation: generation, textLength: speechRequest.ssmlRepresentation.count)
        requestTracer.synthesizeStart(generation: generation)
#endif
        piper?.synthesizeSSML(speechRequest.ssmlRepresentation, speakerId: speakerId)
    }

    public override func cancelSpeechRequest() {
        Log.debug("cancelSpeechRequest")
#if DEBUG
        requestTracer.cancel()
#endif
        cleanUp()
    }

    func cleanUp() {
        Log.debug("cleanUp request:\(self.request?.ssmlRepresentation ?? "nil")")
#if DEBUG
        requestTracer.end()
#endif
        removeRequestAndCleanOutputData()
    }

    private func removeRequestAndCleanOutputData() {
        requestGate.cancel()
        os_unfair_lock_lock(&outputDataLock)
        request = nil
        outputData.clear()
        os_unfair_lock_unlock(&outputDataLock)
        piper?.cancel()
    }

    internal func pauseUntil(maxDelayFactor: UInt32, or condition: @escaping () -> Bool) {
        let maxDelaySeconds = Double(baseDelayMicroseconds * maxDelayFactor) / 1_000_000
        let checkIntervalSeconds = maxDelaySeconds / 5.0
        let startTime = Date()
        while !condition() && Date().timeIntervalSince(startTime) < maxDelaySeconds {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(checkIntervalSeconds))
        }
    }

    private func createPiperIfNeeded(voiceIdentifier: String) {
        guard let model = ModelInfo.installedModelInfo(for: voiceIdentifier),
        let paths = model.installedPath else {
            return
        }
        if model == self.model && piper != nil { return }
        let modelFolder = paths.model.deletingLastPathComponent()
        var g2pwDir: String?
        let dataDir: String? = modelFolder.path(percentEncoded: false)

        if model.language.code.lowercased().hasPrefix("zh") {
            if let sharedG2PW = FileManager.Constants.g2pwFolderURL,
               FileManager.default.fileExists(atPath: sharedG2PW.path) {
                let fileManager = FileManager.default
                let hasFiles = ["MONOPHONIC_CHARS.txt", "char_bopomofo_dict.json", "bopomofo_to_pinyin_wo_tune_dict.json"].allSatisfy { fileManager.fileExists(atPath: sharedG2PW.appendingPathComponent($0).path) }
                if hasFiles {
                    g2pwDir = sharedG2PW.path(percentEncoded: false)
                } else {
                    g2pwDir = modelFolder.path(percentEncoded: false)
                }
            } else {
                g2pwDir = modelFolder.path(percentEncoded: false)
            }
        }

        var openjtalkDir: String?
        if model.language.code.lowercased().hasPrefix("ja") {
            if let sharedOpenJTalk = FileManager.Constants.openjtalkFolderURL,
               FileManager.Constants.openjtalkFileExists() {
                openjtalkDir = sharedOpenJTalk.path(percentEncoded: false)
            } else {
                let candidate = modelFolder.appendingPathComponent("openjtalk")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    openjtalkDir = candidate.path(percentEncoded: false)
                }
            }
        }

        if g2pwDir != nil || openjtalkDir != nil {
            let options = PiperCreateOptions(
                modelPath: paths.model.path(percentEncoded: false),
                configPath: paths.json.path(percentEncoded: false),
                espeakDataPath: nil,
                dataDir: dataDir,
                g2pwModelDir: g2pwDir,
                openjtalkDictDir: openjtalkDir
            )
            piper = (try? Piper(options: options)) ?? (try? Piper(modelPath: paths.model.path(percentEncoded: false), andConfigPath: paths.json.path(percentEncoded: false)))
            Log.debug("Piper Created with g2pwDir:\(g2pwDir ?? "nil") openjtalkDir:\(openjtalkDir ?? "nil")")
        } else {
            piper = try? Piper(modelPath: paths.model.path(percentEncoded: false), andConfigPath: paths.json.path(percentEncoded: false))
            Log.debug("Piper Created")
        }
#if os(iOS)
        let availableMemory = Int64(Double(os_proc_available_memory()) * 0.9)
        if availableMemory > 0 {
            Log.debug("Setting memoryThresholdBytes:\(ByteCountFormatter.string(fromByteCount: availableMemory, countStyle: .binary))")
            piper?.memoryThresholdBytes = UInt64(availableMemory)
        }
#endif
        piper?.delegate = self
        self.model = model
    }

    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get { AVSpeechSynthesisProviderVoice.supportedVoices }
        set { }
    }

    public override func messageChannel(for channelName: String) -> AUMessageChannel {
        Log.debug("Creating message channel for \(channelName)")
        return PiperMessageChannel(delegate: self)
    }
}

extension PiperTTSAudioUnit: PiperDelegate {
    public func piperDidReceiveSamples(_ samples: UnsafePointer<Float>, withSize size: Int) {
        if size == 0 { return }
        // Stamp the chunk with the generation of the request active on
        // arrival; the append validates the stamp, never the mutable
        // activeGeneration (after cancel + new request it holds the new
        // generation and would rubber-stamp stale chunks - bug 2). The
        // resampler runs outside the lock, across the cancel boundary.
        os_unfair_lock_lock(&outputDataLock)
        let producingGeneration = activeGeneration
        let hasActiveRequest = request != nil
        os_unfair_lock_unlock(&outputDataLock)
        guard hasActiveRequest, requestGate.isCurrent(producingGeneration) else {
#if DEBUG
            requestTracer.chunkDroppedEarly(stampedGeneration: producingGeneration, samples: size)
#endif
            return
        }

        let buf = UnsafeBufferPointer(start: samples, count: size)
        if let modelFormat = model?.audioFormat,
           modelFormat.sampleRate != format.sampleRate {
            let resampled = AudioResampler.resampleBuffer(buf, inputRate: modelFormat.sampleRate, outputRate: format.sampleRate)
            os_unfair_lock_lock(&outputDataLock)
            let accepted = requestGate.shouldAcceptChunk(producedUnder: producingGeneration, forActiveRequest: activeGeneration)
            if accepted {
                outputData.appendAndEnforceMax(contentsOf: resampled, maxCount: maxSamplesCount)
            }
#if DEBUG
            let slotAtAppend = activeGeneration
#endif
            os_unfair_lock_unlock(&outputDataLock)
#if DEBUG
            requestTracer.chunk(stampedGeneration: producingGeneration, samples: resampled.count, accepted: accepted, activeGeneration: slotAtAppend)
#endif
        } else {
            os_unfair_lock_lock(&outputDataLock)
            let accepted = requestGate.shouldAcceptChunk(producedUnder: producingGeneration, forActiveRequest: activeGeneration)
            if accepted {
                outputData.appendAndEnforceMax(contentsOf: buf, maxCount: maxSamplesCount)
            }
#if DEBUG
            let slotAtAppend = activeGeneration
#endif
            os_unfair_lock_unlock(&outputDataLock)
#if DEBUG
            requestTracer.chunk(stampedGeneration: producingGeneration, samples: size, accepted: accepted, activeGeneration: slotAtAppend)
#endif
        }
    }

    public func piperDidGenerateMarkers(_ markers: [PiperSpeechMarker]) {
        // piper-objc 0.2.30 now prefers generateMarkersWithAlignment when alignment groups non-empty:
        // monotonic timing, punctuationTrimSet fixes #31. AU just forwards those improved markers.
        os_unfair_lock_lock(&outputDataLock)
        let metadataBlock = self.speechSynthesisOutputMetadataBlock
        let request = self.request
        let isCurrentGeneration = requestGate.isCurrent(self.activeGeneration)
        os_unfair_lock_unlock(&outputDataLock)
        guard let metadataBlock = metadataBlock, let request = request, isCurrentGeneration else { return }
        for marker in markers {
            guard let appleMarker = marker.avMarker else { continue }
#if DEBUG
            let requestText = request.ssmlRepresentation
            let swiftRange = Range(appleMarker.textRange, in: requestText)
            let text = if let swiftRange { String(requestText[swiftRange]) } else { "<no valid range>" }
            Log.debug("DidGenerateMarker [type:\(appleMarker.mark)] offset:\(appleMarker.byteSampleOffset), text:'\(text)'")
#endif
            metadataBlock([appleMarker], request)
        }
    }
}

extension PiperTTSAudioUnit: PiperMessageChannelDelegate {
    var isSyntehizerRunning: Bool {
        os_unfair_lock_lock(&outputDataLock)
        let result = request != nil
        os_unfair_lock_unlock(&outputDataLock)
        return result
    }
}

extension PiperSpeechMarker {
    var avMarker: AVSpeechSynthesisMarker? {
        let avType =
        switch type {
        case .sentence:
            AVSpeechSynthesisMarker.Mark.sentence
        case .word:
            AVSpeechSynthesisMarker.Mark.word
        }
        return AVSpeechSynthesisMarker(markerType: avType, forTextRange: range, atByteSampleOffset: byteOffset)
    }
}
