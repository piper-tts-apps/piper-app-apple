// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import Combine
import PiperAppUtils

enum DownloadEvent {
    case progress(Double)
    case finished(FileManager.ModelPaths)
}

protocol VoiceLoadListener: AnyObject {
    func progressUpdated(_ progress: Float)
}

class VoiceLoader: NSObject {
    /// In-flight downloads by catalog voice key, shared by every row:
    /// a voice downloads once and progress survives row rebuilds.
    /// Each download gets a session token: after a cancel, the old
    /// stream's late teardown must not be able to touch the state of
    /// a new download of the same voice (and a stale cancellation
    /// must not cancel the new download), so every mutation is
    /// scoped to the session it belongs to.
    @Published private(set) var downloadProgress: [String: Double] = [:]
    private var downloadSessions: [String: UUID] = [:]

    @MainActor
    func beginDownload(for key: String) -> UUID? {
        guard downloadProgress[key] == nil else { return nil }
        let session = UUID()
        downloadProgress[key] = 0
        downloadSessions[key] = session
        return session
    }

    @MainActor
    func updateDownloadProgress(_ progress: Double, for key: String) {
        guard downloadProgress[key] != nil else { return }
        downloadProgress[key] = progress
    }

    @MainActor
    func endDownload(for key: String, session: UUID) {
        guard downloadSessions[key] == session else { return }
        downloadSessions[key] = nil
        downloadProgress[key] = nil
    }

    /// The URLSession task currently fetching a file for each download
    /// session, so a download can be cancelled from any row.
    private var activeDownloadTasks: [UUID: URLSessionDownloadTask] = [:]
    private var downloadTaskSessions: [Int: UUID] = [:]
    /// Sessions whose download was cancelled; checked when the next
    /// file's task starts, so a cancel tapped between the two files
    /// of a voice (config, then model) is not lost.
    private var cancelledSessions: Set<UUID> = []

    /// Cancels the in-flight download of a voice, if any: the session
    /// is invalidated and its registry entry goes away (rows return
    /// to the download state), and the download stream throws
    /// URLError.cancelled.
    @MainActor
    func cancelDownload(for key: String) {
        guard let session = downloadSessions[key] else { return }
        cancelledSessions.insert(session)
        endDownload(for: key, session: session)
        activeDownloadTasks[session]?.cancel()
    }

    /// Catalog keys of installed voices a newer catalog build exists
    /// for. Rows and the voice detail screen observe this the same
    /// way they observe the download registry.
    @Published private(set) var updateAvailableKeys: Set<String> = []

    /// File digests already computed, keyed by path: a digest is
    /// recomputed only when the file's size or modification date
    /// changes (an install replaces both), so repeat checks are cheap.
    private struct DigestCacheEntry {
        let size: Int
        let modified: Date
        let digest: String
    }

    private var digestCache: [String: DigestCacheEntry] = [:]
    private let digestCacheLock = NSLock()

    /// Compares every installed voice against the catalog on a
    /// background task and publishes the stale voices' keys.
    func checkForUpdates(voices: [Voice], installed: [FileManager.ModelPaths]) {
        guard !voices.isEmpty else {
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let keys = VoiceUpdateChecker.updateAvailableKeys(
                voices: voices,
                installed: installed,
                filesProvider: self.installedFilesForUpdateCheck
            )
            await MainActor.run {
                self.updateAvailableKeys = keys
            }
        }
    }

    func fileSize(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    func cachedMD5Digest(of url: URL) -> String? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue,
              let modified = attributes?[.modificationDate] as? Date else {
            return VoiceUpdateChecker.md5Digest(ofFileAt: url)
        }
        digestCacheLock.lock()
        let cached = digestCache[url.path]
        digestCacheLock.unlock()
        if let cached, cached.size == size, cached.modified == modified {
            return cached.digest
        }
        guard let digest = VoiceUpdateChecker.md5Digest(ofFileAt: url) else {
            return nil
        }
        digestCacheLock.lock()
        digestCache[url.path] = DigestCacheEntry(size: size, modified: modified, digest: digest)
        digestCacheLock.unlock()
        return digest
    }

    enum Error: Swift.Error {
        case nilURL
        case loadingFailed
        case wrongModelInfo
    }
    enum Constants {
        static let baseURL = "https://huggingface.co/IhorShevchuk/piper1-voices-fp16-quantized/resolve/main"
        static let communitySamplesBaseURL = "https://rhasspy.github.io/piper-samples/samples"

        static var voicesURL: URL? {
            return URL(string: "\(Constants.baseURL)/voices.json")
        }
    }

    private var continuations: [Int: CheckedContinuation<URL, Swift.Error>] = [:]
    private var observations: [Int: NSKeyValueObservation] = [:]

    private lazy var operationQueue: OperationQueue = {
        OperationQueue()
    }()

