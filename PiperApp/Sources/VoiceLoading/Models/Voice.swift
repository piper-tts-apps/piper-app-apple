// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils

class Voice: Decodable {
    let key: String
    let name: String
    let quality: String
    let language: PiperAppUtils.Language
    let files: [String: VoiceFile]
    /// Effective license shown to the user: the most restrictive of the model
    /// license and the training-data license. Optional so catalog entries
    /// written before per-voice licenses were added still decode.
    let license: String?
    let modelLicense: String?
    let trainingData: TrainingData?
    /// Alternative model builds from the catalog's `variants` field,
    /// keyed by format ("int8"). Optional so older catalog entries
    /// still decode, and deliberately excluded from Equatable and
    /// Hashable: a voice's identity stays on the original fields,
    /// whichever build ends up downloaded.
    let variants: [String: VoiceVariant]?
    /// Split (encoder/decoder) build of this voice from the catalog's
    /// top-level `split` field, following the `variants` precedent:
    /// optional so older catalog entries still decode, and deliberately
    /// excluded from Equatable and Hashable. It must not live inside
    /// `files`: `modelPath` picks an `.onnx` key from `files` and
    /// `voiceSize` sums `files`, so two extra `.onnx` entries there
    /// would corrupt both.
    let split: VoiceSplit?

    struct VoiceVariant: Decodable {
        let model: String
        let sizeBytes: Int

        enum CodingKeys: String, CodingKey {
            case model
            case sizeBytes = "size_bytes"
        }
    }

    struct VoiceSplit: Decodable {
        let encoder: VoiceSplitPart
        let decoder: VoiceSplitPart
    }

    struct VoiceSplitPart: Decodable {
        let model: String
        let sizeBytes: Int
        /// Part digest for download verification and update detection,
        /// in the same format as `VoiceFile.md5Digest`.
        let md5Digest: String?

        enum CodingKeys: String, CodingKey {
            case model
            case sizeBytes = "size_bytes"
            case md5Digest = "md5_digest"
        }
    }

    enum CodingKeys: String, CodingKey {
        case key
        case name
        case quality
        case language
        case files
        case license
        case modelLicense = "model_license"
        case trainingData = "training_data"
        case variants
        case split
    }

    /// The INT8 build of this voice, when the catalog offers one.
    var compactVariant: VoiceVariant? {
        variants?["int8"]
    }

    /// Whether downloads and sizes currently follow the Compact
    /// setting for this voice: the setting is on and a variant exists.
    private var compactSelected: Bool {
        ModelFormat.current == .compact && compactVariant != nil
    }

    var voiceSize: Int {
        if let split {
            // Split entries download the encoder+decoder parts instead
            // of the full model: the displayed size is the pair plus
            // the config file every layout shares.
            let configSize = jsonPath.flatMap { files[$0]?.size_bytes } ?? 0
            return split.encoder.sizeBytes + split.decoder.sizeBytes + configSize
        }
        let total = files.values.reduce(into: 0) { $0 += $1.size_bytes }
        if compactSelected,
           let variant = compactVariant,
           let modelPath = Array(files.keys).model,
           let modelFile = files[modelPath] {
            return total - modelFile.size_bytes + variant.sizeBytes
        }
        return total
    }
    var voiceSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(voiceSize), countStyle: .binary)
    }
    /// The catalog path of the full model file. For split entries
    /// this stays the standard model path (the parts live next to it
    /// and installs derive the anchor from it), but it is not a
    /// download target then: the loader fetches `split`'s parts.
    var modelPath: String? {
        if compactSelected, let variant = compactVariant {
            return variant.model
        }
        return Array(files.keys).model
    }
    var jsonPath: String? {
        Array(files.keys).json
    }
    /// The catalog's standard (FP16) model file entry, whatever the
    /// current format setting selects for download: update detection
    /// always compares against the builds the catalog describes.
    var catalogModelFile: VoiceFile? {
        guard let modelPath = Array(files.keys).model else {
            return nil
        }
        return files[modelPath]
    }
    /// The catalog's config file entry (shared by every format).
    var catalogJSONFile: VoiceFile? {
        guard let jsonPath else {
            return nil
        }
        return files[jsonPath]
    }
}

extension Voice: Equatable {
    static func == (lhs: Voice, rhs: Voice) -> Bool {
        lhs.key == rhs.key &&
        lhs.name == rhs.name &&
        lhs.quality == rhs.quality &&
        lhs.language == rhs.language &&
        lhs.files == rhs.files
    }
}

extension Voice: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(name)
        hasher.combine(quality)
        hasher.combine(language)
        hasher.combine(files)
    }
}

extension Voice {
    static var unsupportedVoices: Set<String> = {
        return Set<String>([])
    }()
    var isSupported: Bool {
        return !Voice.unsupportedVoices.contains(name)
    }
}
