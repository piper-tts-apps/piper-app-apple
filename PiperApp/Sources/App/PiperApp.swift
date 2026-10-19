// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Ihor Shevchuk

import SwiftUI

@main
struct PiperApp: App {

#if os(iOS)
    @UIApplicationDelegateAdaptor private var appDelegate: ApplicationDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: ApplicationDelegate
#endif

    @ViewBuilder
    var mainContent: some View {
        MainView(hostModel: mainModel)
    }

    let mainModel = MainHostModel(piper: AppManager.shared.piper)

#if os(macOS)
    /// True when the app was launched by the screenshot UI tests
    /// (`setupSnapshot` passes `-FASTLANE_SNAPSHOT YES`).
    private var isScreenshotMode: Bool {
        ProcessInfo.processInfo.arguments.contains("-FASTLANE_SNAPSHOT")
    }
#endif

    var body: some Scene {
        #if os(macOS)
        Window("piper_app_name".localized, id: "main") {
            if isScreenshotMode {
                mainContent
                    .frame(minWidth: 650, minHeight: 600)
                    .frame(idealWidth: 650, idealHeight: 600)
                    .frame(maxWidth: 1000, maxHeight: 800)
                    .background(ScreenshotWindowPlacer())
            } else {
                mainContent
                    .frame(minWidth: 650, minHeight: 600)
                    .frame(idealWidth: 650, idealHeight: 600)
                    .frame(maxWidth: 1000, maxHeight: 800)
            }
        }
        .defaultSize(width: 650, height: 600)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        #elseif os(iOS)
        WindowGroup {
            mainContent
        }
        #endif
    }
}

#if os(macOS)
/// Screenshot runs capture the whole desktop, so the window itself has to sit
/// at a deterministic size and position: pinned to the app's maximum content
/// size (1000x800) and centered on the main screen. Normal launches never
/// install this view and keep the user's own window frame.
private struct ScreenshotWindowPlacer: NSViewRepresentable {
    fileprivate static let contentSize = NSSize(width: 1000, height: 800)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var timer: Timer?

        func attach(from view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                if self.window !== window {
                    self.window = window
                    window.isRestorable = false
                    window.contentMinSize = ScreenshotWindowPlacer.contentSize
                    window.contentMaxSize = ScreenshotWindowPlacer.contentSize
                    self.startTimer()
                }
                self.place(window)
            }
        }

        func detach() {
            timer?.invalidate()
            timer = nil
        }

        private func startTimer() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.place(window)
            }
        }

        private func place(_ window: NSWindow) {
            let contentRect = NSRect(origin: .zero, size: ScreenshotWindowPlacer.contentSize)
            let frameSize = window.frameRect(forContentRect: contentRect).size
            guard let screen = window.screen ?? NSScreen.main else { return }
            let screenFrame = screen.frame
            let origin = NSPoint(
                x: screenFrame.midX - frameSize.width / 2,
                y: screenFrame.midY - frameSize.height / 2
            )
            let target = NSRect(origin: origin, size: frameSize)
            if window.frame != target {
                window.setFrame(target, display: true)
            }
        }
    }
}
#endif
