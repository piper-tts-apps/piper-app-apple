// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import PiperAppUtils
import Foundation

/// The system registry check must use exactly the identifier the
/// provider registers, and must never claim a voice is visible when
/// the lookup says otherwise.
final class SystemVoiceVisibilityTests: XCTestCase {

    private var singleSpeakerInfo: ModelInfo {
        get throws {
            let json = """
            {
              "dataset":"en_US-lessac-high",
              "piper_version":"1.2.3",
              "language":{"code":"en_US","family":"en","region":"US"},
              "audio":{"sample_rate":22050,"quality":"high"},
              "num_speakers":1
            }
            """
            return try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        }
    }

    private var twoSpeakerInfo: ModelInfo {
        get throws {
            let json = """
            {
              "dataset":"en_US-lessac-high",
              "piper_version":"1.2.3",
              "language":{"code":"en_US","family":"en","region":"US"},
              "audio":{"sample_rate":22050,"quality":"high"},
              "speaker_id_map":{"0":0,"1":1},
              "num_speakers":2
            }
            """
            return try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        }
    }

    func testPiperVoiceIdForSingleSpeakerHasNoSuffix() throws {
        let info = try singleSpeakerInfo
        XCTAssertEqual(SystemVoiceVisibility.piperVoiceId(for: info, speakerId: 0), info.voiceId)
    }

    func testPiperVoiceIdForMultiSpeakerAppendsSpeakerId() throws {
        let info = try twoSpeakerInfo
        XCTAssertEqual(SystemVoiceVisibility.piperVoiceId(for: info, speakerId: 1),
                       "\(info.voiceId)\(Constants.speakerIdSeparator)1")
    }

    func testSystemIdentifierHasProviderPrefix() throws {
        let info = try singleSpeakerInfo
        XCTAssertEqual(SystemVoiceVisibility.systemIdentifier(for: info, speakerId: 0),
                       "dev.ihor-shevchuk.piperapp.pipertts.\(info.voiceId)")
    }

    func testIsVisibleWhenLookupFindsIdentifier() throws {
        let info = try singleSpeakerInfo
        XCTAssertTrue(SystemVoiceVisibility.isVisible(modelInfo: info, speakerId: 0, lookup: { _ in true }))
    }

    func testIsNotVisibleWhenLookupMissesIdentifier() throws {
        let info = try singleSpeakerInfo
        XCTAssertFalse(SystemVoiceVisibility.isVisible(modelInfo: info, speakerId: 0, lookup: { _ in false }))
    }

    func testIsVisibleProbesTheSystemIdentifier() throws {
        let info = try twoSpeakerInfo
        var probed: String?
        _ = SystemVoiceVisibility.isVisible(modelInfo: info, speakerId: 1, lookup: { probed = $0; return true })
        XCTAssertEqual(probed, "dev.ihor-shevchuk.piperapp.pipertts.\(info.voiceId)\(Constants.speakerIdSeparator)1")
    }
}
