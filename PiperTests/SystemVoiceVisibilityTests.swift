// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import PiperAppUtils
import Foundation

/// The system registry check must use exactly the identifier the
/// provider registers, and must never claim a voice is visible when
/// the lookup says otherwise.
///
/// Ground truth (macOS registry, 2026-11-07, Piper voices installed):
///   dev.ihor-shevchuk.piper.pipertts.cori>0<high>0<22050.0>0<en_GB>0<1
///   dev.ihor-shevchuk.piper.pipertts.thorsten>0<high>0<22050.0>0<de_DE>0<1
///   dev.ihor-shevchuk.piper.pipertts.news_tts>0<medium>0<22050.0>0<id_ID>0<1
/// i.e. the system prefixes the provider voice id with the speech
/// extension's bundle id (dev.ihor-shevchuk.piper.pipertts), which is
/// the app bundle id (dev.ihor-shevchuk.piper) + ".pipertts" — NOT
/// "dev.ihor-shevchuk.piperapp.pipertts". Edon (sq_AL, medium, 22050,
/// single speaker) is registered the same way on Ihor's iPhone and
/// listed under piper in the VoiceOver voices list, so the helper
/// must construct
///   dev.ihor-shevchuk.piper.pipertts.edon>0<medium>0<22050.0>0<sq_AL>0<1
/// for it.
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

    /// Edon as installed on Ihor's iPhone: Albanian, sq_AL, medium,
    /// 22050 Hz, single speaker, 31.1 MB (catalog sq_AL-edon-medium).
    private var edonInfo: ModelInfo {
        get throws {
            let json = """
            {
              "dataset":"edon",
              "piper_version":"1.2.3",
              "language":{"code":"sq_AL","family":"sq","region":"AL"},
              "audio":{"sample_rate":22050,"quality":"medium"},
              "num_speakers":1
            }
            """
            return try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        }
    }

    /// Cori high as registered on a real device/Mac: the exact
    /// identifier the system registry lists it under.
    private var coriHighInfo: ModelInfo {
        get throws {
            let json = """
            {
              "dataset":"cori",
              "piper_version":"1.2.3",
              "language":{"code":"en_GB","family":"en","region":"GB"},
              "audio":{"sample_rate":22050,"quality":"high"},
              "num_speakers":1
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
                       "dev.ihor-shevchuk.piper.pipertts.\(info.voiceId)")
    }

    func testSystemIdentifierForEdonMatchesRealRegistryIdentifier() throws {
        let info = try edonInfo
        XCTAssertEqual(SystemVoiceVisibility.systemIdentifier(for: info, speakerId: 0),
                       "dev.ihor-shevchuk.piper.pipertts.edon>0<medium>0<22050.0>0<sq_AL>0<1")
    }

    func testSystemIdentifierForCoriMatchesRealRegistryIdentifier() throws {
        let info = try coriHighInfo
        XCTAssertEqual(SystemVoiceVisibility.systemIdentifier(for: info, speakerId: 0),
                       "dev.ihor-shevchuk.piper.pipertts.cori>0<high>0<22050.0>0<en_GB>0<1")
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
        XCTAssertEqual(probed, "dev.ihor-shevchuk.piper.pipertts.\(info.voiceId)\(Constants.speakerIdSeparator)1")
    }

    func testIsVisibleProbesTheRealEdonIdentifier() throws {
        let info = try edonInfo
        var probed: String?
        _ = SystemVoiceVisibility.isVisible(modelInfo: info, speakerId: 0, lookup: { probed = $0; return true })
        XCTAssertEqual(probed, "dev.ihor-shevchuk.piper.pipertts.edon>0<medium>0<22050.0>0<sq_AL>0<1")
    }
}
