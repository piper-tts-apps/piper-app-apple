// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

extension FileManager {
    public struct ModelPaths {
        public let model: URL
        public let json: URL
        public let info: ModelInfo?
        /// Key of the voice in the remote catalog (e.g. "en_GB-dii-high").
        /// Set at install time so a catalog row can be matched to its
        /// installed files even when the model config's own metadata
        /// (dataset, quality) disagrees with the catalog entry.
        public var catalogKey: String?
        public init?(model: URL?, json: URL?) {
            guard let model, let json else {
                return nil
            }
            self.model = model
            self.json = json
            self.info = try? ModelInfo.create(from: json)
        }

        /// Location of the encoder part of a split voice, derived from the
        /// model URL using the fixed storage file name libpiper expects
        /// next to the model (see Constants).
        public var encoder: URL {
            return model.deletingLastPathComponent()
                .appendingPathComponent(PiperAppUtils.Constants.modelEncoderFileNameWithExtension)
        }

        /// Location of the decoder part of a split voice (see `encoder`).
        public var decoder: URL {
            return model.deletingLastPathComponent()
                .appendingPathComponent(PiperAppUtils.Constants.modelDecoderFileNameWithExtension)
        }

        /// Whether both split voice parts are present next to the model.
        /// libpiper only streams when both exist; with neither (or only
        /// one) the voice is synthesized from the full model as before.
        public var hasSplitModel: Bool {
            return FileManager.default.fileExists(atPath: encoder.path) &&
                FileManager.default.fileExists(atPath: decoder.path)
        }

        /// Finds the split voice parts for a model file among files the
        /// user selected together with it in the import flow. The parts of
        /// `<name>.onnx` are `<name>.encoder.onnx` and `<name>.decoder.onnx`;
        /// both must be present and belong to the model.
        public static func splitModelFiles(
            forModel model: URL,
            among urls: [URL]
        ) -> (encoder: URL, decoder: URL)? {
            let baseName = model.deletingPathExtension().lastPathComponent
            let encoderName = "\(baseName).encoder.\(PiperAppUtils.Constants.modelExtensiom)"
            let decoderName = "\(baseName).decoder.\(PiperAppUtils.Constants.modelExtensiom)"
            guard let encoder = urls.first(where: { $0.lastPathComponent == encoderName }),
                  let decoder = urls.first(where: { $0.lastPathComponent == decoderName }) else {
                return nil
            }
            return (encoder, decoder)
        }

        /// Classifies an arbitrary import selection into the parts of one
        /// voice: the model is the `.onnx` file that is not a split part,
        /// the json is the `.json` file, and the split parts are matched
        /// to the model with the same rules as `splitModelFiles`.
        /// Files that are none of these (e.g. a readme) are ignored, and
        /// when several models are present the first one wins and only
        /// its own parts are returned.
        public static func importedModelFiles(among urls: [URL]) -> ImportedModelFiles {
            let modelExtension = PiperAppUtils.Constants.modelExtensiom
            let model = urls.first { url in
                url.pathExtension.lowercased() == modelExtension &&
                    !url.lastPathComponent.hasSuffix(".encoder.\(modelExtension)") &&
                    !url.lastPathComponent.hasSuffix(".decoder.\(modelExtension)")
            }
            let json = urls.first {
                $0.pathExtension.lowercased() == PiperAppUtils.Constants.jsonModelExtension
            }
            var encoder: URL?
            var decoder: URL?
            if let model, let split = splitModelFiles(forModel: model, among: urls) {
                encoder = split.encoder
                decoder = split.decoder
            }
            return ImportedModelFiles(model: model, json: json, encoder: encoder, decoder: decoder)
        }

        public var exist: Bool {
            return FileManager.default.fileExists(atPath: model.path) &&
            FileManager.default.fileExists(atPath: json.path)
        }

        public var modelFolder: URL? {
            if self == ModelPaths.engine {
                return nil
            }

            let modelParent = model.deletingLastPathComponent()
            let jsonParent = json.deletingLastPathComponent()
            if modelParent == jsonParent {
                return modelParent
            }
            return nil
        }

        public static var engine: ModelPaths? {
            return ModelPaths(model: FileManager.Constants.modelURL,
                              json: FileManager.Constants.jsonModelURL)
        }

