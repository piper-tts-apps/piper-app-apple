// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
@testable import PiperAppUtils
import Foundation

/// Functional check of the OpenJTalk dictionary install against the
/// REAL archive and the REAL shared group folder. Gated on an
/// environment variable so normal test runs skip it: the staged zip
/// must sit in the group container root under the given file name
/// (OPENJTALK_FUNCTIONAL_ZIP), because the sandboxed app process can
/// read its group container but not arbitrary paths.
final class OpenJTalkFunctionalTests: XCTestCase {

    func testRealArchiveInstallsIntoSharedFolder() throws {
        guard let zipName = ProcessInfo.processInfo.environment["OPENJTALK_FUNCTIONAL_ZIP"] else {
            throw XCTSkip("OPENJTALK_FUNCTIONAL_ZIP not set")
        }
        let folder = try XCTUnwrap(FileManager.Constants.openjtalkFolderURL,
                                   "shared group container unavailable in this process")
        let zipURL = folder.deletingLastPathComponent().appendingPathComponent(zipName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zipURL.path),
                      "staged archive missing at \(zipURL.path)")

        // The state the AudioUnit check reports before any install.
        XCTAssertFalse(FileManager.Constants.openjtalkFileExists(),
                       "precondition: shared dictionary must start uninstalled")

        // Production install entry point, default (shared) destination.
        try OpenJTalkDataManager.install(fromArchiveFile: zipURL)

        XCTAssertTrue(FileManager.Constants.openjtalkFileExists())
        XCTAssertTrue(OpenJTalkDataManager.isInstalled)

        // The real dictionary, not a fixture: sys.dic size is stable.
        let sysDic = folder.appendingPathComponent("sys.dic")
        let attributes = try FileManager.default.attributesOfItem(atPath: sysDic.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, 103_131_410)
        let matrix = folder.appendingPathComponent("matrix.bin")
        let matrixAttributes = try FileManager.default.attributesOfItem(atPath: matrix.path)
        XCTAssertEqual((matrixAttributes[.size] as? NSNumber)?.int64Value, 3_792_262)

        // The production no-op: VoiceLoader skips its dictionary download
        // whenever isInstalled is true, so repeating the production guard
        // must leave the installed files untouched.
        let modified = attributes[.modificationDate] as? Date
        if !OpenJTalkDataManager.isInstalled {
            try OpenJTalkDataManager.install(fromArchiveFile: zipURL)
        }
        let after = try FileManager.default.attributesOfItem(atPath: sysDic.path)
        XCTAssertEqual(modified, after[.modificationDate] as? Date)
    }

    /// Downloads the LIVE canonical archive from the Hugging Face repo,
    /// verifies its pinned SHA-256, and installs it into the shared
    /// folder - the same pieces the VoiceLoader production path runs
    /// (its session download + hash verification + install), exercised
    /// here against the real network source. Gated on
    /// OPENJTALK_FUNCTIONAL_LIVE=1 and a not-installed starting state.
    func testLiveArchiveDownloadsAndInstalls() async throws {
        guard ProcessInfo.processInfo.environment["OPENJTALK_FUNCTIONAL_LIVE"] == "1" else {
            throw XCTSkip("OPENJTALK_FUNCTIONAL_LIVE not set")
        }
        let folder = try XCTUnwrap(FileManager.Constants.openjtalkFolderURL,
                                   "shared group container unavailable in this process")
        XCTAssertFalse(FileManager.Constants.openjtalkFileExists(),
                       "precondition: shared dictionary must start uninstalled")

        let (downloaded, response) = try await URLSession.shared.download(
            from: OpenJTalkDataManager.dictionaryArchiveURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)

        let size = (try FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(size, 23_595_090)
        XCTAssertEqual(try OpenJTalkDataManager.sha256Hex(of: downloaded),
                       OpenJTalkDataManager.dictionaryArchiveSHA256)
        XCTAssertNoThrow(try OpenJTalkDataManager.verifyCanonicalArchive(at: downloaded))

        try OpenJTalkDataManager.install(fromArchiveFile: downloaded)

        XCTAssertTrue(FileManager.Constants.openjtalkFileExists())
        XCTAssertTrue(OpenJTalkDataManager.isInstalled)
        let sysDic = folder.appendingPathComponent("sys.dic")
        let sysDicSize = (try FileManager.default.attributesOfItem(atPath: sysDic.path)[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(sysDicSize, 103_131_410)
    }
}
