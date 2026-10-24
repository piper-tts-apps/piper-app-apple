// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import PiperAppUtils
import Foundation

final class VoiceUpdateCheckerTests: XCTestCase {

    private typealias Installed = VoiceUpdateChecker.InstalledFiles

    /// Catalog entry with digests on both files and an INT8 variant,
    /// shaped exactly like the live fp16 catalog.
    private var catalogJSON: Data {
        // swiftlint:disable:next non_optional_string_data_conversion
        """
        {
          "key":"en_US-lessac-medium",
          "name":"lessac",
          "quality":"medium",
          "language":{"code":"en_US","family":"en","region":"US"},
          "files":{
            "en/en_US/lessac/medium/en_US-lessac-medium.onnx":{"size_bytes":1000,"md5_digest":"aaaa"},
            "en/en_US/lessac/medium/en_US-lessac-medium.onnx.json":{"size_bytes":100,"md5_digest":"bbbb"},
            "en/en_US/lessac/medium/MODEL_CARD":{"size_bytes":10,"md5_digest":"cccc"}
          },
          "variants":{
            "int8":{"model":"en/en_US/lessac/medium/en_US-lessac-medium.int8.onnx","size_bytes":600}
          }
        }
        """.data(using: .utf8)!
    }

    private func decodeVoice() throws -> Voice {
        try JSONDecoder().decode(Voice.self, from: catalogJSON)
    }

    func testCatalogDigestsDecoded() throws {
        let voice = try decodeVoice()
        XCTAssertEqual(voice.catalogModelFile?.md5Digest, "aaaa")
        XCTAssertEqual(voice.catalogModelFile?.size_bytes, 1000)
        XCTAssertEqual(voice.catalogJSONFile?.md5Digest, "bbbb")
    }

