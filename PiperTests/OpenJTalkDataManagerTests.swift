// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
import ZIPFoundation
@testable import Piper
@testable import PiperAppUtils
import Foundation

final class OpenJTalkDataManagerTests: XCTestCase {

    private var tempDir: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openjtalk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        destination = tempDir.appendingPathComponent("shared", isDirectory: true)
            .appendingPathComponent(FileManager.Constants.openjtalkFolderName, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture

    /// Builds a tiny fixture archive with the required dictionary file
    /// names (contents are dummies - install logic does not parse them),
    /// laid out at the zip root exactly like the real openjtalk.zip.
    private func makeFixtureArchive(missing: String? = nil,
                                    marker: String = "fixture") throws -> URL {
        let source = tempDir.appendingPathComponent("fixture-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for file in FileManager.Constants.openjtalkRequiredFiles where file != missing {
            try "\(marker)-\(file)".write(to: source.appendingPathComponent(file),
                                          atomically: true, encoding: .utf8)
        }
        try "license".write(to: source.appendingPathComponent("COPYING"),
                            atomically: true, encoding: .utf8)
        let archive = tempDir.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        // Contents at the zip root, not nested under the source folder.
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)
        return archive
    }

    private func installedMarker(at folder: URL) throws -> String {
        let url = folder.appendingPathComponent("sys.dic")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Tests

    func testInstallsWhenMissing() throws {
        XCTAssertFalse(OpenJTalkDataManager.isInstalled(in: destination))
        let archive = try makeFixtureArchive()
        try OpenJTalkDataManager.install(fromArchiveFile: archive, to: destination)
        XCTAssertTrue(OpenJTalkDataManager.isInstalled(in: destination))
        XCTAssertEqual(try installedMarker(at: destination), "fixture-sys.dic")
    }

    /// The no-op-when-installed decision lives in the CALLER (VoiceLoader
    /// checks `OpenJTalkDataManager.isInstalled` before downloading), so
    /// the manager-level contract is that `isInstalled(in:)` reflects the
    /// folder state exactly: missing, partial, and complete.
    func testIsInstalledReflectsFolderState() throws {
        XCTAssertFalse(OpenJTalkDataManager.isInstalled(in: destination))
        XCTAssertFalse(OpenJTalkDataManager.isInstalled(in: nil))

        // Partial: only one of the required files present.
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "partial".write(to: destination.appendingPathComponent("sys.dic"),
                            atomically: true, encoding: .utf8)
        XCTAssertFalse(OpenJTalkDataManager.isInstalled(in: destination))

        let archive = try makeFixtureArchive()
        try OpenJTalkDataManager.install(fromArchiveFile: archive, to: destination)
        XCTAssertTrue(OpenJTalkDataManager.isInstalled(in: destination))
    }

    /// install() itself always installs (it is not the no-op gate);
    /// installing over an existing folder replaces its contents, which
    /// is what makes a retry after a corrupt install safe.
    func testInstallOverExistingReplacesContents() throws {
        let sentinel = try makeFixtureArchive(marker: "sentinel")
        try OpenJTalkDataManager.install(fromArchiveFile: sentinel, to: destination)
        XCTAssertEqual(try installedMarker(at: destination), "sentinel-sys.dic")

        let other = try makeFixtureArchive(marker: "other")
        try OpenJTalkDataManager.install(fromArchiveFile: other, to: destination)
        XCTAssertEqual(try installedMarker(at: destination), "other-sys.dic")
    }

    func testFailureLeavesNoPartialFolder() throws {
        let bogus = tempDir.appendingPathComponent("bogus.zip")
        try "this is not a zip archive".write(to: bogus, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OpenJTalkDataManager.install(fromArchiveFile: bogus, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        assertNoLeftovers()
    }

    func testMissingArchiveFileLeavesNoPartialFolder() throws {
        let absent = tempDir.appendingPathComponent("absent.zip")
        XCTAssertThrowsError(try OpenJTalkDataManager.install(fromArchiveFile: absent, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        assertNoLeftovers()
    }

    func testArchiveMissingRequiredFileIsRejected() throws {
        let archive = try makeFixtureArchive(missing: "unk.dic")
        do {
            try OpenJTalkDataManager.install(fromArchiveFile: archive, to: destination)
            XCTFail("install must reject an archive without all required files")
        } catch let error as OpenJTalkDataManager.Error {
            guard case .invalidArchive(let missing) = error else {
                XCTFail("expected invalidArchive, got \(error)")
                return
            }
            XCTAssertEqual(missing, ["unk.dic"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        assertNoLeftovers()
    }

    func testSHA256HexKnownVector() throws {
        let file = tempDir.appendingPathComponent("abc.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        // Published SHA-256 test vector for "abc".
        XCTAssertEqual(try OpenJTalkDataManager.sha256Hex(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testVerifyCanonicalArchiveRejectsNonCanonicalFile() async throws {
        let archive = try makeFixtureArchive()
        XCTAssertThrowsError(try OpenJTalkDataManager.verifyCanonicalArchive(at: archive)) { error in
            guard let managerError = error as? OpenJTalkDataManager.Error,
                  case .archiveHashMismatch = managerError else {
                XCTFail("expected archiveHashMismatch, got \(error)")
                return
            }
        }
    }

    private func assertNoLeftovers() {
        let parent = destination.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        XCTAssertTrue(siblings.filter { $0.hasPrefix("openjtalk-tmp-") }.isEmpty,
                      "staging siblings left behind: \(siblings)")
    }
}

/// Shared-folder constants for the OpenJTalk dictionary (PiperAppUtils).
final class OpenJTalkConstantsTests: XCTestCase {

    func testFolderIdentity() {
        XCTAssertEqual(FileManager.Constants.openjtalkFolderName, "openjtalk")
        XCTAssertEqual(FileManager.Constants.openjtalkFolderURL?.lastPathComponent,
                       FileManager.Constants.openjtalkFolderName)
    }

    func testRequiredFiles() {
        XCTAssertEqual(FileManager.Constants.openjtalkRequiredFiles,
                       ["sys.dic", "matrix.bin", "char.bin", "unk.dic"])
    }

    /// The AudioUnit resolves the dictionary through this check, so it must
    /// reflect reality. Gated: only asserts when the functional run sets the
    /// expectation, because the shared folder is machine state.
    func testSharedFolderStateWhenExpected() throws {
        guard let expected = ProcessInfo.processInfo.environment["OPENJTALK_EXPECT_INSTALLED"] else {
            throw XCTSkip("OPENJTALK_EXPECT_INSTALLED not set")
        }
        XCTAssertEqual(FileManager.Constants.openjtalkFileExists(), expected == "1")
        XCTAssertEqual(OpenJTalkDataManager.isInstalled, expected == "1")
    }
}
