// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import Foundation

final class VoiceDecodingTests: XCTestCase {

    /// Enriched entry: `license`, `model_license` and `training_data` populated,
    /// as in the hybrid per-voice license catalog.
    private var enrichedJSON: Data {
        // swiftlint:disable:next non_optional_string_data_conversion
        """
        {
          "key":"de_DE-thorsten-medium",
          "name":"thorsten",
          "quality":"medium",
          "language":{"code":"de_DE","family":"de","region":"DE"},
          "files":{
            "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx":{"size_bytes":31951473,"md5_digest":"bfab926dffc60c6006a92d8681046485"}
          },
          "license":"MIT",
          "model_license":"MIT",
          "training_data":{
            "url":"https://github.com/thorstenMueller/Thorsten-Voice",
            "license":"CC0-1.0",
            "license_raw":"CC0"
          }
        }
        """.data(using: .utf8)!
    }

    /// Legacy entry: a voice exactly as the current production catalog serves
    /// it, with none of the license fields. This is the backward-compatibility
    /// case that must never break: decoding succeeds and every new field is nil.
    private var legacyJSON: Data {
        // swiftlint:disable:next non_optional_string_data_conversion
        """
        {
          "key":"de_DE-thorsten-medium",
          "name":"thorsten",
          "quality":"medium",
          "language":{"code":"de_DE","family":"de","region":"DE"},
          "files":{
            "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx":{"size_bytes":31951473,"md5_digest":"bfab926dffc60c6006a92d8681046485"}
          }
        }
        """.data(using: .utf8)!
    }

    /// Partially enriched entry: `training_data` present but explicitly null,
    /// as the enriched catalog writes it for voices without a MODEL_CARD.
    private var nullTrainingDataJSON: Data {
        // swiftlint:disable:next non_optional_string_data_conversion
        """
        {
          "key":"de_DE-dii-high",
          "name":"dii",
          "quality":"high",
          "language":{"code":"de_DE","family":"de","region":"DE"},
          "files":{
            "de/de_DE/dii/high/de_DE-dii-high.onnx":{"size_bytes":31854240,"md5_digest":"1324e35f3060d0681046485"}
          },
          "license":"CC-BY-NC-SA-4.0",
          "model_license":"CC-BY-NC-SA-4.0",
          "training_data":null
        }
        """.data(using: .utf8)!
    }

