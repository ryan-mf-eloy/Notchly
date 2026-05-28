import Foundation
import AppKit
import SwiftUI

#if canImport(Translation)
@preconcurrency import Translation
#endif

#if canImport(_Translation_SwiftUI)
@preconcurrency import _Translation_SwiftUI
#endif

@main
final class TranslationLanguageDownloaderApp {
    private static var window: NSWindow?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prepare Apple Translation"
        window.center()
        window.contentView = NSHostingView(rootView: TranslationLanguageDownloaderView())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        app.run()
    }
}

#if canImport(Translation) && canImport(_Translation_SwiftUI)
@available(macOS 15.0, *)
@MainActor
final class TranslationLanguageDownloadModel: ObservableObject {
    struct Job: Identifiable {
        let id = UUID()
        let source: Locale.Language
        let target: Locale.Language
        let sample: String
        let label: String
    }

    @Published var configuration: TranslationSession.Configuration?
    @Published var currentJob: Job?
    @Published var status = "Preparing Apple Translation languages..."
    @Published var detail = "Keep this window open until both languages are ready."
    @Published var completed: [String] = []
    @Published var failed: [String] = []

    private var jobs = [
        Job(
            source: Locale.Language(identifier: "pt-BR"),
            target: Locale.Language(identifier: "en-US"),
            sample: "Olá, mundo. Isto é um teste de tradução.",
            label: "Portuguese -> English"
        ),
        Job(
            source: Locale.Language(identifier: "en-US"),
            target: Locale.Language(identifier: "pt-BR"),
            sample: "Hello world. This is a translation test.",
            label: "English -> Portuguese"
        )
    ]

    func start() {
        guard currentJob == nil, configuration == nil else { return }
        startNextJob()
    }

    func completeCurrentJob(with translatedText: String) {
        guard let currentJob else { return }
        completed.append("\(currentJob.label): \(translatedText)")
        self.currentJob = nil
        configuration = nil
        startNextJob()
    }

    func failCurrentJob(_ error: Error) {
        guard let currentJob else { return }
        failed.append("\(currentJob.label): \(error.localizedDescription)")
        self.currentJob = nil
        configuration = nil
        startNextJob()
    }

    private func startNextJob() {
        guard !jobs.isEmpty else {
            if failed.isEmpty {
                status = "Ready"
                detail = "Apple Translation accepted both language pairs."
            } else {
                status = "Needs attention"
                detail = "macOS did not finish one or more language downloads."
            }
            return
        }

        let job = jobs.removeFirst()
        currentJob = job
        status = "Preparing \(job.label)"
        detail = "If macOS shows a download prompt, let it finish before closing this window."
        configuration = TranslationSession.Configuration(source: job.source, target: job.target)
    }
}

@available(macOS 15.0, *)
struct TranslationLanguageDownloaderAvailableView: View {
    @StateObject private var model = TranslationLanguageDownloadModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: model.failed.isEmpty && !model.completed.isEmpty && model.currentJob == nil ? "checkmark.circle" : "arrow.down.circle")
                    .font(.system(size: 20, weight: .medium))
                Text(model.status)
                    .font(.system(size: 18, weight: .semibold))
            }

            Text(model.detail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.completed, id: \.self) { item in
                    Label(item, systemImage: "checkmark")
                        .foregroundStyle(.primary)
                }
                ForEach(model.failed, id: \.self) { item in
                    Label(item, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if model.currentJob != nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.system(size: 12, weight: .medium))

            Spacer()
        }
        .padding(24)
        .translationTask(model.configuration) { session in
            guard let job = model.currentJob else { return }
            do {
                try await session.prepareTranslation()
                let response = try await session.translate(job.sample)
                model.completeCurrentJob(with: response.targetText)
            } catch {
                model.failCurrentJob(error)
            }
        }
        .onAppear {
            model.start()
        }
    }
}
#endif

struct TranslationLanguageDownloaderView: View {
    var body: some View {
        #if canImport(Translation) && canImport(_Translation_SwiftUI)
        if #available(macOS 15.0, *) {
            TranslationLanguageDownloaderAvailableView()
        } else {
            Text("Apple Translation requires macOS 15 or newer.")
                .padding()
        }
        #else
        Text("Apple Translation framework is unavailable in this SDK.")
            .padding()
        #endif
    }
}
