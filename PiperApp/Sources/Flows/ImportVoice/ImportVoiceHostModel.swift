// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import Combine
import PiperAppUtils

class ImportVoiceHostModel: @unchecked Sendable, ObservableObject {
    @Published var viewModel: ImportVoiceViewModel
    weak var delegate: ModelChangeDelegate?
    let piper: PiperManager

    init(piper: PiperManager,
         delegate: ModelChangeDelegate?) {
        self.piper = piper
        viewModel = ImportVoiceViewModel()
        self.delegate = delegate
    }

    func select(model: URL?) {
        guard let model else {
            Log.error("Failed to find model file")
            viewModel.selectedModelURL = nil
            return
        }
        if !model.startAccessingSecurityScopedResource() {
            Log.error("Failed to access model file")
            viewModel.selectedModelURL = nil
            return
        }
        defer {
            model.stopAccessingSecurityScopedResource()
            modelDidChange()
        }

        if FileManager.default.fileExists(atPath: model.path) {
            viewModel.selectedModelURL = model
        }
    }

    func select(files urls: [URL]) {
        // Both import buttons open the same unified picker, so a single
        // selection can carry the whole voice: the model, its config json
        // and, for a split voice, its encoder/decoder parts. ModelPaths
        // classifies the selection; the parts that are present go through
        // the same per-part selection paths the separate pickers used.
        let imported = FileManager.ModelPaths.importedModelFiles(among: urls)
        if imported.model != nil {
            select(model: imported.model)
            // Split parts belong to the model they were classified
            // against: (re)selecting a model replaces the parts of any
            // previous selection, clearing them when it brings none.
            viewModel.selectedEncoderURL = imported.encoder
            viewModel.selectedDecoderURL = imported.decoder
        }
        if imported.json != nil {
            select(json: imported.json)
        }
    }

    func select(json: URL?) {
        guard let json else {
            Log.error("Failed to find json file")
            viewModel.selectedJSONURL = nil
            return
        }
        if !json.startAccessingSecurityScopedResource() {
            Log.error("Failed to access json file")
            viewModel.selectedJSONURL = nil
            return
        }
        defer {
            json.stopAccessingSecurityScopedResource()
            modelDidChange()
        }

        if !FileManager.default.fileExists(atPath: json.path) {
            viewModel.selectedJSONURL = nil
           return
        }

        do {
           _ = try ModelInfo.create(from: json)
        } catch {
            Log.error("Invalid JSON file: \(error)")
            viewModel.error = error
            viewModel.selectedJSONURL = nil
            viewModel.showErrorMessage = true
            return
        }

        viewModel.selectedJSONURL = json
    }

    func install() {
        guard let paths = FileManager.ModelPaths(model: viewModel.selectedModelURL,
                                                 json: viewModel.selectedJSONURL) else {
            Log.error("Failed to find model or model JSON file")
            return
        }

        let selectedEncoder = viewModel.selectedEncoderURL
        let selectedDecoder = viewModel.selectedDecoderURL

        Task { [weak self] in
            defer {
                paths.model.stopAccessingSecurityScopedResource()
                paths.json.stopAccessingSecurityScopedResource()
                selectedEncoder?.stopAccessingSecurityScopedResource()
                selectedDecoder?.stopAccessingSecurityScopedResource()
            }

            if paths.model.startAccessingSecurityScopedResource() != true {
                Log.error("Failed to access model")
                return
            }

            if paths.json.startAccessingSecurityScopedResource() != true {
                Log.error("Failed to access JSON")
                return
            }

            // Split parts are optional: pass them on only when both were
            // selected with the model and can actually be read.
            var splitEncoder: URL?
            var splitDecoder: URL?
            if let selectedEncoder, let selectedDecoder,
               selectedEncoder.startAccessingSecurityScopedResource(),
               selectedDecoder.startAccessingSecurityScopedResource(),
               FileManager.default.fileExists(atPath: selectedEncoder.path),
               FileManager.default.fileExists(atPath: selectedDecoder.path) {
                splitEncoder = selectedEncoder
                splitDecoder = selectedDecoder
            }

            if (try? ModelInfo.create(from: paths.json)) == nil {
                Log.error("Failed to create ModelInfo from modelJSON")
                return
            }

            guard let self else {
                return
            }

            await self.piper.install(paths: paths,
                                     encoder: splitEncoder,
                                     decoder: splitDecoder)
            self.delegate?.modelDidChange()
            await MainActor.run { [weak self] in
                self?.viewModel.onDismiss?()
            }
        }
    }

    func modelDidChange() {
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
            }
        }
    }
}

extension Error {
    var humanReadableError: String {
        if let error = self as? ModelInfo.Error {
            switch error {
            case .nilFileURL:
                return "json_error_invalid_model_file_path".localized
            case .invalidSpeakerId:
                return "json_error_invalid_speaker_id".localized
            }
        }

        guard let decodingError = self as? DecodingError else {
            return localizedDescription
        }

        switch decodingError {
        case .keyNotFound(let key, let context):
            return String(localized: "json_error_missing_field_\(String(describing: key.stringValue))_at_\(String(describing: context.codingPath.map { $0.stringValue }.joined(separator: ".")))")
        case .typeMismatch(let type, let context):
            return String(localized: "json_error_type_mismatch_\(String(describing: type))_at_\(String(describing: context.codingPath.map { $0.stringValue }.joined(separator: ".")))")
        case .valueNotFound(let type, let context):
            return String(localized: "json_error_value_not_found_\(String(describing: type))_at_\(String(describing: context.codingPath.map { $0.stringValue }.joined(separator: ".")))")
        case .dataCorrupted(let context):
            return String(localized: "json_error_data_corrupted_\(String(describing: context.debugDescription))")
        @unknown default:
            break
        }
        return "An unknown decoding error occurred."
    }
}