        public static var installNew: ModelPaths? {
            guard let modelsFolder = FileManager.Constants.modelsFolderURL else {
                return nil
            }
            let installNewFolder = modelsFolder.appendingPathComponent(UUID().uuidString)
            return ModelPaths(model: installNewFolder.appendingPathComponent(PiperAppUtils.Constants.modelFileNameWithExtension),
                              json: installNewFolder.appendingPathComponent(PiperAppUtils.Constants.modelJSONFileNameWithExtension))
        }

        public var isInstalled: Bool {
            if self == ModelPaths.engine && exist {
                return true
            }

            return ModelPaths.installed.contains(self)
        }

        @FileBacked<[ModelPaths]>(default: [], urlProvider: {
            Constants.modelsJsonURL
        }) static var installed

        public static var installedModels: [ModelPaths] {
            get {
                var result = Set<ModelPaths>()
                if let legacy = ModelPaths.engine,
                    legacy.exist {
                    result.insert(legacy)
                }
                result.formUnion(installed)
                return Array(result)
            }
            set {
                self.installed = newValue
            }
        }

        /// Finds the installed entry that installing a new model would replace.
        ///
        /// When the catalog key of the voice being installed is known, it is the
        /// reliable identity: some model configs carry metadata that is identical
        /// across catalog entries (e.g. `en_GB-dii-high` and `en_GB-miro-high`
        /// both decode to dataset "working" and quality "training"), so
        /// config-identity matching alone cannot tell such voices apart.
        ///
        /// - Parameters:
        ///   - catalogKey: key of the catalog entry being installed, if known.
        ///   - info: config identity of the model being installed.
        ///   - installed: the currently installed models.
        /// - Returns: the installed entry to uninstall before installing, or `nil`
        ///   when the voice is not already installed.
        public static func duplicate(
            forCatalogKey catalogKey: String?,
            info: ModelInfo?,
            in installed: [ModelPaths]
        ) -> ModelPaths? {
            if let catalogKey {
                if let keyMatch = installed.first(where: { $0.catalogKey == catalogKey }) {
                    return keyMatch
                }
                // No key match: fall back to config-identity matching, but only
                // against legacy installs that predate key tracking. An installed
                // model carrying a different key is a different catalog entry,
                // even when its config is identical.
                guard let info else { return nil }
                return installed.first(where: { $0.catalogKey == nil && $0.info == info })
            }
            guard let info else { return nil }
            return installed.first(where: { $0.info == info })
        }
    }

    enum Error: Swift.Error {
        case nilModelFolderURL
    }

    public var isInstalled: Bool {
        guard let paths = ModelPaths.engine else {
            return false
        }
        return paths.exist
    }

    public func createModelPathsFolder(paths: ModelPaths) throws {
        guard let folder = paths.modelFolder else {
            throw Error.nilModelFolderURL
        }
        try createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.none
        ])
    }
}

extension FileManager.ModelPaths: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model.standardizedFileURL == rhs.model.standardizedFileURL &&
        lhs.json.standardizedFileURL == rhs.json.standardizedFileURL &&
        lhs.info == rhs.info
    }
}

extension FileManager.ModelPaths: Codable {
    enum CodingKeys: String, CodingKey {
        case model
        case json
        case catalogKey
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try values.decode(URL.self, forKey: .model)
        self.json = try values.decode(URL.self, forKey: .json)
        self.info = try? ModelInfo.create(from: self.json)
        self.catalogKey = try values.decodeIfPresent(String.self, forKey: .catalogKey)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(json, forKey: .json)
        try values.encodeIfPresent(catalogKey, forKey: .catalogKey)
    }
}

extension FileManager.ModelPaths: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(model.standardizedFileURL)
        hasher.combine(json.standardizedFileURL)
        hasher.combine(info)
    }
}

/// The parts of one voice found in a single import selection, as
/// classified by `FileManager.ModelPaths.importedModelFiles(among:)`.
/// `encoder` and `decoder` are either both set (and belong to `model`)
/// or both nil; any part may be missing when the user picked a classic
/// model + json voice.
public struct ImportedModelFiles {
    public let model: URL?
    public let json: URL?
    public let encoder: URL?
    public let decoder: URL?

    public init(model: URL?, json: URL?, encoder: URL?, decoder: URL?) {
        self.model = model
        self.json = json
        self.encoder = encoder
        self.decoder = decoder
    }
}
