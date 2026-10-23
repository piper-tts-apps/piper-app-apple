// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import PiperAppUtils

struct ImportVoiceViewModel {
    var selectedModel: String {
        if let selectedModelURL {
            return selectedModelURL.lastPathComponent
        }
        // Splits-only selection (issue #94): there is no model file to
        // name, so the encoder part stands in for the voice in the
        // model slot - the row (and the Install button's enabled state,
        // which keys off this text) stays truthful without new strings.
        if let selectedEncoderURL {
            return selectedEncoderURL.lastPathComponent
        }
        return ""
    }
    var selectedJSON: String {
        guard let selectedJSONURL else {
            return ""
        }
        return selectedJSONURL.lastPathComponent
    }

    var selectedModelURL: URL?
    var selectedJSONURL: URL?
    // Split voice parts (<name>.encoder.onnx / <name>.decoder.onnx),
    // selected together with the model or, for a splits-only voice,
    // without one; both or neither.
    var selectedEncoderURL: URL?
    var selectedDecoderURL: URL?
    var onDismiss: (() -> Void)?
    var error: Error?
    var showErrorMessage: Bool = false
}
