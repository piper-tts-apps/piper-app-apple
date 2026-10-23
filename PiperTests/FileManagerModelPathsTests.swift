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
}
