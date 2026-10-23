// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils

extension FileManager {
    enum InstallError: Swift.Error {
        case invalidSourceFiles
        case invalidDestinationURLs
        case cantParseModelInfo
    }

    func install(paths: ModelPaths?,
                 catalogKey: String? = nil,
                 encoder: URL? = nil,
                 decoder: URL? = nil) throws {
        guard let paths else {
            throw InstallError.invalidSourceFiles
        }

        guard let destination = ModelPaths.installNew else {
            throw InstallError.invalidDestinationURLs
        }

        do {
            // Resolve which installed entry this download replaces, if any.
            // The catalog key is the reliable identity: some model configs
            // (e.g. en_GB-dii-high and en_GB-miro-high) decode to identical
            // ModelInfo values, so config-identity matching alone would treat
            // such voices as the same entry and uninstall each other.
            let alreadyInstalled = FileManager.ModelPaths.duplicate(
                forCatalogKey: catalogKey,
                info: paths.info,
                in: FileManager.ModelPaths.installedModels
            )
            if let installedPath = alreadyInstalled {
                try uninstall(paths: installedPath)
            }
        } catch {
            Log.debug("Error happened while uninstalling. Error: \(error)")
        }

        let fileManager = FileManager.default
        try fileManager.createModelPathsFolder(paths: destination)
        try fileManager.copyItem(at: paths.json, to: destination.json)
        try fileManager.markFileAsUnprotected(at: destination.json)
        try fileManager.copyItem(at: paths.model, to: destination.model)
        try fileManager.markFileAsUnprotected(at: destination.model)

        // Optional split voice parts (issue #94 streaming)
        if let encoder, let decoder {
            copySplitModelParts(encoder: encoder, decoder: decoder, to: destination)
        }

        if let info = paths.info, info.language.code.lowercased().hasPrefix("zh") {
            if let g2pwFolder = FileManager.Constants.g2pwFolderURL,
               FileManager.Constants.g2pwFileExists(),
               let modelFolder = destination.modelFolder {
                for file in FileManager.Constants.g2pwRequiredFiles {
                    let src = g2pwFolder.appendingPathComponent(file)
                    let dest = modelFolder.appendingPathComponent(file)
                    if fileManager.fileExists(atPath: dest.path) { continue }
                    try? fileManager.copyItem(at: src, to: dest)
                    try? fileManager.markFileAsUnprotected(at: dest)
                }
            }
        }
        var installedModels = FileManager.ModelPaths.installedModels
        var installedEntry = destination
        installedEntry.catalogKey = catalogKey
        installedModels.append(installedEntry)
        FileManager.ModelPaths.installedModels = installedModels
    }

    /// Stores split voice parts next to an installed model, under the
    /// fixed names libpiper derives from the model path. Best effort with
    /// no half-installed pair: without the parts the voice still works
    /// (threaded, unsplit), so a failed copy must not fail the install -
    /// on any failure both parts are removed again.
    private func copySplitModelParts(encoder: URL,
                                     decoder: URL,
                                     to destination: ModelPaths) {
        let fileManager = FileManager.default
        do {
            try fileManager.copyItem(at: encoder, to: destination.encoder)
            try fileManager.markFileAsUnprotected(at: destination.encoder)
            try fileManager.copyItem(at: decoder, to: destination.decoder)
            try fileManager.markFileAsUnprotected(at: destination.decoder)
        } catch {
            Log.error("Failed to install split model parts. Error: \(error)")
            try? fileManager.removeItem(at: destination.encoder)
            try? fileManager.removeItem(at: destination.decoder)
        }
    }

    func uninstall(paths: ModelPaths?) throws {

        guard let installed = paths else {
            throw InstallError.invalidDestinationURLs
        }

        var installedModels = FileManager.ModelPaths.installedModels
        installedModels.removeAll(where: { path in
            path == paths
        })
        FileManager.ModelPaths.installedModels = installedModels
        let fileManager = FileManager.default
        try fileManager.removeItem(at: installed.model)
        try fileManager.removeItem(at: installed.json)
        // Split voice parts live next to the model under fixed names; the
        // folder removal below covers them for folder-backed installs, but
        // remove them explicitly so no pair survives a folder-less path.
        try? fileManager.removeItem(at: installed.encoder)
        try? fileManager.removeItem(at: installed.decoder)

        if let modelFolder = installed.modelFolder {
            try fileManager.removeItem(at: modelFolder)
        }
    }

    enum Error: Swift.Error {
        case nilTemporaryDirectory
    }

    static var tempFolderInDocumentDirectory: URL? {
        let temporaryDirectoryURL = URL(filePath: NSTemporaryDirectory())
        return temporaryDirectoryURL.appending(component: "temporary_folder")
    }

    func createTemporaryDirectoryIfNeeded() throws {
        guard let temporaryDirectoryURL = FileManager.tempFolderInDocumentDirectory else {
            throw Error.nilTemporaryDirectory
        }
        if !FileManager.default.fileExists(atPath: temporaryDirectoryURL.path) {
            try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true, attributes:
                                                        [.protectionKey: FileProtectionType.none]
            )
        }
    }

    func cleanTemporaryDirectory() throws {
        guard let temporaryDirectoryURL = FileManager.tempFolderInDocumentDirectory else {
            throw Error.nilTemporaryDirectory
        }
        let fileManager = FileManager.default
        try fileManager.removeItem(at: temporaryDirectoryURL)
    }

    func moveToTemporaryDirectory(fileURL: URL) throws -> URL {
        guard let temporaryDirectoryURL = FileManager.tempFolderInDocumentDirectory else {
            throw Error.nilTemporaryDirectory
        }
        try createTemporaryDirectoryIfNeeded()
        let movedFileURL = temporaryDirectoryURL.appendingPathComponent(UUID().uuidString)
        try self.copyItem(at: fileURL, to: movedFileURL)
        return movedFileURL
    }

    private func markFileAsUnprotected(at url: URL) throws {
        try setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: url.path
        )
    }

    func markModelsFolderAsUnprotected() {
        guard let modelsFolderURL = FileManager.Constants.modelsFolderURL else {
            return
        }

        do {
            try markFileAsUnprotected(at: modelsFolderURL)
        } catch {
            Log.error("Failed to mark models folder as unprotected: \(error)")
        }

        guard let enumerator = FileManager.default.enumerator(
            at: modelsFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            do {
                try markFileAsUnprotected(at: fileURL)
            } catch {
                Log.error("Failed to make file unprotected: \(error)")
            }
        }
    }
}

extension FileManager.ModelPaths {
    var modelTitle: String {
        guard let modelInfo = info else {
            return "Unknown"
        }

        return "\(modelInfo.name.capitalized) \(modelInfo.language.code.localizedLanguageFromCode)"
    }
}
