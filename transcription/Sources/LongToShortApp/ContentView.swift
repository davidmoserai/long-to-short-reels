import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LongToShortCore

private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]

enum ProcessingState {
    case idle
    case processing(videoIndex: Int, videoCount: Int, currentFile: String, stage: String, progress: Double)
    case reviewing(videoIndex: Int, videoCount: Int, sourceURL: URL, highlights: [Highlight], urls: [URL], outputFolders: [URL], totalClips: Int)
    case finished(clipCount: Int, outputFolders: [URL])
    case error(String)
}

struct ContentView: View {
    @EnvironmentObject private var apiKeyStatus: APIKeyStatus
    @State private var state: ProcessingState = .idle
    @State private var isTargeted = false
    @State private var latestErrorReport = ""
    @State private var batchAPIKey = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("Armin's Long to Short Converter")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            switch state {
            case .idle:
                dropZone
            case .processing(let videoIndex, let videoCount, let currentFile, let stage, let progress):
                processingView(videoIndex: videoIndex, videoCount: videoCount, currentFile: currentFile, stage: stage, progress: progress)
            case .reviewing(let videoIndex, let videoCount, let sourceURL, let highlights, let urls, let outputFolders, let totalClips):
                ReviewGalleryView(
                    sourceURL: sourceURL,
                    highlights: highlights,
                    videoIndex: videoIndex,
                    videoCount: videoCount,
                    onExport: { selected in
                        exportSelection(
                            selected,
                            sourceURL: sourceURL,
                            videoIndex: videoIndex,
                            urls: urls,
                            outputFolders: outputFolders,
                            totalClips: totalClips
                        )
                    },
                    onSkip: {
                        advanceBatch(
                            after: videoIndex,
                            urls: urls,
                            outputFolders: outputFolders,
                            totalClips: totalClips
                        )
                    }
                )
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

        }
    }

    // MARK: - Processing

    private func processingView(videoIndex: Int, videoCount: Int, currentFile: String, stage: String, progress: Double) -> some View {
        VStack(spacing: 16) {
            Text("Processing video \(videoIndex) of \(videoCount)")
                .font(.headline)
            Text(currentFile)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 400)
            Text("\(Int((progress * 100).rounded()))% complete")
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
            Text(stage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

            if !outputFolders.isEmpty {
                Button("Reveal All Exported Clips in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(outputFolders)
                }
                .buttonStyle(.borderedProminent)

                ForEach(outputFolders, id: \.self) { folder in
                    Button("Reveal \(folder.lastPathComponent)") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(.link)
                }
            }

            Button("Process More Videos") { state = .idle }
                .buttonStyle(.bordered)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("A report was saved locally. It never includes your Anthropic API key.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Email Error Report") {
                ErrorReporter.email(report: latestErrorReport)
            }
            .buttonStyle(.borderedProminent)
            .disabled(latestErrorReport.isEmpty)
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
            apiKeyStatus.refresh()
            return
        }
        batchAPIKey = apiKey
        prepareVideo(at: 0, urls: urls, outputFolders: [], totalClips: 0)
    }

    private func prepareVideo(at index: Int, urls: [URL], outputFolders: [URL], totalClips: Int) {
        let url = urls[index]
        Task {
            state = .processing(
                videoIndex: index + 1, videoCount: urls.count,
                currentFile: url.lastPathComponent, stage: "Step 1 of 3 — Preparing…",
                progress: Double(index) / Double(urls.count)
            )

            do {
                let result = try await PipelineRunner.prepare(inputPath: url.path, apiKey: batchAPIKey) { stage in
                    Task { @MainActor in
                        updateStage(stage, videoIndex: index + 1, videoCount: urls.count, filename: url.lastPathComponent)
                    }
                }
                await MainActor.run {
                    state = .reviewing(
                        videoIndex: index + 1,
                        videoCount: urls.count,
                        sourceURL: result.sourceURL,
                        highlights: result.highlights,
                        urls: urls,
                        outputFolders: outputFolders,
                        totalClips: totalClips
                    )
                }
            } catch {
                showError(error, for: url)
            }
        }
    }

    private func exportSelection(
        _ highlights: [Highlight],
        sourceURL: URL,
        videoIndex: Int,
        urls: [URL],
        outputFolders: [URL],
        totalClips: Int
    ) {
        Task {
            do {
                let outputFolder = try await PipelineRunner.export(highlights, sourceURL: sourceURL) { stage in
                    Task { @MainActor in
                        updateStage(stage, videoIndex: videoIndex, videoCount: urls.count, filename: sourceURL.lastPathComponent)
                    }
                }
                await MainActor.run {
                    advanceBatch(
                        after: videoIndex,
                        urls: urls,
                        outputFolders: outputFolders + [outputFolder],
                        totalClips: totalClips + highlights.count
                    )
                }
            } catch {
                showError(error, for: sourceURL)
            }
        }
    }

    private func advanceBatch(after videoIndex: Int, urls: [URL], outputFolders: [URL], totalClips: Int) {
        if videoIndex < urls.count {
            prepareVideo(at: videoIndex, urls: urls, outputFolders: outputFolders, totalClips: totalClips)
        } else {
            state = .finished(clipCount: totalClips, outputFolders: outputFolders)
        }
    }

    private func showError(_ error: Error, for url: URL) {
        let report = ErrorReporter.record(error: error, inputFile: url.lastPathComponent)
        Task { @MainActor in
            latestErrorReport = report
            state = .error("Failed on \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func updateStage(_ stage: PipelineRunner.Stage, videoIndex: Int, videoCount: Int, filename: String) {
        let text: String
        let videoProgress: Double
        switch stage {
        case .transcribing(let status):
            text = "Step 1 of 3 — Transcribing: \(status)"
            videoProgress = transcriptionProgress(for: status)
        case .scoring(let completed, let total):
            text = "Step 2 of 3 — Scoring highlights (\(completed) of \(total) windows)"
            videoProgress = 0.45 + 0.40 * Double(completed) / Double(max(total, 1))
        case .selecting:
            text = "Step 3 of 3 — Preparing candidates for review"
            videoProgress = 0.88
        case .cutting(let completed, let total):
            text = "Exporting selected clips (\(completed) of \(total))"
            videoProgress = 0.90 + 0.10 * Double(completed) / Double(max(total, 1))
        case .done:
            text = "Done"
            videoProgress = 1
        case .failed(let message):
            text = "Failed: \(message)"
            videoProgress = 0
        }
        let progress = (Double(videoIndex - 1) + videoProgress) / Double(videoCount)
        state = .processing(videoIndex: videoIndex, videoCount: videoCount, currentFile: filename, stage: text, progress: progress)
    }

    private func transcriptionProgress(for status: String) -> Double {
        if status.hasPrefix("Diarizing") { return 0.35 }
        if status.hasPrefix("Loading diarization") { return 0.30 }
        if status.hasPrefix("Transcribing") { return 0.08 }
        return 0.02
    }
}
