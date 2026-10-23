// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils

/// How one download stage maps its own 0...1 progress onto the whole
/// download's progress (the config is worth 5%, the model stage the
/// rest, less when the Japanese dictionary band runs first).
typealias DownloadProgressBand = (weight: Double, base: Double)

extension VoiceLoader {

    /// The installed-files snapshot update detection compares against
    /// the catalog. Splits-only installs (issue #94) have no model
    /// file or model digest: the model slot carries the pair's total
    /// size and the two part digests go in the split fields.
    func installedFilesForUpdateCheck(_ paths: FileManager.ModelPaths) -> VoiceUpdateChecker.InstalledFiles {
        if !FileManager.default.fileExists(atPath: paths.model.path), paths.hasSplitModel {
            return VoiceUpdateChecker.InstalledFiles(
                modelSize: (fileSize(at: paths.encoder) ?? 0) + (fileSize(at: paths.decoder) ?? 0),
                modelMD5: nil,
                configMD5: cachedMD5Digest(of: paths.json),
                isSplitsOnly: true,
                splitEncoderMD5: cachedMD5Digest(of: paths.encoder),
                splitDecoderMD5: cachedMD5Digest(of: paths.decoder),
                splitEncoderSize: fileSize(at: paths.encoder),
                splitDecoderSize: fileSize(at: paths.decoder)
            )
        }
        return VoiceUpdateChecker.InstalledFiles(
            modelSize: fileSize(at: paths.model),
            modelMD5: cachedMD5Digest(of: paths.model),
            configMD5: cachedMD5Digest(of: paths.json)
        )
    }

    /// Downloads a voice's split build (issue #94): the encoder and
    /// decoder parts instead of the full model. Each part is verified
    /// against the catalog (size always, digest where the catalog
    /// carries one) before it counts as downloaded. The parts are
    /// staged in a per-download folder under the anchor name libpiper
    /// derives them from, so the returned paths are the splits-only
    /// layout: an anchor with no file behind it and the parts at the
    /// derived encoder/decoder URLs. On failure the staged files are
    /// removed again before the error propagates.
    func downloadSplitModel(split: VoiceSplit,
                            jsonLocalURL: URL,
                            session: UUID,
                            band: DownloadProgressBand,
                            continuation: AsyncThrowingStream<DownloadEvent, Swift.Error>.Continuation)
        async throws -> (paths: FileManager.ModelPaths, stagedFiles: [URL]) {
        guard let tempFolder = FileManager.tempFolderInDocumentDirectory else {
            throw Error.loadingFailed
        }
        try FileManager.default.createTemporaryDirectoryIfNeeded()
        let folder = tempFolder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stagedFiles: [URL] = [folder]
        do {
            let anchor = folder.appendingPathComponent(PiperAppUtils.Constants.modelFileNameWithExtension)
            guard let paths = FileManager.ModelPaths(model: anchor, json: jsonLocalURL) else {
                throw Error.loadingFailed
            }
            let parts: [(part: VoiceSplitPart, destination: URL)] = [
                (split.encoder, paths.encoder),
                (split.decoder, paths.decoder)
            ]
            let partWeight = band.weight / 2
            for (index, item) in parts.enumerated() {
                guard let partURL = URL(string: "\(Constants.baseURL)/\(item.part.model)") else {
                    throw Error.nilURL
                }
                let localURL = try await downloadFile(
                    from: partURL,
                    session: session,
                    weight: partWeight,
                    baseProgress: band.base + partWeight * Double(index),
                    continuation: continuation
                )
                stagedFiles.append(localURL)
                try verifyDownloadedPart(localURL, part: item.part)
                try FileManager.default.moveItem(at: localURL, to: item.destination)
            }
            return (paths, stagedFiles)
        } catch {
            for url in stagedFiles {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// A downloaded split part counts only when it is exactly the
    /// file the catalog describes.
    func verifyDownloadedPart(_ url: URL, part: VoiceSplitPart) throws {
        guard fileSize(at: url) == part.sizeBytes else {
            throw Error.loadingFailed
        }
        if let expectedMD5 = part.md5Digest,
           VoiceUpdateChecker.md5Digest(ofFileAt: url)?.caseInsensitiveCompare(expectedMD5) != .orderedSame {
            throw Error.loadingFailed
        }
    }

    /// Downloads the full model of a classic (non-split) catalog
    /// entry, exactly as the loader always has.
    func downloadClassicModel(voice: Voice,
                              jsonLocalURL: URL,
                              session: UUID,
                              band: DownloadProgressBand,
                              continuation: AsyncThrowingStream<DownloadEvent, Swift.Error>.Continuation)
        async throws -> (paths: FileManager.ModelPaths, modelLocalURL: URL) {
        guard let modelPath = voice.modelPath else {
            throw Error.loadingFailed
        }
        guard let modelURL = URL(string: "\(Constants.baseURL)/\(modelPath)") else {
            throw Error.nilURL
        }
        // Model is large: the band is 95% of the download (65% after
        // a dictionary fetch).
        let modelLocalURL = try await downloadFile(
            from: modelURL,
            session: session,
            weight: band.weight,
            baseProgress: band.base,
            continuation: continuation
        )
        guard let paths = FileManager.ModelPaths(model: modelLocalURL, json: jsonLocalURL) else {
            throw Error.loadingFailed
        }
        return (paths, modelLocalURL)
    }
}
