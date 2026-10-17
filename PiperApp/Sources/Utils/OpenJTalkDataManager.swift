// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import CryptoKit
import Foundation
import PiperAppUtils
import ZIPFoundation

/// Installs the OpenJTalk dictionary that Japanese voices need for
/// phonemization (libpiper has no bundled Japanese G2P data).
/// Mirrors `G2PWDataManager`'s shape, but the dictionary is ~107 MB
/// unpacked, so it cannot be embedded in the app like the Chinese files:
/// `VoiceLoader` downloads it once, as part of the first Japanese voice
/// download, and this manager installs it into the SHARED group folder
/// (`FileManager.Constants.openjtalkFolderURL`), where one copy serves
/// every Japanese voice (and survives voice uninstalls). Downloading is
/// deliberately NOT done here: the single production transport is
/// `VoiceLoader`'s session-scoped download, which gives the dictionary
/// fetch the voice download's progress band and cancellation.
public enum OpenJTalkDataManager {
    public enum Error: Swift.Error {
        case noOpenJTalkFolder
        case invalidArchive(missing: [String])
        case verificationFailed
        case archiveHashMismatch
    }

    /// The dictionary archive lives in its own Hugging Face repo, separate
    /// from the voice catalog repo: `openjtalk.zip` there holds the
    /// dictionary files at the zip root (sys.dic, matrix.bin, ...).
    public static let dictionaryArchiveURL = URL(string: "https://huggingface.co/IhorShevchuk/openjtalk-dictionary/resolve/main/openjtalk.zip")!

    /// SHA-256 of the canonical `openjtalk.zip` in that repo (23,595,090
    /// bytes, uploaded 2026-10-10). Archives fetched from the canonical
    /// URL are verified against this before anything is installed, so a
    /// corrupted or swapped upload cannot reach the shared folder.
    public static let dictionaryArchiveSHA256 = "06039fe6f628cb7d946284d81aaca911380f90d880f81c768f0c7d06be557322"

    public static var folderURL: URL? {
        FileManager.Constants.openjtalkFolderURL
    }

    public static var isInstalled: Bool {
        FileManager.Constants.openjtalkFileExists()
    }

    public static func isInstalled(in folder: URL?) -> Bool {
        guard let folder else { return false }
        let fileManager = FileManager.default
        return FileManager.Constants.openjtalkRequiredFiles.allSatisfy {
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Verifies a downloaded archive against the pinned canonical hash.
    public static func verifyCanonicalArchive(at file: URL) throws {
        guard try sha256Hex(of: file) == dictionaryArchiveSHA256 else {
            throw Error.archiveHashMismatch
        }
    }

    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Installs the dictionary from an already-downloaded archive file:
    /// unzips into a staging directory, verifies the required files, and
    /// only then moves the result into place, so a failed or interrupted
    /// install never leaves a partial shared folder behind.
    public static func install(fromArchiveFile archiveFile: URL,
                               to folder: URL? = nil) throws {
        guard let destination = folder ?? folderURL else {
            throw Error.noOpenJTalkFolder
        }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("openjtalk-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: archiveFile, to: staging)

        let missing = FileManager.Constants.openjtalkRequiredFiles.filter {
            !fileManager.fileExists(atPath: staging.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw Error.invalidArchive(missing: missing)
        }
        markAsUnprotectedRecursively(at: staging)

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent,
                                        withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.none])
        let sibling = parent.appendingPathComponent("openjtalk-tmp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: sibling) }
        try fileManager.moveItem(at: staging, to: sibling)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: sibling, to: destination)

        guard isInstalled(in: destination) else {
            throw Error.verificationFailed
        }
    }

    private static func markAsUnprotectedRecursively(at folder: URL) {
        let fileManager = FileManager.default
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.none],
                                       ofItemAtPath: folder.path)
        guard let enumerator = fileManager.enumerator(at: folder,
                                                      includingPropertiesForKeys: nil) else {
            return
        }
        for case let fileURL as URL in enumerator {
            try? fileManager.setAttributes([.protectionKey: FileProtectionType.none],
                                           ofItemAtPath: fileURL.path)
        }
    }
}
