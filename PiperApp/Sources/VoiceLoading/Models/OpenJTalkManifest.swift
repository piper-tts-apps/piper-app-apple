// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

/// Manifest published next to the OpenJTalk dictionary archive in its
/// Hugging Face repo (`openjtalk.json` in
/// `IhorShevchuk/openjtalk-dictionary`), fetched by `VoiceLoader` at
/// dictionary download time. The archive is installed only when its
/// size and SHA-256 match the manifest, so the dictionary can be
/// revised without an app update - the same fetched-not-pinned pattern
/// as the voice catalog's per-file digests. `archive` names the
/// archive file the size and hash belong to.
struct OpenJTalkManifest: Decodable {
    let archive: String
    let sha256: String
    let sizeBytes: Int
    let version: Int

    enum CodingKeys: String, CodingKey {
        case archive
        case sha256
        case sizeBytes = "size_bytes"
        case version
    }
}