    private lazy var urlSession: URLSession = {
        URLSession(configuration: .default,
                   delegate: self,
                   delegateQueue: operationQueue)
    }()

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("voices-catalog.json")
    }

    func loadVoices() async throws -> [Voice] {
        guard let url = Constants.voicesURL else {
            throw Error.nilURL
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let allVoices = try JSONDecoder().decode([String: Voice].self, from: data)
            if let cacheURL {
                try? data.write(to: cacheURL, options: .atomic)
            }
            return Array(allVoices.values)
        } catch {
            // Offline or a broken response: use the last good catalog.
            guard let cacheURL,
                  let data = try? Data(contentsOf: cacheURL),
                  let cached = try? JSONDecoder().decode([String: Voice].self, from: data) else {
                throw error
            }
            return Array(cached.values)
        }
    }

    func sampleURL(for voice: Voice) -> URL? {
        guard let modelPath = voice.modelPath else { return nil }
        let directory = (modelPath as NSString).deletingLastPathComponent
        return URL(string: "\(Constants.baseURL)/\(directory)/sample.mp3")
    }

    /// Community sample, used when our hosted sample is missing.
    func fallbackSampleURL(for voice: Voice) -> URL? {
        let languageCode = voice.language.code
        let languageFamily = languageCode.split(separator: "_").first.map(String.init) ?? languageCode
        let path = "\(languageFamily)/\(languageCode)/\(voice.name)/\(voice.quality)/speaker_0.mp3"
        return URL(string: "\(Constants.communitySamplesBaseURL)/\(path)")
    }

    private func isPinyinVoice(_ voice: Voice, configURL: URL) -> Bool {
        if voice.language.code.lowercased().hasPrefix("zh") { return true }
        guard let data = try? Data(contentsOf: configURL) else { return false }
        guard let config = try? JSONDecoder().decode(VoiceConfig.self, from: data) else { return false }
        return config.phonemeType?.lowercased() == "pinyin"
    }

    private func isJapaneseVoice(_ voice: Voice, configURL: URL) -> Bool {
        if voice.language.code.lowercased().hasPrefix("ja") { return true }
        guard let data = try? Data(contentsOf: configURL) else { return false }
        guard let config = try? JSONDecoder().decode(VoiceConfig.self, from: data) else { return false }
        return config.phonemeType?.lowercased() == "japanese"
    }

    func download(voice: Voice,
                  session: UUID) -> AsyncThrowingStream<DownloadEvent, Swift.Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.performDownload(voice: voice, session: session, continuation: continuation)
            }
        }
    }

    private func performDownload(voice: Voice,
                                 session: UUID,
                                 continuation: AsyncThrowingStream<DownloadEvent, Swift.Error>.Continuation) async {
        var downloadedFiles: [URL] = []
        do {
            let jsonLocalURL = try await downloadVoiceConfig(voice: voice, session: session, continuation: continuation)
            downloadedFiles.append(jsonLocalURL)

            // Japanese voices also need the OpenJTalk dictionary, which is
            // too big to embed in the app. When it is not installed yet, it
            // is fetched as part of this download (progress band 5% -> 35%)
            // and the model keeps the remaining 65%; in every other case
            // the model keeps the usual 95% weight.
            var modelWeight = 0.95
            var modelBaseProgress = 0.05
            if isJapaneseVoice(voice, configURL: jsonLocalURL),
               !OpenJTalkDataManager.isInstalled {
                await ensureJapaneseDictionary(session: session, continuation: continuation)
                modelWeight = 0.65
                modelBaseProgress = 0.35
            }

            let band: DownloadProgressBand = (weight: modelWeight, base: modelBaseProgress)
            let paths: FileManager.ModelPaths
            if let split = voice.split {
                // Split build (issue #94): fetch the encoder+decoder
                // parts instead of the full model; the voice installs
                // splits-only.
                let staged = try await downloadSplitModel(split: split,
                                                          jsonLocalURL: jsonLocalURL,
                                                          session: session,
                                                          band: band,
                                                          continuation: continuation)
                downloadedFiles.append(contentsOf: staged.stagedFiles)
                paths = staged.paths
            } else {
                let classic = try await downloadClassicModel(voice: voice,
                                                             jsonLocalURL: jsonLocalURL,
                                                             session: session,
                                                             band: band,
                                                             continuation: continuation)
                downloadedFiles.append(classic.modelLocalURL)
                paths = classic.paths
            }

            continuation.yield(.finished(paths))
            continuation.finish()

        } catch {
            // A failed or cancelled download must not leave
            // partial temp files behind.
            for fileURL in downloadedFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
            continuation.finish(throwing: error)
        }
        cancelledSessions.remove(session)
        activeDownloadTasks[session] = nil
    }

    /// Downloads and validates a voice's config file (the small JSON),
    /// preparing extra data for voices that need it (Chinese G2PW).
    private func downloadVoiceConfig(voice: Voice,
                                     session: UUID,
                                     continuation: AsyncThrowingStream<DownloadEvent, Swift.Error>.Continuation) async throws -> URL {
        guard let jsonPath = voice.jsonPath else {
            throw Error.loadingFailed
        }
        guard let jsonURL = URL(string: "\(Constants.baseURL)/\(jsonPath)") else {
            throw Error.nilURL
        }

        // JSON is tiny → weight 5%
        let jsonLocalURL = try await downloadFile(
            from: jsonURL,
            session: session,
            weight: 0.05,
            baseProgress: 0.0,
            continuation: continuation
        )

        if (try? ModelInfo.create(from: jsonLocalURL)) == nil {
            try? FileManager.default.removeItem(at: jsonLocalURL)
            throw Error.wrongModelInfo
        }

        if isPinyinVoice(voice, configURL: jsonLocalURL) {
            do {
                try G2PWDataManager.ensureInstalled()
            } catch {
                Log.error("Failed to ensure g2pw data: \(error)")
            }
        }

        return jsonLocalURL
    }

    /// Downloads the OpenJTalk dictionary archive through the same
    /// session-scoped download machinery as the voice files, so it
    /// reports progress into the dictionary band and is cancelled
    /// together with the voice download, then installs it into the
    /// shared folder. The manifest published next to the archive is
    /// fetched first, and the archive is installed only after its size
    /// and SHA-256 match the manifest, so a manifest that cannot be
    /// fetched or decoded aborts the step - nothing unverified is ever
    /// installed. Failures are logged, not fatal (mirrors the G2PW
    /// handling): the voice still installs, and the next Japanese
    /// download retries the dictionary. A cancellation needs no special
    /// handling here - the model download that follows re-checks the
    /// cancelled session and throws.
    private func ensureJapaneseDictionary(session: UUID,
                                          continuation: AsyncThrowingStream<DownloadEvent, Swift.Error>.Continuation) async {
        do {
            let manifest = try await fetchOpenJTalkManifest()
            let archiveURL = try await downloadFile(
                from: OpenJTalkDataManager.dictionaryArchiveURL,
                session: session,
                weight: 0.30,
                baseProgress: 0.05,
                continuation: continuation
            )
            defer { try? FileManager.default.removeItem(at: archiveURL) }
            guard fileSize(at: archiveURL) == manifest.sizeBytes else {
                throw Error.loadingFailed
            }
            try OpenJTalkDataManager.verifyArchive(at: archiveURL,
                                                   expectedSHA256: manifest.sha256)
            try OpenJTalkDataManager.install(fromArchiveFile: archiveURL)
        } catch {
            Log.error("Failed to install OpenJTalk dictionary: \(error)")
        }
    }

    /// Fetches the dictionary manifest (`openjtalk.json`) published
    /// next to the archive in its Hugging Face repo, the same way the
    /// voice catalog is fetched in `loadVoices`. The manifest carries
    /// the expected archive size and hash, so dictionary updates never
    /// need an app update.
    private func fetchOpenJTalkManifest() async throws -> OpenJTalkManifest {
        let (data, _) = try await URLSession.shared.data(from: OpenJTalkDataManager.dictionaryManifestURL)
        return try JSONDecoder().decode(OpenJTalkManifest.self, from: data)
    }

    func downloadFile(
        from url: URL,
        session: UUID,
        weight: Double,
        baseProgress: Double,
        continuation: AsyncThrowingStream<DownloadEvent, Swift.Error>.Continuation
    ) async throws -> URL {

        let task = urlSession.downloadTask(with: url)
        let id = task.taskIdentifier
        activeDownloadTasks[session] = task
        downloadTaskSessions[id] = session

        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let total = baseProgress + progress.fractionCompleted * weight
            continuation.yield(.progress(total))
        }

        observations[id] = observation

        return try await withCheckedThrowingContinuation { cont in
            continuations[id] = cont
            task.resume()
            if cancelledSessions.contains(session) {
                task.cancel()
            }
        }
    }
}

extension VoiceLoader: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier

        do {
            let tempLocation = try FileManager.default.moveToTemporaryDirectory(fileURL: location)
            continuations[id]?.resume(returning: tempLocation)
        } catch {
            Log.error("Failed to move file to temporary location: \(error)")
            continuations[id]?.resume(throwing: error)
        }

        continuations[id] = nil
        observations[id]?.invalidate()
        observations[id] = nil
        clearDownloadTask(id: id)
    }

    private func clearDownloadTask(id: Int) {
        if let session = downloadTaskSessions[id],
           activeDownloadTasks[session]?.taskIdentifier == id {
            activeDownloadTasks[session] = nil
        }
        downloadTaskSessions[id] = nil
    }

    private func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let id = task.taskIdentifier
        continuations[id]?.resume(throwing: error ?? URLError(.unknown))
        continuations[id] = nil
        observations[id]?.invalidate()
        observations[id] = nil
        clearDownloadTask(id: id)
    }
}
