// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import UniformTypeIdentifiers

public enum Constants {
    public static let speakerIdSeparator = "<+>"
    public static let modelFileName = "model"
    public static let modelsFolderName = "models"
    public static let modelExtensiom = "onnx"
    public static let jsonModelExtension = "json"
    public static var modelFileNameWithExtension: String {
        return "\(modelFileName).\(modelExtensiom)"
    }
    public static var modelJSONFileNameWithExtension: String {
        return "\(modelFileNameWithExtension).\(jsonModelExtension)"
    }
    // Split voice parts for streaming (issue #94): libpiper derives these
    // names from the model file name (<stem>.encoder.onnx / .decoder.onnx).
    public static var modelEncoderFileNameWithExtension: String {
        return "\(modelFileName).encoder.\(modelExtensiom)"
    }
    public static var modelDecoderFileNameWithExtension: String {
        return "\(modelFileName).decoder.\(modelExtensiom)"
    }

    public static var modelsJSONFileName: String {
        return "\(modelsFolderName).\(jsonModelExtension)"
    }

    public static let jsonUTI: UTType = .json
    public static let modelUTI: UTType = .init(filenameExtension: modelExtensiom) ?? .item
}
