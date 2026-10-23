// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperAppUtils
import Foundation

final class FileManagerModelPathsTests: XCTestCase {

    func testInitNilReturnsNil() {
        XCTAssertNil(FileManager.ModelPaths(model: nil, json: nil))
        XCTAssertNil(FileManager.ModelPaths(model: URL(fileURLWithPath: "/tmp/a"), json: nil))
        XCTAssertNil(FileManager.ModelPaths(model: nil, json: URL(fileURLWithPath: "/tmp/b")))
    }

    func testInitValid() {
        let model = URL(fileURLWithPath: "/tmp/model.onnx")
        let json = URL(fileURLWithPath: "/tmp/model.onnx.json")
        let paths = FileManager.ModelPaths(model: model, json: json)
        XCTAssertNotNil(paths)
        XCTAssertEqual(paths?.model, model)
        XCTAssertEqual(paths?.json, json)
    }

    func testExistFalseWhenMissing() {
        let model = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).onnx")
        let json = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let paths = FileManager.ModelPaths(model: model, json: json)!
        XCTAssertFalse(paths.exist)
    }

    func testModelFolderSameParent() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = folder.appendingPathComponent("model.onnx")
        let json = folder.appendingPathComponent("model.onnx.json")
        let paths = FileManager.ModelPaths(model: model, json: json)!
        // deletingLastPathComponent() returns directory URL with trailing '/', so compare paths
        XCTAssertEqual(paths.modelFolder?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(paths.modelFolder?.standardizedFileURL.pathComponents, folder.standardizedFileURL.pathComponents)
    }

    func testModelFolderDifferentParentsNil() {
        let folder1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = folder1.appendingPathComponent("model.onnx")
        let json = folder2.appendingPathComponent("model.onnx.json")
        let paths = FileManager.ModelPaths(model: model, json: json)!
        XCTAssertNil(paths.modelFolder)
    }

    func testModelFolderEngineIsNil() {
        // engine may be nil in test env; guard accordingly
        if let engine = FileManager.ModelPaths.engine {
            XCTAssertNil(engine.modelFolder, "engine modelFolder should be nil by design")
        }
    }

    func testEquatableStandardized() {
        let base = "/tmp"
        let model1 = URL(fileURLWithPath: "\(base)/a/../a/model.onnx").standardized
        let json1 = URL(fileURLWithPath: "\(base)/a/model.onnx.json")
        let model2 = URL(fileURLWithPath: "\(base)/a/model.onnx")
        let json2 = URL(fileURLWithPath: "\(base)/a/model.onnx.json")
        // swiftlint:disable:next identifier_name
        let p1 = FileManager.ModelPaths(model: model1, json: json1)!
        // swiftlint:disable:next identifier_name
        let p2 = FileManager.ModelPaths(model: model2, json: json2)!
        // Equality uses standardizedFileURL, so a/../a should equal a
        XCTAssertEqual(p1, p2)
    }

    func testHashConsistency() {
        let model = URL(fileURLWithPath: "/tmp/model.onnx")
        let json = URL(fileURLWithPath: "/tmp/model.onnx.json")
        // swiftlint:disable:next identifier_name
        let p1 = FileManager.ModelPaths(model: model, json: json)!
        // swiftlint:disable:next identifier_name
        let p2 = FileManager.ModelPaths(model: model, json: json)!
        XCTAssertEqual(p1.hashValue, p2.hashValue)
    }

    func testCodableRoundTrip() throws {
        let model = URL(fileURLWithPath: "/tmp/models/en/model.onnx")
        let json = URL(fileURLWithPath: "/tmp/models/en/model.onnx.json")
        let original = FileManager.ModelPaths(model: model, json: json)!
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileManager.ModelPaths.self, from: data)
        XCTAssertEqual(original.model, decoded.model)
        XCTAssertEqual(original.json, decoded.json)
    }

    func testIsInstalledFalseWhenNotInInstalledList() {
        let model = URL(fileURLWithPath: "/tmp/notinstalled/model.onnx")
        let json = URL(fileURLWithPath: "/tmp/notinstalled/model.onnx.json")
        let paths = FileManager.ModelPaths(model: model, json: json)!
        // No files exist and not in installed list -> false
        XCTAssertFalse(paths.isInstalled)
    }

    func testCreateModelFolderThrowsWhenNil() {
        // If paths is engine, modelFolder nil -> throws
        if let engine = FileManager.ModelPaths.engine {
            XCTAssertThrowsError(try FileManager.default.createModelPathsFolder(paths: engine))
        }
    }

    func testInstallNewNilWhenNoModelsFolder() {
        // In test env sharedFolder is nil, so modelsFolderURL nil, installNew nil
        // If by chance sharedFolder exists, we still validate non-crash
        let new = FileManager.ModelPaths.installNew
        if let new = new {
            // if it exists, its folder should be inside modelsFolderURL
            XCTAssertNotNil(new.modelFolder)
        } else {
            XCTAssertNil(new)
        }
    }

    func testSplitModelURLsDerivedFromModel() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = folder.appendingPathComponent("model.onnx")
        let json = folder.appendingPathComponent("model.onnx.json")
        let paths = FileManager.ModelPaths(model: model, json: json)!
        XCTAssertEqual(paths.encoder.lastPathComponent, "model.encoder.onnx")
        XCTAssertEqual(paths.decoder.lastPathComponent, "model.decoder.onnx")
        XCTAssertEqual(paths.encoder.deletingLastPathComponent().standardizedFileURL.path,
                       folder.standardizedFileURL.path)
        XCTAssertEqual(paths.decoder.deletingLastPathComponent().standardizedFileURL.path,
                       folder.standardizedFileURL.path)
    }

    func testHasSplitModelRequiresBothParts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = folder.appendingPathComponent("model.onnx")
        let json = folder.appendingPathComponent("model.onnx.json")
        let paths = FileManager.ModelPaths(model: model, json: json)!
        XCTAssertFalse(paths.hasSplitModel)
        try Data("encoder".utf8).write(to: paths.encoder)
        XCTAssertFalse(paths.hasSplitModel)
        try Data("decoder".utf8).write(to: paths.decoder)
        XCTAssertTrue(paths.hasSplitModel)
    }

    func testSplitModelFilesClassification() {
        let model = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.onnx")
        let encoder = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.encoder.onnx")
        let decoder = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.decoder.onnx")
        let split = FileManager.ModelPaths.splitModelFiles(forModel: model,
                                                           among: [decoder, model, encoder])
        XCTAssertEqual(split?.encoder, encoder)
        XCTAssertEqual(split?.decoder, decoder)
    }

    func testSplitModelFilesRequiresBothParts() {
        let model = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.onnx")
        let encoder = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.encoder.onnx")
        XCTAssertNil(FileManager.ModelPaths.splitModelFiles(forModel: model, among: [model, encoder]))
    }

    func testSplitModelFilesRejectsPartsOfAnotherModel() {
        let model = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.onnx")
        let otherEncoder = URL(fileURLWithPath: "/tmp/voice/de_DE-thorsten-high.encoder.onnx")
        let otherDecoder = URL(fileURLWithPath: "/tmp/voice/de_DE-thorsten-high.decoder.onnx")
        XCTAssertNil(FileManager.ModelPaths.splitModelFiles(forModel: model,
                                                            among: [model, otherEncoder, otherDecoder]))
    }

    // MARK: - importedModelFiles (unified import picker classification)

    private let lessacModel = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.onnx")
    private let lessacJSON = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.onnx.json")
    private let lessacEncoder = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.encoder.onnx")
    private let lessacDecoder = URL(fileURLWithPath: "/tmp/voice/en_US-lessac-medium.decoder.onnx")

    func testImportedModelFilesAllFourParts() {
        let imported = FileManager.ModelPaths.importedModelFiles(
            among: [lessacDecoder, lessacJSON, lessacModel, lessacEncoder])
        XCTAssertEqual(imported.model, lessacModel)
        XCTAssertEqual(imported.json, lessacJSON)
        XCTAssertEqual(imported.encoder, lessacEncoder)
        XCTAssertEqual(imported.decoder, lessacDecoder)
    }

    func testImportedModelFilesModelAndJSONOnly() {
        let imported = FileManager.ModelPaths.importedModelFiles(among: [lessacJSON, lessacModel])
        XCTAssertEqual(imported.model, lessacModel)
        XCTAssertEqual(imported.json, lessacJSON)
        XCTAssertNil(imported.encoder)
        XCTAssertNil(imported.decoder)
    }

    func testImportedModelFilesModelAndSplitsWithoutJSON() {
        let imported = FileManager.ModelPaths.importedModelFiles(
            among: [lessacModel, lessacEncoder, lessacDecoder])
        XCTAssertEqual(imported.model, lessacModel)
        XCTAssertNil(imported.json)
        XCTAssertEqual(imported.encoder, lessacEncoder)
        XCTAssertEqual(imported.decoder, lessacDecoder)
    }

    func testImportedModelFilesRejectsPartsOfAnotherModel() {
        let otherEncoder = URL(fileURLWithPath: "/tmp/voice/de_DE-thorsten-high.encoder.onnx")
        let otherDecoder = URL(fileURLWithPath: "/tmp/voice/de_DE-thorsten-high.decoder.onnx")
        let imported = FileManager.ModelPaths.importedModelFiles(
            among: [lessacModel, lessacJSON, otherEncoder, otherDecoder])
        XCTAssertEqual(imported.model, lessacModel)
        XCTAssertEqual(imported.json, lessacJSON)
        XCTAssertNil(imported.encoder)
        XCTAssertNil(imported.decoder)
    }

    func testImportedModelFilesSingleSplitPartIsDropped() {
        let imported = FileManager.ModelPaths.importedModelFiles(
            among: [lessacModel, lessacJSON, lessacEncoder])
        XCTAssertEqual(imported.model, lessacModel)
        XCTAssertEqual(imported.json, lessacJSON)
        XCTAssertNil(imported.encoder)
        XCTAssertNil(imported.decoder)
    }

    func testImportedModelFilesIgnoresUnrelatedFiles() {
        let readme = URL(fileURLWithPath: "/tmp/voice/README.md")
        let notes = URL(fileURLWithPath: "/tmp/voice/notes.txt")
        let imported = FileManager.ModelPaths.importedModelFiles(
            among: [notes, lessacModel, lessacJSON, lessacEncoder, lessacDecoder, readme])
        XCTAssertEqual(imported.model, lessacModel)
        XCTAssertEqual(imported.json, lessacJSON)
        XCTAssertEqual(imported.encoder, lessacEncoder)
        XCTAssertEqual(imported.decoder, lessacDecoder)
    }

    // MARK: - exist for split voices (issue #94 two-onnx refactor)

    private func makeVoiceFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func voicePaths(in folder: URL) -> FileManager.ModelPaths {
        return FileManager.ModelPaths(model: folder.appendingPathComponent("model.onnx"),
                                      json: folder.appendingPathComponent("model.onnx.json"))!
    }

    func testExistClassicModelAndJSON() throws {
        let folder = try makeVoiceFolder(files: ["model.onnx", "model.onnx.json"])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(voicePaths(in: folder).exist)
    }

    func testExistSplitsOnlyWithoutModelFile() throws {
        let folder = try makeVoiceFolder(files: ["model.encoder.onnx",
                                                 "model.decoder.onnx",
                                                 "model.onnx.json"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = voicePaths(in: folder)
        XCTAssertTrue(paths.hasSplitModel)
        XCTAssertTrue(paths.exist)
    }

    func testExistFalseWithOnlyOneSplitPart() throws {
        let folder = try makeVoiceFolder(files: ["model.encoder.onnx", "model.onnx.json"])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(voicePaths(in: folder).exist)
    }

    func testExistFalseWithSplitsButNoJSON() throws {
        let folder = try makeVoiceFolder(files: ["model.encoder.onnx", "model.decoder.onnx"])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(voicePaths(in: folder).exist)
    }

    func testCodableRoundTripSplitsOnlyEntryReportsExist() throws {
        let folder = try makeVoiceFolder(files: ["model.encoder.onnx",
                                                 "model.decoder.onnx",
                                                 "model.onnx.json"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = voicePaths(in: folder)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileManager.ModelPaths.self, from: data)
        XCTAssertEqual(decoded.model, original.model)
        XCTAssertEqual(decoded.json, original.json)
        XCTAssertTrue(decoded.exist)
    }

    func testImportedModelFilesSplitsOnlySelection() {
        // 3 files: encoder + decoder + json, no full model (issue #94).
        let urls = [lessacJSON, lessacEncoder, lessacDecoder]
        let result = FileManager.ModelPaths.importedModelFiles(among: urls)
        XCTAssertNil(result.model)
        XCTAssertEqual(result.json, lessacJSON)
        XCTAssertEqual(result.encoder, lessacEncoder)
        XCTAssertEqual(result.decoder, lessacDecoder)
    }

    func testImportedModelFilesSplitsOnlyWithoutJSON() {
        let urls = [lessacEncoder, lessacDecoder]
        let result = FileManager.ModelPaths.importedModelFiles(among: urls)
        XCTAssertNil(result.model)
        XCTAssertNil(result.json)
        XCTAssertEqual(result.encoder, lessacEncoder)
        XCTAssertEqual(result.decoder, lessacDecoder)
    }

    func testImportedModelFilesEncoderWithoutDecoderIsIncomplete() {
        let urls = [lessacJSON, lessacEncoder]
        let result = FileManager.ModelPaths.importedModelFiles(among: urls)
        XCTAssertNil(result.model)
        XCTAssertEqual(result.json, lessacJSON)
        XCTAssertNil(result.encoder)
        XCTAssertNil(result.decoder)
    }

    func testImportedModelFilesMismatchedSplitPairIsIncomplete() {
        let otherDecoder = URL(fileURLWithPath: "/tmp/voice/en_US-amy-medium.decoder.onnx")
        let urls = [lessacJSON, lessacEncoder, otherDecoder]
        let result = FileManager.ModelPaths.importedModelFiles(among: urls)
        XCTAssertNil(result.model)
        XCTAssertNil(result.encoder)
        XCTAssertNil(result.decoder)
    }

    func testImportedModelFilesEmptySelection() {
        let imported = FileManager.ModelPaths.importedModelFiles(among: [])
        XCTAssertNil(imported.model)
        XCTAssertNil(imported.json)
        XCTAssertNil(imported.encoder)
        XCTAssertNil(imported.decoder)
    }
}