    func testDecodingEnrichedEntry() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: enrichedJSON)
        XCTAssertEqual(voice.key, "de_DE-thorsten-medium")
        XCTAssertEqual(voice.license, "MIT")
        XCTAssertEqual(voice.modelLicense, "MIT")
        XCTAssertEqual(voice.trainingData?.url, "https://github.com/thorstenMueller/Thorsten-Voice")
        XCTAssertEqual(voice.trainingData?.license, "CC0-1.0")
        XCTAssertEqual(voice.trainingData?.licenseRaw, "CC0")
    }

    func testDecodingLegacyEntry() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: legacyJSON)
        XCTAssertEqual(voice.key, "de_DE-thorsten-medium")
        XCTAssertEqual(voice.name, "thorsten")
        XCTAssertNil(voice.license)
        XCTAssertNil(voice.modelLicense)
        XCTAssertNil(voice.trainingData)
    }

    func testDecodingNullTrainingData() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: nullTrainingDataJSON)
        XCTAssertEqual(voice.license, "CC-BY-NC-SA-4.0")
        XCTAssertEqual(voice.modelLicense, "CC-BY-NC-SA-4.0")
        XCTAssertNil(voice.trainingData)
    }

    /// Entry with an INT8 variant, as the catalog writes it for voices
    /// that offer a Compact build (same identity as the legacy entry).
    private var variantJSON: Data {
        // swiftlint:disable:next non_optional_string_data_conversion
        """
        {
          "key":"de_DE-thorsten-medium",
          "name":"thorsten",
          "quality":"medium",
          "language":{"code":"de_DE","family":"de","region":"DE"},
          "files":{
            "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx":{"size_bytes":31951473,"md5_digest":"bfab926dffc60c6006a92d8681046485"}
          },
          "variants":{
            "int8":{"model":"de/de_DE/thorsten/medium/de_DE-thorsten-medium.int8.onnx","size_bytes":17900000}
          }
        }
        """.data(using: .utf8)!
    }

    func testDecodingVariantEntry() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: variantJSON)
        XCTAssertEqual(voice.compactVariant?.model,
                       "de/de_DE/thorsten/medium/de_DE-thorsten-medium.int8.onnx")
        XCTAssertEqual(voice.compactVariant?.sizeBytes, 17900000)
    }

    func testDecodingWithoutVariants() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: legacyJSON)
        XCTAssertNil(voice.compactVariant)
    }

    func testEqualityIgnoresVariants() throws {
        // Same production-safety rule as the license fields: which builds
        // a voice offers must not change its identity.
        let legacy = try JSONDecoder().decode(Voice.self, from: legacyJSON)
        let withVariant = try JSONDecoder().decode(Voice.self, from: variantJSON)
        XCTAssertEqual(legacy, withVariant)
        XCTAssertEqual(legacy.hashValue, withVariant.hashValue)
    }

    /// Entry with a split (encoder/decoder) build in the top-level
    /// `split` field (issue #94), as a future catalog would write it.
    /// The `files` dict keeps the full model and the config only - the
    /// parts must not appear there.
    private var splitJSON: Data {
        // swiftlint:disable:next non_optional_string_data_conversion
        """
        {
          "key":"de_DE-thorsten-medium",
          "name":"thorsten",
          "quality":"medium",
          "language":{"code":"de_DE","family":"de","region":"DE"},
          "files":{
            "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx":{"size_bytes":31951473,"md5_digest":"bfab926dffc60c6006a92d8681046485"},
            "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx.json":{"size_bytes":4875,"md5_digest":"e39d926dffc60c6006a92d8681046485"}
          },
          "split":{
            "encoder":{"model":"de/de_DE/thorsten/medium/de_DE-thorsten-medium.encoder.onnx","size_bytes":15000000,"md5_digest":"aaaa926dffc60c6006a92d8681046485"},
            "decoder":{"model":"de/de_DE/thorsten/medium/de_DE-thorsten-medium.decoder.onnx","size_bytes":16956298,"md5_digest":"bbbb926dffc60c6006a92d8681046485"}
          }
        }
        """.data(using: .utf8)!
    }

    func testDecodingSplitEntry() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: splitJSON)
        XCTAssertEqual(voice.split?.encoder.model,
                       "de/de_DE/thorsten/medium/de_DE-thorsten-medium.encoder.onnx")
        XCTAssertEqual(voice.split?.encoder.sizeBytes, 15000000)
        XCTAssertEqual(voice.split?.encoder.md5Digest, "aaaa926dffc60c6006a92d8681046485")
        XCTAssertEqual(voice.split?.decoder.model,
                       "de/de_DE/thorsten/medium/de_DE-thorsten-medium.decoder.onnx")
        XCTAssertEqual(voice.split?.decoder.sizeBytes, 16956298)
        XCTAssertEqual(voice.split?.decoder.md5Digest, "bbbb926dffc60c6006a92d8681046485")
    }

    func testDecodingWithoutSplit() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: legacyJSON)
        XCTAssertNil(voice.split)
    }

    func testSplitEntryModelPathStaysTheFullModel() throws {
        // modelPath is the anchor/directory source for split voices,
        // not a download target: it keeps resolving to the files model
        // entry the parts live next to.
        let voice = try JSONDecoder().decode(Voice.self, from: splitJSON)
        XCTAssertEqual(voice.modelPath, "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx")
        XCTAssertEqual(voice.jsonPath, "de/de_DE/thorsten/medium/de_DE-thorsten-medium.onnx.json")
    }

    func testSplitEntryVoiceSizeIsPairPlusConfig() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: splitJSON)
        XCTAssertEqual(voice.voiceSize, 15000000 + 16956298 + 4875)
    }

    func testClassicEntryVoiceSizeSumsFiles() throws {
        let voice = try JSONDecoder().decode(Voice.self, from: legacyJSON)
        XCTAssertEqual(voice.voiceSize, 31951473)
    }

    func testEqualityIgnoresSplit() throws {
        let withSplit = try JSONDecoder().decode(Voice.self, from: splitJSON)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: splitJSON) as? [String: Any])
        dict["split"] = nil
        let withoutSplit = try JSONDecoder().decode(
            Voice.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(withSplit, withoutSplit)
        XCTAssertEqual(withSplit.hashValue, withoutSplit.hashValue)
    }

    func testEqualityIgnoresLicenseFields() throws {
        // Production safety: Voice equality/hash feed installed-voice matching
        // and must stay on the original fields only, so the same voice decoded
        // from the legacy and the enriched catalog compares (and hashes) equal.
        let legacy = try JSONDecoder().decode(Voice.self, from: legacyJSON)
        let enriched = try JSONDecoder().decode(Voice.self, from: enrichedJSON)
        XCTAssertEqual(legacy, enriched)
        XCTAssertEqual(legacy.hashValue, enriched.hashValue)
    }
}