    func testDigestDoesNotChangeVoiceIdentity() throws {
        // The same production-safety rule as licenses and variants:
        // digests feed update detection only, never equality/hash.
        let voice = try decodeVoice()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogJSON) as? [String: Any])
        var files = try XCTUnwrap(json["files"] as? [String: Any])
        for path in Array(files.keys) {
            var file = try XCTUnwrap(files[path] as? [String: Any])
            file["md5_digest"] = "ffff"
            files[path] = file
        }
        json["files"] = files
        let otherData = try JSONSerialization.data(withJSONObject: json)
        let other = try JSONDecoder().decode(Voice.self, from: otherData)
        XCTAssertEqual(voice, other)
        XCTAssertEqual(voice.hashValue, other.hashValue)
    }

    func testUpToDateStandardBuild() throws {
        let voice = try decodeVoice()
        let installed = Installed(modelSize: 1000, modelMD5: "aaaa", configMD5: "bbbb")
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .upToDate)
    }

    func testRetrainedModelIsUpdate() throws {
        let voice = try decodeVoice()
        let installed = Installed(modelSize: 1000, modelMD5: "dddd", configMD5: "bbbb")
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
    }

    func testConfigOnlyChangeIsUpdate() throws {
        // The 2026-10-03 dataset fixes changed only .onnx.json files.
        let voice = try decodeVoice()
        let installed = Installed(modelSize: 1000, modelMD5: "aaaa", configMD5: "eeee")
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
    }

    func testCompactBuildCurrentByVariantSize() throws {
        // Installed model is the INT8 build: its digest cannot match
        // the standard build's, but its size is the variant's size.
        let voice = try decodeVoice()
        let installed = Installed(modelSize: 600, modelMD5: "dddd", configMD5: "bbbb")
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .upToDate)
    }

    func testCompactBuildStaleWhenVariantSizeChanges() throws {
        let voice = try decodeVoice()
        let installed = Installed(modelSize: 590, modelMD5: "dddd", configMD5: "bbbb")
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
    }

    func testDigestComparisonIsCaseInsensitive() throws {
        let voice = try decodeVoice()
        let installed = Installed(modelSize: 1000, modelMD5: "AAAA", configMD5: "BBBB")
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .upToDate)
    }

    func testSizeOnlyDifferenceIsUpdate() {
        let status = VoiceUpdateChecker.status(
            catalogModelMD5: nil, catalogModelSize: 1000,
            catalogConfigMD5: nil, variantModelSize: 600,
            installed: Installed(modelSize: 900, modelMD5: nil, configMD5: nil))
        XCTAssertEqual(status, .updateAvailable)
    }

    func testSizeMatchWithoutDigestsIsUnknown() {
        // A rebuilt model can keep its byte size; without digests
        // the checker must not claim the voice is up to date.
        let status = VoiceUpdateChecker.status(
            catalogModelMD5: nil, catalogModelSize: 1000,
            catalogConfigMD5: nil, variantModelSize: nil,
            installed: Installed(modelSize: 1000, modelMD5: nil, configMD5: nil))
        XCTAssertEqual(status, .unknown)
    }

    func testUnreadableInstalledFilesAreUnknown() throws {
        let voice = try decodeVoice()
        let installed = Installed(modelSize: nil, modelMD5: nil, configMD5: nil)
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .unknown)
    }

    func testUpdateAvailableKeys() throws {
        let voice = try decodeVoice()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let model = folder.appendingPathComponent("model.onnx")
        let json = folder.appendingPathComponent("model.onnx.json")
        var stale = try XCTUnwrap(FileManager.ModelPaths(model: model, json: json))
        stale.catalogKey = voice.key
        var current = try XCTUnwrap(FileManager.ModelPaths(model: model, json: json))
        current.catalogKey = "other-voice"

        let keys = VoiceUpdateChecker.updateAvailableKeys(
            voices: [voice],
            installed: [stale, current]
        ) { paths in
            paths.catalogKey == voice.key
                ? Installed(modelSize: 1000, modelMD5: "dddd", configMD5: "bbbb")
                : Installed(modelSize: 1000, modelMD5: "aaaa", configMD5: "bbbb")
        }
        XCTAssertEqual(keys, [voice.key])
    }

    // MARK: - Splits-only installs (issue #94)

    /// Catalog entry whose voice also ships a split build: the
    /// top-level `split` field carries per-part paths, sizes, digests.
    private var splitCatalogJSON: Data {
        // swiftlint:disable:next non_optional_string_data_conversion
        """
        {
          "key":"en_US-lessac-medium",
          "name":"lessac",
          "quality":"medium",
          "language":{"code":"en_US","family":"en","region":"US"},
          "files":{
            "en/en_US/lessac/medium/en_US-lessac-medium.onnx":{"size_bytes":1000,"md5_digest":"aaaa"},
            "en/en_US/lessac/medium/en_US-lessac-medium.onnx.json":{"size_bytes":100,"md5_digest":"bbbb"},
            "en/en_US/lessac/medium/MODEL_CARD":{"size_bytes":10,"md5_digest":"cccc"}
          },
          "split":{
            "encoder":{"model":"en/en_US/lessac/medium/en_US-lessac-medium.encoder.onnx","size_bytes":400,"md5_digest":"eeee"},
            "decoder":{"model":"en/en_US/lessac/medium/en_US-lessac-medium.decoder.onnx","size_bytes":600,"md5_digest":"ffff"}
          }
        }
        """.data(using: .utf8)!
    }

    private func decodeSplitVoice() throws -> Voice {
        try JSONDecoder().decode(Voice.self, from: splitCatalogJSON)
    }

    func testSplitsOnlyUpToDate() throws {
        let voice = try decodeSplitVoice()
        let installed = Installed(modelSize: 1000, modelMD5: nil, configMD5: "bbbb",
                                  isSplitsOnly: true,
                                  splitEncoderMD5: "eeee", splitDecoderMD5: "ffff",
                                  splitEncoderSize: 400, splitDecoderSize: 600)
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .upToDate)
    }

    func testSplitsOnlyPartDigestDiffersIsUpdate() throws {
        let voice = try decodeSplitVoice()
        let installed = Installed(modelSize: 1000, modelMD5: nil, configMD5: "bbbb",
                                  isSplitsOnly: true,
                                  splitEncoderMD5: "eeee", splitDecoderMD5: "dddd",
                                  splitEncoderSize: 400, splitDecoderSize: 600)
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
    }

    func testSplitsOnlyConfigChangeIsUpdate() throws {
        let voice = try decodeSplitVoice()
        let installed = Installed(modelSize: 1000, modelMD5: nil, configMD5: "eeee",
                                  isSplitsOnly: true,
                                  splitEncoderMD5: "eeee", splitDecoderMD5: "ffff",
                                  splitEncoderSize: 400, splitDecoderSize: 600)
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
    }

    func testSplitsOnlyAgainstEntryWithoutSplitIsUnknown() throws {
        // The catalog entry has no split build (e.g. the voice was
        // imported from files): there is nothing to compare the parts
        // against. The classic size fallback must NOT fire here - the
        // pair's total (999) never equals the full model's size, so the
        // classic logic would wrongly report an update.
        let voice = try decodeVoice()
        let installed = Installed(modelSize: 999, modelMD5: nil, configMD5: "bbbb",
                                  isSplitsOnly: true,
                                  splitEncoderMD5: "eeee", splitDecoderMD5: "ffff",
                                  splitEncoderSize: 400, splitDecoderSize: 599)
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .unknown)
    }

    func testSplitsOnlySizeDifferenceWithoutDigestsIsUpdate() throws {
        // Split entry without digests: part sizes are the only evidence.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: splitCatalogJSON) as? [String: Any])
        var split = try XCTUnwrap(json["split"] as? [String: Any])
        for part in ["encoder", "decoder"] {
            var entry = try XCTUnwrap(split[part] as? [String: Any])
            entry["md5_digest"] = nil
            split[part] = entry
        }
        json["split"] = split
        let voice = try JSONDecoder().decode(Voice.self, from: JSONSerialization.data(withJSONObject: json))
        let installed = Installed(modelSize: 1001, modelMD5: nil, configMD5: "bbbb",
                                  isSplitsOnly: true,
                                  splitEncoderMD5: nil, splitDecoderMD5: nil,
                                  splitEncoderSize: 401, splitDecoderSize: 600)
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
    }

    func testSplitsOnlySizeMatchWithoutDigestsIsUnknown() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: splitCatalogJSON) as? [String: Any])
        var split = try XCTUnwrap(json["split"] as? [String: Any])
        for part in ["encoder", "decoder"] {
            var entry = try XCTUnwrap(split[part] as? [String: Any])
            entry["md5_digest"] = nil
            split[part] = entry
        }
        json["split"] = split
        let voice = try JSONDecoder().decode(Voice.self, from: JSONSerialization.data(withJSONObject: json))
        let installed = Installed(modelSize: 1000, modelMD5: nil, configMD5: "bbbb",
                                  isSplitsOnly: true,
                                  splitEncoderMD5: nil, splitDecoderMD5: nil,
                                  splitEncoderSize: 400, splitDecoderSize: 600)
        XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .unknown)
    }

    func testMD5DigestOfFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(VoiceUpdateChecker.md5Digest(ofFileAt: url),
                       "900150983cd24fb0d6963f7d28e17f72")
    }

    func testMD5DigestReadsInChunks() throws {
        // Larger than the 1 MB read chunk, so the loop must iterate.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x61, count: 1_500_000).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(VoiceUpdateChecker.md5Digest(ofFileAt: url),
                       "de903a5a2a7df6cef1817c455d413359")
    }

    func testMD5DigestOfMissingFileIsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertNil(VoiceUpdateChecker.md5Digest(ofFileAt: url))
    }
}
