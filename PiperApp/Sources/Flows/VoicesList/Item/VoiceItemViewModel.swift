// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils

struct VoiceItemViewModel {
    let voice: Voice
    /// A newer catalog build of this installed voice exists.
    var updateAvailable: Bool = false
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0
    var isSampleLoading: Bool = false
    var isPlaying: Bool = false
    /// False when the system registry does not list this installed
    /// voice: VoiceOver cannot use it. True until probed.
    var isSystemVoiceVisible: Bool = true
}
