// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import Foundation

/// Streaming voices setting cases for `VoiceUpdateCheckerTests`
/// (issue #94), kept in an extension so the main test class stays
/// within its size budget. The comparison follows the installed
/// layout, never the setting - these tests pin that with the
/// setting explicitly off.
extension VoiceUpdateCheckerTests {

    private typealias InstalledFiles = VoiceUpdateChecker.InstalledFiles

    /// Catalog entry whose voice also ships a split build (the
    /// same shape as the main test class's split fixture).
    private var streamingSplitCatalogJSON: Data {
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

    private func decodeStreamingSplitVoice() throws -> Voice {
        try JSONDecoder().decode(Voice.self, from: streamingSplitCatalogJSON)
    }

    /// Runs `body` with the Streaming voices preference set (or
    /// removed, for nil), restoring the previous value afterwards.
    private func withStreamingVoices(_ value: Bool?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let key = StreamingVoices.userDefaultsKey
        let saved = defaults.object(forKey: key)
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        body()
    }

    func testClassicInstallAgainstSplitEntryIsUpToDateWhenStreamingOff() throws {
        // Turning the setting off must not turn the entry's split
        // field into a phantom update for a classic install: the
        // install compares against the catalog's classic files,
        // which match.
        let voice = try decodeStreamingSplitVoice()
        let installed = InstalledFiles(modelSize: 1000, modelMD5: "aaaa", configMD5: "bbbb")
        withStreamingVoices(false) {
            XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .upToDate)
        }
    }

    func testClassicInstallAgainstSplitEntryStillSeesClassicUpdate() throws {
        // The classic comparison still runs with the setting off: a
        // retrained classic model is an update, split field or not.
        let voice = try decodeStreamingSplitVoice()
        let installed = InstalledFiles(modelSize: 1000, modelMD5: "dddd", configMD5: "bbbb")
        withStreamingVoices(false) {
            XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
        }
    }

    func testSplitsOnlyInstallComparesPerPartWhenStreamingOff() throws {
        // A splits-only install stays a streaming voice when the
        // setting is turned off afterwards: it keeps comparing
        // per-part instead of being flagged for a classic re-download
        // it could never match.
        let voice = try decodeStreamingSplitVoice()
        let installed = InstalledFiles(modelSize: 1000, modelMD5: nil, configMD5: "bbbb",
                                       isSplitsOnly: true,
                                       splitEncoderMD5: "eeee", splitDecoderMD5: "ffff",
                                       splitEncoderSize: 400, splitDecoderSize: 600)
        withStreamingVoices(false) {
            XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .upToDate)
        }
    }

    func testSplitsOnlyInstallWithStreamingOffStillSeesPartUpdate() throws {
        // Per-part comparison with the setting off still notices a
        // genuinely newer split build in the catalog.
        let voice = try decodeStreamingSplitVoice()
        let installed = InstalledFiles(modelSize: 1000, modelMD5: nil, configMD5: "bbbb",
                                       isSplitsOnly: true,
                                       splitEncoderMD5: "eeee", splitDecoderMD5: "dddd",
                                       splitEncoderSize: 400, splitDecoderSize: 600)
        withStreamingVoices(false) {
            XCTAssertEqual(VoiceUpdateChecker.status(voice: voice, installed: installed), .updateAvailable)
        }
    }
}
