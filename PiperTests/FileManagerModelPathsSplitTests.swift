// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import PiperAppUtils
import Foundation

/// Split-voice cases for `FileManagerModelPathsTests` (issue #94
/// two-onnx refactor), kept in an extension so the main test class
/// stays within its size budget.
extension FileManagerModelPathsTests {

    // MARK: - exist for split voices (issue #94 two-onnx refactor)

    func makeVoiceFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    func voicePaths(in folder: URL) -> FileManager.ModelPaths {
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

    // MARK: - importedModelFiles splits-only selections (issue #94)

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
}
