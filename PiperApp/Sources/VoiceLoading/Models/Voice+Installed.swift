// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils

/// A catalog-shaped `Voice` for an installed model with no catalog
/// entry. This lives in the app target, not in PiperAppUtils:
/// `ModelInfo` is in PiperAppUtils and cannot see the app's `Voice`
/// type, so the conversion is an app-side extension on `ModelInfo`.
extension ModelInfo {
    /// Builds the row for this installed model. The key is prefixed
    /// so it can never collide with a catalog key or appear in the
    /// loader's download / update registries, and it stays stable
    /// across reinstalls (install folders are UUID-named, so the
    /// path is not a usable identity). `name` and `quality` match
    /// the fields `VoiceItemHostModel.installedPaths` matches on,
    /// so the row is recognised as installed and navigates to its
    /// detail screen instead of offering a download.
    ///
    /// `files` carries the on-disk sizes only, for the row's size
    /// label: it is never a download target. `split` stays nil for
    /// the same reason - the detail screen plays from `ModelPaths`,
    /// which derives split parts from the model anchor, so the
    /// synthetic voice needs no split build of its own.
    func installedVoice(paths: FileManager.ModelPaths) -> Voice {
        var files: [String: VoiceFile] = [:]
        files[paths.model.lastPathComponent] = VoiceFile(size_bytes: Self.fileSize(at: paths.model),
                                                         md5Digest: nil)
        files[paths.json.lastPathComponent] = VoiceFile(size_bytes: Self.fileSize(at: paths.json),
                                                        md5Digest: nil)
        if paths.hasSplitModel {
            files[paths.encoder.lastPathComponent] = VoiceFile(size_bytes: Self.fileSize(at: paths.encoder),
                                                               md5Digest: nil)
            files[paths.decoder.lastPathComponent] = VoiceFile(size_bytes: Self.fileSize(at: paths.decoder),
                                                               md5Digest: nil)
        }
        return Voice(key: "installed:\(voiceId)",
                     name: name,
                     quality: audio.quality,
                     language: language,
                     files: files)
    }

    private static func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
