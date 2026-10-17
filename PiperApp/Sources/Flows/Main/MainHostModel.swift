// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import Foundation
import Combine
import PiperAppUtils

class MainHostModel: @unchecked Sendable, ObservableObject {
    @Published var viewModel: MainViewModel
    let piper: PiperManager
    let loader: VoiceLoader
    var languages: [String: [Voice]] = [:]
    /// The last catalog loaded, kept so update checks can re-run
    /// when the installed set changes without refetching it.
    private var catalogVoices: [Voice] = []
    private var defaultsObserver: NSObjectProtocol?

    init(piper: PiperManager,
         loader: VoiceLoader = AppManager.shared.loader) {
        self.piper = piper
        self.loader = loader
        viewModel = Self.makeViewModel(installed: piper.installedVoices)
        // Voice sizes follow the Model format setting; refresh the
        // list when it changes in Settings.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
        connect()
        loadVoices()
    }

    /// Model configs do not always use the catalog's language code:
    /// community configs ship codes like "en-gb-x-rp" where the catalog
    /// says "en_GB". Reduce a code to family + region so installed
    /// voices group under the same key the catalog uses.
    static func canonicalLanguageCode(_ code: String) -> String {
        let components = code.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard let family = components.first?.lowercased() else {
            return code
        }
        guard components.count > 1 else {
            return family
        }
        return "\(family)_\(components[1].uppercased())"
    }

    private static func makeViewModel(installed: [FileManager.ModelPaths]) -> MainViewModel {
        let sorted = installed.sorted(by: { model1, model2 in
            return model1.modelTitle < model2.modelTitle
        })
        var byLanguage: [String: [FileManager.ModelPaths]] = [:]
        var ungrouped: [FileManager.ModelPaths] = []
        for model in sorted {
            if let code = model.info?.language.code {
                byLanguage[canonicalLanguageCode(code), default: []].append(model)
            } else {
                ungrouped.append(model)
            }
        }
        let groups = byLanguage
            .map { MainViewModel.InstalledLanguage(code: $0.key, models: $0.value) }
            .sorted(by: { group1, group2 in
                return group1.code.localizedLanguageFromCode < group2.code.localizedLanguageFromCode
            })
        return MainViewModel(installedModels: sorted,
                             installedByLanguage: groups,
                             ungroupedInstalled: ungrouped)
    }

    func loadVoices() {
        Task {
            do {
                let voices = try await self.loader.loadVoices()
                self.catalogVoices = voices
                self.loader.checkForUpdates(voices: voices, installed: self.piper.installedVoices)
                self.languages = Dictionary(grouping: voices) { voice in
                    Self.canonicalLanguageCode(voice.language.code)
                }
                let codes = self.languages.keys
                    .sorted(by: { lang1, lang2 in
                        return lang1.localizedLanguageFromCode < lang2.localizedLanguageFromCode
                    })
                await MainActor.run {
                    self.updateCatalog(codes: codes, state: .loaded)
                }
            } catch {
                Log.error("Failed to load voices: \(error)")
                await MainActor.run {
                    self.updateCatalog(codes: [], state: .failed)
                }
            }
        }
    }

    private func updateCatalog(codes: [String], state: MainViewModel.CatalogState) {
        var updated = viewModel
        updated.languageCodes = codes
        updated.catalogState = state
        viewModel = updated
    }

    func voices(for languageCode: String) -> [Voice] {
        return languages[languageCode]?
            .filter { voice in
                return voice.isSupported
            }
            .sorted(by: { voice1, voice2 in
                return voice1.name < voice2.name
            }) ?? []
    }

    /// Maps an installed language group to the catalog key its voices
    /// list lives under: the canonical code when the catalog has it,
    /// else the catalog's only language with the same family (a config
    /// that ships just "uk" still finds "uk_UA").
    func resolvedLanguageCode(for code: String) -> String {
        let canonical = Self.canonicalLanguageCode(code)
        if languages[canonical] != nil {
            return canonical
        }
        let family = canonical.split(separator: "_").first.map(String.init) ?? canonical
        let matches = languages.keys.filter { key in
            return key.split(separator: "_").first.map(String.init) == family
        }
        return matches.count == 1 ? matches[0] : canonical
    }

    func installedPaths(for voice: Voice) -> FileManager.ModelPaths? {
        VoiceItemHostModel.installedPaths(for: voice, in: piper.installedVoices)
    }

    func searchResults(for query: String) -> [Voice] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let foldedQuery = query.folding(options: options, locale: .current)
        guard !foldedQuery.isEmpty else {
            return []
        }
        return languages.values.flatMap { $0 }
            .filter { voice in
                return voice.isSupported
            }
            .filter { voice in
                if voice.name.folding(options: options, locale: .current).contains(foldedQuery) {
                    return true
                }
                let language = voice.language
                let candidates = [language.code,
                                  language.family,
                                  language.country,
                                  language.language,
                                  language.nameEnglish,
                                  language.nameNative,
                                  language.countryEnglish,
                                  language.code.localizedLanguageFromCode].compactMap { $0 }
                return candidates.contains { candidate in
                    return candidate.folding(options: options, locale: .current).contains(foldedQuery)
                }
            }
            .sorted(by: { voice1, voice2 in
                let language1 = voice1.language.code.localizedLanguageFromCode
                let language2 = voice2.language.code.localizedLanguageFromCode
                if language1 != language2 {
                    return language1 < language2
                }
                return voice1.name < voice2.name
            })
    }

    func connect() {
        Task {
#if DEBUG
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                Log.error("Error happened during waiting: \(error)")
            }
#endif
            await self.piper.audioUnit.connect()
        }
    }

    func selected(files: [URL]) {
        if files.count != 2 {
            Log.error("Wrong number of files selected: \(files.count)")
            return
        }

        let model = files.model
        let modelJSON = files.json

        guard let paths = FileManager.ModelPaths(model: model, json: modelJSON) else {
            Log.error("Failed to find model or model JSON file")
            return
        }

        Task { [weak self] in
            defer {
                paths.model.stopAccessingSecurityScopedResource()
                paths.json.stopAccessingSecurityScopedResource()
            }

            if paths.model.startAccessingSecurityScopedResource() != true {
                Log.error("Failed to access model")
                return
            }

            if paths.json.startAccessingSecurityScopedResource() != true {
                Log.error("Failed to access JSON")
                return
            }

            if (try? ModelInfo.create(from: paths.json)) == nil {
                Log.error("Failed to create ModelInfo from modelJSON")
                return
            }

            guard let self else {
                return
            }

            await self.piper.install(paths: paths)
            self.modelDidChange()
        }
    }
}

extension MainHostModel: ModelChangeDelegate {
    func modelDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var updated = Self.makeViewModel(installed: self.piper.installedVoices)
            updated.languageCodes = self.viewModel.languageCodes
            updated.catalogState = self.viewModel.catalogState
            self.viewModel = updated
            // An install or uninstall (an update is both) changes
            // which installed voices are stale.
            self.loader.checkForUpdates(voices: self.catalogVoices,
                                        installed: self.piper.installedVoices)
        }
    }
}
