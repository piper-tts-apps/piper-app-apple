// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import PiperAppUtils
import Foundation
import AVFoundation

/// Sample playback must not depend on the system voice registry:
/// the voice detail screen's preview renders the installed model
/// locally, so a voice the system has not (re-)registered for
/// VoiceOver still plays its sample.
/// - playbackRoute: a voice the registry does not list routes to
///   local synthesis; a listed voice routes to the system voice.
/// - playSampleLocally: an installed but unregistered ("invisible")
///   voice still attempts local playback; a voice whose files are
///   not on disk is skipped. The guard is the files on disk, not
///   the installed-models list (which lives in the app-group
///   container the test host cannot see).
final class PiperManagerPlaybackTests: XCTestCase {

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

    private func makeEdonPaths(withModelFile: Bool = true) throws -> FileManager.ModelPaths {
        let json = """
        {
          "dataset":"edon",
          "piper_version":"1.2.3",
          "language":{"code":"sq_AL","family":"sq","region":"AL"},
          "audio":{"sample_rate":22050,"quality":"medium"},
          "num_speakers":1
        }
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonURL = dir.appendingPathComponent("sq_AL-edon-medium.onnx.json")
        try Data(json.utf8).write(to: jsonURL)
        let modelURL = dir.appendingPathComponent("sq_AL-edon-medium.onnx")
        if withModelFile {
            FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        }
        guard let paths = FileManager.ModelPaths(model: modelURL, json: jsonURL) else {
            XCTFail("ModelPaths must build from the Edon fixture")
            throw NSError(domain: "PiperManagerPlaybackTests", code: 1)
        }
        XCTAssertNotNil(paths.info)
        return paths
    }

    func testInvisibleVoiceRoutesToLocalSynthesis() throws {
        let info = try edonInfo
        let manager = PiperManager()
        let route = manager.playbackRoute(for: info, speakerId: 0, lookup: { _ in nil })
        guard case .localSynthesis = route else {
            XCTFail("a voice the registry does not list must route to local synthesis")
            return
        }
    }

    func testVisibleVoiceRoutesToSystemVoice() throws {
        guard let systemVoice = AVSpeechSynthesisVoice.speechVoices().first else {
            XCTFail("the simulator must list at least one system voice")
            return
        }
        let info = try edonInfo
        let manager = PiperManager()
        let route = manager.playbackRoute(for: info, speakerId: 0, lookup: { _ in systemVoice })
        guard case .systemVoice(let voice) = route else {
            XCTFail("a voice the registry lists must route to the system voice")
            return
        }
        XCTAssertTrue(voice === systemVoice)
    }

    func testPlaySampleLocallyAttemptsLocalPlaybackForInvisibleVoice() async throws {
        let paths = try makeEdonPaths()
        guard let info = paths.info else {
            XCTFail("Edon fixture must decode")
            return
        }
        XCTAssertTrue(paths.exist, "fixture files must be on disk")
        // Edon is not in the simulator's system registry: the lookup
        // returns nil, i.e. the voice is "invisible" here.
        XCTAssertNil(AVSpeechSynthesisVoice(identifier: SystemVoiceVisibility.systemIdentifier(for: info, speakerId: 0)))
        let manager = PiperManager()
        let attempted = await manager.playSampleLocally(demoText: "Hello", speakerId: 0, paths: paths)
        XCTAssertTrue(attempted, "an installed but unregistered voice must still attempt local playback")
    }

    func testPlaySampleLocallySkipsVoiceWithoutFilesOnDisk() async throws {
        // Fixture JSON exists (so info decodes) but no model file and
        // no split parts: the voice's files are not on disk.
        let paths = try makeEdonPaths(withModelFile: false)
        XCTAssertNotNil(paths.info)
        XCTAssertFalse(paths.exist, "fixture must have no model file on disk")
        let manager = PiperManager()
        let attempted = await manager.playSampleLocally(demoText: "Hello", speakerId: 0, paths: paths)
        XCTAssertFalse(attempted, "a voice without files on disk must not attempt playback")
    }
}
