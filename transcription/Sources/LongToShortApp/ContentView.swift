import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LongToShortCore

private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]

enum ProcessingState: Equatable {
    case idle
    case processing(videoIndex: Int, videoCount: Int, currentFile: String, stage: String)
    case finished(clipCount: Int, outputFolders: [URL])
    case error(String)
}

struct ContentView: View {
    @EnvironmentObject private var apiKeyStatus: APIKeyStatus
    @State private var state: ProcessingState = .idle
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 24) {
            Text("Armin's Long to Short Converter")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            switch state {
            case .idle:
                dropZone
            case .processing(let videoIndex, let videoCount, let currentFile, let stage):
                processingView(videoIndex: videoIndex, videoCount: videoCount, currentFile: currentFile, stage: stage)
            case .finished(let clipCount, let outputFolders):
                finishedView(clipCount: clipCount, outputFolders: outputFolders)
            case .error(let message):
                errorView(message: message)
            }

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Idle / drop zone

    private var dropZone: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(height: 220)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Drop video(s) or a folder here")
                            .foregroundStyle(.secondary)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers)
                    return true
                }

            Button("Choose Videos or Folder…") {
                chooseFiles()
            }
            .buttonStyle(.borderedProminent)

            if !apiKeyStatus.hasKey {
                Label("Set your Anthropic API key in Settings before processing.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Processing

    private func processingView(videoIndex: Int, videoCount: Int, currentFile: String, stage: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Processing video \(videoIndex) of \(videoCount)")
                .font(.headline)
            Text(currentFile)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(stage)
                .font(.subheadline)
        }
    }

    // MARK: - Finished

    private func finishedView(clipCount: Int, outputFolders: [URL]) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Done — \(clipCount) clip\(clipCount == 1 ? "" : "s") ready")
                .font(.headline)

            ForEach(outputFolders, id: \.self) { folder in
                Button(folder.lastPathComponent) {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .buttonStyle(.link)
            }

            Button("Process More Videos") { state = .idle }
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again") { state = .idle }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: 400)
    }

    // MARK: - Input handling

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .folder]

        if panel.runModal() == .OK {
            processVideos(expand(panel.urls))
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var slots = [URL?](repeating: nil, count: providers.count)

        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                slots[i] = url
                group.leave()
            }
        }

        group.notify(queue: .main) {
            processVideos(expand(slots.compactMap { $0 }))
        }
    }

    /// Expands any dropped/selected folders into the video files they contain.
    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let fileURL as URL in enumerator
                    where videoExtensions.contains(fileURL.pathExtension.lowercased()) {
                        result.append(fileURL)
                    }
                }
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    private func processVideos(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let apiKey = KeychainStore.loadAPIKey() else {
            state = .error("No Anthropic API key set. Open Settings and add your key first.")
            return
        }

        Task {
            var outputFolders: [URL] = []
            var totalClips = 0

            for (index, url) in urls.enumerated() {
                state = .processing(
                    videoIndex: index + 1, videoCount: urls.count,
                    currentFile: url.lastPathComponent, stage: "Starting…")

                do {
                    let result = try await PipelineRunner.run(inputPath: url.path, apiKey: apiKey) { stage in
                        Task { @MainActor in
                            updateStage(stage, videoIndex: index + 1, videoCount: urls.count, filename: url.lastPathComponent)
                        }
                    }
                    outputFolders.append(result.outputDir)
                    totalClips += result.highlights.count
                } catch {
                    await MainActor.run {
                        state = .error("Failed on \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                    return
                }
            }

            await MainActor.run {
                state = .finished(clipCount: totalClips, outputFolders: outputFolders)
            }
        }
    }

    @MainActor
    private func updateStage(_ stage: PipelineRunner.Stage, videoIndex: Int, videoCount: Int, filename: String) {
        let text: String
        switch stage {
        case .transcribing(let status): text = "Transcribing — \(status)"
        case .scoring(let completed, let total): text = "Scoring highlights (\(completed)/\(total) windows)…"
        case .selecting: text = "Selecting best moments…"
        case .cutting(let completed, let total): text = "Cutting clips (\(completed)/\(total))…"
        case .done: text = "Done"
        case .failed(let message): text = "Failed: \(message)"
        }
        state = .processing(videoIndex: videoIndex, videoCount: videoCount, currentFile: filename, stage: text)
    }
}
