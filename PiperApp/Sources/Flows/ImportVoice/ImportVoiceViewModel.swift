// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils

struct ImportVoiceViewModel {
    var selectedModel: String {
        guard let selectedModelURL else {
            return ""
        }
        return selectedModelURL.lastPathComponent
    }
    var selectedJSON: String {
        guard let selectedJSONURL else {
            return ""
        }
        return selectedJSONURL.lastPathComponent
    }

    var selectedModelURL: URL?
    var selectedJSONURL: URL?
    // Optional split voice parts selected together with the model
    // (<name>.encoder.onnx / <name>.decoder.onnx); both or neither.
    var selectedEncoderURL: URL?
    var selectedDecoderURL: URL?
    var onDismiss: (() -> Void)?
    var error: Error?
    var showErrorMessage: Bool = false
}
