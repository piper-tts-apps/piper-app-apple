// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import PiperAppUtils
import Foundation

/// "Check again" must show its spinner on EVERY tap, not just the
/// first: refreshSystemVoices() sets isRefreshingSystemVoices=true
/// before the 1 s re-probe delay and clears it after. A second tap
/// while the section is still shown must raise the flag again.
/// (Device report 2026-11-07: the spinner appeared on the first tap
/// only; later taps showed no activity indicator. The flag itself
/// flipped correctly on every tap, so the defect was in how the view
/// observed it: the flag lived inside the @Published view-model
/// struct and the button was swapped for the spinner. The flag now
/// lives on the host model and the button stays mounted with the
/// spinner beside it.)
final class VoiceHostModelRefreshTests: XCTestCase {

    private func makeHostModel() throws -> VoiceHostModel {
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
        guard let paths = FileManager.ModelPaths(model: modelURL, json: jsonURL) else {
            XCTFail("ModelPaths must build from the Edon fixture")
            throw NSError(domain: "VoiceHostModelRefreshTests", code: 1)
        }
        XCTAssertNotNil(paths.info)
        return VoiceHostModel(piper: PiperManager(), modelPaths: paths, delegate: nil)
    }

    func testRefreshShowsSpinnerOnEveryTap() async throws {
        let host = try makeHostModel()
        XCTAssertFalse(host.isRefreshingSystemVoices)
        // First tap.
        host.refreshSystemVoices()
        XCTAssertTrue(host.isRefreshingSystemVoices, "first tap must show the spinner")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(host.isRefreshingSystemVoices, "spinner must clear after the re-probe")
        // Second tap: the spinner must come back.
        host.refreshSystemVoices()
        XCTAssertTrue(host.isRefreshingSystemVoices, "second tap must show the spinner again")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(host.isRefreshingSystemVoices, "spinner must clear after the second re-probe")
        // Third tap, same expectation.
        host.refreshSystemVoices()
        XCTAssertTrue(host.isRefreshingSystemVoices, "third tap must show the spinner again")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(host.isRefreshingSystemVoices)
    }

    func testDoubleTapWhileRefreshingDoesNotWedgeTheSpinner() async throws {
        let host = try makeHostModel()
        host.refreshSystemVoices()
        XCTAssertTrue(host.isRefreshingSystemVoices)
        // A second tap while the re-scan is already in flight is
        // ignored: it must not restart or clear the wait.
        host.refreshSystemVoices()
        XCTAssertTrue(host.isRefreshingSystemVoices, "second tap during a refresh must not clear the spinner")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(host.isRefreshingSystemVoices, "spinner must clear after the re-probe")
    }
}
