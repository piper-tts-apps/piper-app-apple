import Foundation

class Fastfile: LaneFile {

    private func supportedLanguages() -> [String] {
        if let rawLanguages = ProcessInfo.processInfo.environment["LANGUAGES"] {
            let tokens = rawLanguages.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            if !tokens.isEmpty {
                return tokens
            }
        }
        let fileManager = FileManager.default
        let metaPath = "fastlane/metadata"
        if let items = try? fileManager.contentsOfDirectory(atPath: metaPath) {
            return items.filter { name in
                var isDir: ObjCBool = false
                let full = (metaPath as NSString).appendingPathComponent(name)
                return fileManager.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
            }.sorted()
        }
        return ["en-US"]
    }

    func captureScreenshotsLane() {
        desc("Generate iOS screenshots using UI Tests – languages from LANGUAGES env filter, default fastlane/metadata (build once, test-without-building per lang)")
        sh(command: "rm -rf fastlane/test_output && mkdir -p fastlane/test_output")
        // Fix AX timeout on first language – snapshot warns 0s wait, we want 30s for AX to load
        setenv("SNAPSHOT_SIMULATOR_WAIT_FOR_BOOT_TIMEOUT", "30", 1)
        // Skip package resolution speedup – we already resolved
        setenv("FASTLANE_SNAPSHOT", "YES", 1)
        let languages = supportedLanguages()
        let derivedDataPath = "/tmp/snapshot_derived_ios"
        // Clean derived data once
        sh(command: "rm -rf \(derivedDataPath) && mkdir -p \(derivedDataPath)")
        // 1) Build once for testing – scan is wrapper around xcodebuild build-for-testing
        // Uses same workspace/scheme/devices as snapshot to populate DerivedData
        // Order for scan follows Scan::Options.available_options: workspace, scheme, device, derivedDataPath, buildForTesting etc
        scan(
            workspace: "./Piper.xcworkspace",
            scheme: "Screenshots",
            devices: .userDefined(["iPhone 17 Pro", "iPad Pro 13-inch (M5)"]),
            xcodebuildFormatter: "xcpretty",
            derivedDataPath: .userDefined(derivedDataPath),
            buildForTesting: .userDefined(true)
        )
        // 2) Run snapshot with testWithoutBuilding – avoids 13 rebuilds (was rebuilding each lang)
        // Order must match Snapshot::Options.available_options order:
        // languages -> outputDirectory -> clearPreviousScreenshots -> headless -> overrideStatusBar -> numberOfRetries -> concurrentSimulators -> xcodebuildFormatter -> derivedDataPath -> testWithoutBuilding
        captureScreenshots(
            languages: languages,
            outputDirectory: "fastlane/screenshots/ios",
            clearPreviousScreenshots: true,
            headless: true,
            overrideStatusBar: true,
            testWithoutBuilding: .userDefined(true),
            numberOfRetries: 3,
            derivedDataPath: .userDefined(derivedDataPath),
            concurrentSimulators: true,
            xcodebuildFormatter: "xcpretty"
        )
    }

    func updateReleaseNotesLane(withOptions options: [String: String]?) {
        desc("Update the 'What's New' text in App Store Connect using the metadata files. Pass `appVersion` as a parameter.")

        guard let appVersion = options?["appVersion"] else {
            fatalError("""
            Missing required parameter 'appVersion'.
            Usage: fastlane updateReleaseNotes appVersion:"1.2.3"
            """)
        }

        guard let appIdentifier = options?["appIdentifier"] else {
            fatalError("""
            Missing required parameter 'appIdentifier'.
            Usage: fastlane updateReleaseNotes appIdentifier:"com.app.id"
            """)
        }

        guard let keyContent = options?["apiKeyPath"] else {
            fatalError("""
            Missing required parameter 'apiKeyPath'.
            Usage: fastlane updateReleaseNotes apiKeyPath:"path/to/key.json"
            """)
        }

        let skipPreview = Bool(options?["skipPreview"] ?? "") ?? false
        let uploadScreenshots = Bool(options?["uploadScreenshots"] ?? "false") ?? false
        let platformOption = options?["platform"]?.lowercased() ?? "all"

        let platforms: [String]
        switch platformOption {
        case "ios":
            platforms = ["ios"]
        case "osx", "macos", "mac":
            platforms = ["osx"]
        default:
            platforms = ["ios", "osx"]
        }

        for platform in platforms {
            uploadToAppStore(
                apiKeyPath: .userDefined(keyContent),
                appIdentifier: .userDefined(appIdentifier),
                appVersion: .userDefined(appVersion),
                platform: platform,
                metadataPath: "./fastlane/metadata",
                skipBinaryUpload: true,
                skipScreenshots: .userDefined(!uploadScreenshots),
                skipMetadata: false,
                force: .userDefined(skipPreview),
                overwriteScreenshots: false,
                runPrecheckBeforeSubmit: false,
            )
        }
    }
}
