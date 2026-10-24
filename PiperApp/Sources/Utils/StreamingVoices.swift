// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation

/// Whether new downloads use a voice's split (streaming) build when
/// the catalog offers one, chosen in Settings and persisted in
/// UserDefaults. Unlike `ModelFormat`, the preference defaults to
/// ON: an absent key means enabled, so no migration is needed and
/// only an explicit opt-out is ever stored. Downloads read
/// `isEnabled` when they start; installed voices keep the layout
/// they came with, voices imported from files are not affected,
/// and update detection always compares the layout actually
/// installed, never this setting.
enum StreamingVoices {
    static let userDefaultsKey = "streaming_voices"

    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
}
