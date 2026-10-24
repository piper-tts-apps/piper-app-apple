// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import CryptoKit
import Foundation
import PiperAppUtils

/// Whether the catalog's build of an installed voice differs from
/// the files on disk.
enum VoiceUpdateStatus: Equatable {
    case upToDate
    case updateAvailable
    /// Not enough evidence either way (unreadable files, a catalog
    /// without digests): the UI stays as it is today, no indicator.
    case unknown
}

/// Update detection compares the catalog's per-file MD5 digests
/// with the installed files' actual contents. The catalog carries
/// no version number, and none is needed: a retrained model changes
/// the model digest, a config-only fix changes the config digest.
/// Existing installs need no migration, because nothing about the
/// installed voice is stored - its files are hashed as they are.
enum VoiceUpdateChecker {

    /// Digests and size of one installed voice's files, gathered by
    /// the caller so the comparison itself stays pure and testable.
    struct InstalledFiles: Equatable {
        var modelSize: Int?
        var modelMD5: String?
        var configMD5: String?
        /// Splits-only installs (issue #94) have no model file: the
        /// model digest stays nil (no single digest is fabricated over
        /// the pair - the catalog publishes per-part digests) and the
        /// parts are compared via the fields below instead. The model
        /// size still carries the pair's total.
        var isSplitsOnly: Bool = false
        var splitEncoderMD5: String?
        var splitDecoderMD5: String?
        var splitEncoderSize: Int?
        var splitDecoderSize: Int?
    }

    /// The comparison follows the layout that is actually
    /// installed, never the Streaming voices setting - the setting
    /// governs new downloads only. A classic install compares
    /// against the catalog's classic files even when the entry also
    /// offers a split build (comparing it against the split parts
    /// would flag a permanent phantom update), and a splits-only
    /// install keeps comparing per-part even if the setting has
    /// since been turned off: it is a working streaming voice, not
    /// a stale classic one, so the toggle must not force it into a
    /// re-download.
    static func status(voice: Voice, installed: InstalledFiles) -> VoiceUpdateStatus {
        if installed.isSplitsOnly {
            return splitsOnlyStatus(voice: voice, installed: installed)
        }
        return status(catalogModelMD5: voice.catalogModelFile?.md5Digest,
                      catalogModelSize: voice.catalogModelFile?.size_bytes,
                      catalogConfigMD5: voice.catalogJSONFile?.md5Digest,
                      variantModelSize: voice.compactVariant?.sizeBytes,
                      installed: installed)
    }

    /// Splits-only installs have no model file, so the classic model
    /// digest/size comparisons must not run: a split pair's total size
    /// never equals the full model's size, and there is no single model
    /// digest. The catalog's split build carries per-part digests and
    /// sizes to compare against instead. Without a split build in the
    /// entry there is no evidence either way.
    private static func splitsOnlyStatus(voice: Voice, installed: InstalledFiles) -> VoiceUpdateStatus {
        // A changed config alone (e.g. a dataset fix) is an update.
        if digestsDiffer(voice.catalogJSONFile?.md5Digest, installed.configMD5) {
            return .updateAvailable
        }
        guard let split = voice.split else {
            return .unknown
        }
        if digestsMatch(split.encoder.md5Digest, installed.splitEncoderMD5),
           digestsMatch(split.decoder.md5Digest, installed.splitDecoderMD5) {
            return .upToDate
        }
        if digestsDiffer(split.encoder.md5Digest, installed.splitEncoderMD5) ||
            digestsDiffer(split.decoder.md5Digest, installed.splitDecoderMD5) {
            return .updateAvailable
        }
        // Without usable digests, part sizes can only prove a
        // difference (the same rule as the classic size fallback).
        if let encoderSize = installed.splitEncoderSize,
           let decoderSize = installed.splitDecoderSize,
           encoderSize != split.encoder.sizeBytes || decoderSize != split.decoder.sizeBytes {
            return .updateAvailable
        }
        return .unknown
    }

    static func status(catalogModelMD5: String?,
                       catalogModelSize: Int?,
                       catalogConfigMD5: String?,
                       variantModelSize: Int?,
                       installed: InstalledFiles) -> VoiceUpdateStatus {
        // A changed config alone (e.g. a dataset fix) is an update.
        if digestsDiffer(catalogConfigMD5, installed.configMD5) {
            return .updateAvailable
        }
        // The installed model is exactly the catalog's standard build.
        if digestsMatch(catalogModelMD5, installed.modelMD5) {
            return .upToDate
        }
        // The installed model is not the standard build but has
        // exactly the current Compact build's size: it is that build
        // (the catalog serves no digest for variants to check more).
        if digestsDiffer(catalogModelMD5, installed.modelMD5),
           let variantModelSize, installed.modelSize == variantModelSize {
            return .upToDate
        }
        // The model digest is known on both sides and differs.
        if digestsDiffer(catalogModelMD5, installed.modelMD5) {
            return .updateAvailable
        }
        // Without usable digests, sizes can only prove a difference:
        // matching sizes might still hide rebuilt weights.
        if let catalogModelSize, let modelSize = installed.modelSize,
           modelSize != catalogModelSize, modelSize != variantModelSize {
            return .updateAvailable
        }
        return .unknown
    }

    /// Keys of the catalog voices whose installed copy is stale.
    static func updateAvailableKeys(
        voices: [Voice],
        installed: [FileManager.ModelPaths],
        filesProvider: (FileManager.ModelPaths) -> InstalledFiles
    ) -> Set<String> {
        var result = Set<String>()
        for voice in voices {
            guard let paths = VoiceItemHostModel.installedPaths(for: voice, in: installed) else {
                continue
            }
            if status(voice: voice, installed: filesProvider(paths)) == .updateAvailable {
                result.insert(voice.key)
            }
        }
        return result
    }

    private static func digestsMatch(_ catalog: String?, _ installed: String?) -> Bool {
        guard let catalog, let installed else {
            return false
        }
        return catalog.caseInsensitiveCompare(installed) == .orderedSame
    }

    private static func digestsDiffer(_ catalog: String?, _ installed: String?) -> Bool {
        guard let catalog, let installed else {
            return false
        }
        return catalog.caseInsensitiveCompare(installed) != .orderedSame
    }

    /// MD5 of a file's contents as lowercase hex (the catalog's
    /// digest format), read in chunks so large models never load
    /// into memory at once. Nil when the file cannot be read.
    static func md5Digest(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }
        var hasher = Insecure.MD5()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
