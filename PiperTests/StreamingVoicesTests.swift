// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import Foundation

final class StreamingVoicesTests: XCTestCase {

    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: StreamingVoices.userDefaultsKey)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: StreamingVoices.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: StreamingVoices.userDefaultsKey)
        }
        super.tearDown()
    }

    private func setStreaming(_ value: Bool?) {
        if let value {
            UserDefaults.standard.set(value, forKey: StreamingVoices.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: StreamingVoices.userDefaultsKey)
        }
    }

    // MARK: - Store

    func testEnabledByDefaultWhenKeyAbsent() {
        // Default ON with no stored value: fresh installs stream
        // without any migration ever writing the key.
        setStreaming(nil)
        XCTAssertTrue(StreamingVoices.isEnabled)
    }

    func testExplicitOffPersists() {
        setStreaming(false)
        XCTAssertFalse(StreamingVoices.isEnabled)
    }

    func testExplicitOnPersists() {
        setStreaming(true)
        XCTAssertTrue(StreamingVoices.isEnabled)
    }

    // MARK: - Download layout decision

    /// Catalog entry with a split build (the future catalog shape):
    /// `files` carries the full model (31951473) and the config
    /// (4875); the split parts are 15000000 + 16956298.
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

    /// The same entry without a split build.
    private var classicJSON: Data {
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
          }
        }
        """.data(using: .utf8)!
    }

    func testSplitSelectedWhenStreamingOn() throws {
        setStreaming(true)
        let voice = try JSONDecoder().decode(Voice.self, from: splitJSON)
        XCTAssertNotNil(voice.selectedSplit)
        // Displayed size follows the layout: pair plus config.
        XCTAssertEqual(voice.voiceSize, 15000000 + 16956298 + 4875)
    }

    func testSplitSelectedByDefault() throws {
        // The absent-key default (ON) selects the split layout too.
        setStreaming(nil)
        let voice = try JSONDecoder().decode(Voice.self, from: splitJSON)
        XCTAssertNotNil(voice.selectedSplit)
    }

    func testSplitNotSelectedWhenStreamingOff() throws {
        setStreaming(false)
        let voice = try JSONDecoder().decode(Voice.self, from: splitJSON)
        XCTAssertNil(voice.selectedSplit)
        // Displayed size falls back to the classic files total.
        XCTAssertEqual(voice.voiceSize, 31951473 + 4875)
    }

    func testNoSplitEntryStaysClassicWhenStreamingOn() throws {
        setStreaming(true)
        let voice = try JSONDecoder().decode(Voice.self, from: classicJSON)
        XCTAssertNil(voice.selectedSplit)
        XCTAssertEqual(voice.voiceSize, 31951473 + 4875)
    }

    func testNoSplitEntryStaysClassicWhenStreamingOff() throws {
        setStreaming(false)
        let voice = try JSONDecoder().decode(Voice.self, from: classicJSON)
        XCTAssertNil(voice.selectedSplit)
        XCTAssertEqual(voice.voiceSize, 31951473 + 4875)
    }
}
