// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import XCTest
@testable import Piper
import PiperAppUtils
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class DemoTextTests: XCTestCase {

    private let samples: [String: String] = [
        "de": "German sample",
        "en_GB": "English sample",
        "es_ES": "Spanish sample",
        "ja_JA": "Japanese sample",
        "pt_BR": "Brazilian Portuguese sample",
        "pt_PT": "European Portuguese sample"
    ]

    private func language(code: String, family: String, region: String) -> Language {
        Language(code: code, family: family, region: region)
    }

    func testExactCodeWins() {
        let lang = language(code: "pt_PT", family: "pt", region: "PT")
        XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), "European Portuguese sample")
    }

    func testBareFamilyKey() {
        let lang = language(code: "de_DE", family: "de", region: "DE")
        XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), "German sample")
    }

    /// Regression: Spanish voices from Mexico and Argentina fell back
    /// to the English default because `Samples` only carries `es_ES`
    /// and there is no bare `es` key.
    func testRegionalFallbackSpanishMexico() {
        let lang = language(code: "es_MX", family: "es", region: "MX")
        XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), "Spanish sample")
    }

    func testRegionalFallbackSpanishArgentina() {
        let lang = language(code: "es_AR", family: "es", region: "AR")
        XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), "Spanish sample")
    }

    func testRegionalFallbackEnglishUS() {
        let lang = language(code: "en_US", family: "en", region: "US")
        XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), "English sample")
    }

    /// A future `ja_JP` catalog code must keep resolving to the sample
    /// stored under the historical `ja_JA` key.
    func testRegionalFallbackJapaneseRename() {
        let lang = language(code: "ja_JP", family: "ja", region: "JP")
        XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), "Japanese sample")
    }

    func testRegionalFallbackIsDeterministic() {
        let lang = language(code: "pt_AO", family: "pt", region: "AO")
        XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), "Brazilian Portuguese sample")
    }

    func testNoSampleForLanguageReturnsNil() {
        let lang = language(code: "xx_XX", family: "xx", region: "XX")
        XCTAssertNil(DemoText.sampleText(in: samples, for: lang))
    }

    /// The bundled `Samples` asset itself: the languages added in
    /// Nov 2026 (including Indonesian, and the corrected Malayalam
    /// text that used to carry the Indonesian sentence) must resolve
    /// to their own sample, never the English default, and Malayalam
    /// must no longer equal the Indonesian sample.
    func testBundledNewSamplesResolve() throws {
        let dataAsset = NSDataAsset(name: "Samples")
        try XCTSkipUnless(dataAsset != nil, "Samples asset not available in this test host")
        let samples = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(dataAsset?.data))
        for code in ["bn_BD", "et_EE", "eu_ES", "he_IL", "hy_AM", "id_ID",
                     "ko_KR", "ku_TR", "lt_LT", "ml_IN", "mr_IN", "sq_AL", "th_TH", "tl_PH"] {
            let parts = code.split(separator: "_")
            let lang = language(code: code, family: String(parts[0]), region: String(parts[1]))
            XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), samples[code])
        }
        XCTAssertNotEqual(samples["ml_IN"], samples["id_ID"])
        XCTAssertTrue(samples["ml_IN"]?.contains("മഴവില്ല്") ?? false)
        XCTAssertTrue(samples["tl_PH"]?.contains("bahaghari") ?? false)
        XCTAssertTrue(samples["lt_LT"]?.contains("Vaivorykštė") ?? false)
    }

    /// The bundled `Samples` asset itself: every Spanish voice in the
    /// catalog must resolve to the Spanish text, never the default.
    func testBundledSpanishSamplesResolve() throws {
        let dataAsset = NSDataAsset(name: "Samples")
        try XCTSkipUnless(dataAsset != nil, "Samples asset not available in this test host")
        let samples = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(dataAsset?.data))
        for code in ["es_ES", "es_MX", "es_AR"] {
            let region = String(code.suffix(2))
            let lang = language(code: code, family: "es", region: region)
            XCTAssertEqual(DemoText.sampleText(in: samples, for: lang), samples["es_ES"])
        }
    }
}
