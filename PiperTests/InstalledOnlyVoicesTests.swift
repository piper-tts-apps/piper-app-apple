// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import PiperAppUtils
import Foundation

/// Regression tests for the 1.0.15 custom-voice regression (#68):
/// a per-language list rendered catalog voices only, so an imported
/// voice counted in Installed languages but had no row to tap.
final class InstalledOnlyVoicesTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func makeModel(dataset: String,
                           code: String,
                           family: String,
                           region: String,
                           quality: String) -> FileManager.ModelPaths? {
        // swiftlint:disable:next non_optional_string_data_conversion
        let json = """
        {
          "dataset":"\(dataset)",
          "piper_version":"1.0.0",
          "language":{"code":"\(code)","family":"\(family)","region":"\(region)"},
          "audio":{"sample_rate":22050,"quality":"\(quality)"}
        }
        """.data(using: .utf8)!
        let base = tempDir.appendingPathComponent(UUID().uuidString)
        let jsonURL = base.appendingPathExtension("onnx.json")
        try? json.write(to: jsonURL)
        let modelURL = base.appendingPathExtension("onnx")
        return FileManager.ModelPaths(model: modelURL, json: jsonURL)
    }

    private func catalogVoice(key: String,
                              name: String,
                              quality: String,
                              code: String) throws -> Voice {
        // swiftlint:disable:next non_optional_string_data_conversion
        let json = """
        {
          "key":"\(key)",
          "name":"\(name)",
          "quality":"\(quality)",
          "language":{"code":"\(code)"},
          "files":{
            "pl/pl_PL/\(name)/\(quality)/\(key).onnx":{"size_bytes":1000},
            "pl/pl_PL/\(name)/\(quality)/\(key).onnx.json":{"size_bytes":100}
          }
        }
        """.data(using: .utf8)!
        return try JSONDecoder().decode(Voice.self, from: json)
    }

    func testCustomVoiceSurfacesAndCatalogVoiceIsNotRepeated() throws {
        let custom = try XCTUnwrap(makeModel(dataset: "my-voice",
                                             code: "pl_PL",
                                             family: "pl",
                                             region: "PL",
                                             quality: "medium"))
        let catalogInstalled = try XCTUnwrap(makeModel(dataset: "glos",
                                                       code: "pl_PL",
                                                       family: "pl",
                                                       region: "PL",
                                                       quality: "medium"))
        let catalog = try catalogVoice(key: "pl_PL-glos-medium",
                                       name: "glos",
                                       quality: "medium",
                                       code: "pl_PL")
        let result = MainHostModel.installedOnlyModels(for: "pl_PL",
                                                       installed: [custom, catalogInstalled],
                                                       catalogVoices: [catalog],
                                                       catalogLanguageCodes: ["pl_PL"])
        XCTAssertEqual(result.map { $0.model.path }, [custom.model.path])
    }

    func testBareLanguageCodeResolvesToSingleCatalogLanguage() throws {
        let custom = try XCTUnwrap(makeModel(dataset: "my-uk-voice",
                                             code: "uk",
                                             family: "uk",
                                             region: "",
                                             quality: "medium"))
        let result = MainHostModel.installedOnlyModels(for: "uk_UA",
                                                       installed: [custom],
                                                       catalogVoices: [],
                                                       catalogLanguageCodes: ["uk_UA"])
        XCTAssertEqual(result.map { $0.model.path }, [custom.model.path])
    }

    func testVoiceWithoutLanguageStaysUngrouped() throws {
        let jsonURL = tempDir.appendingPathComponent(UUID().uuidString + ".onnx.json")
        try Data("{}".utf8).write(to: jsonURL)
        let modelURL = tempDir.appendingPathComponent(UUID().uuidString + ".onnx")
        let model = try XCTUnwrap(FileManager.ModelPaths(model: modelURL, json: jsonURL))
        XCTAssertNil(model.info)
        let result = MainHostModel.installedOnlyModels(for: "pl_PL",
                                                       installed: [model],
                                                       catalogVoices: [],
                                                       catalogLanguageCodes: ["pl_PL"])
        XCTAssertTrue(result.isEmpty)
    }
}
