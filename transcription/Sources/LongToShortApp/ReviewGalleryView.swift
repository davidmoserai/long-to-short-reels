import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LongToShortCore

struct ReviewGalleryView: View {
    let sourceURL: URL
    let highlights: [Highlight]
    let videoIndex: Int
    let videoCount: Int
    let onExport: ([Highlight]) -> Void
    let onSkip: () -> Void

    @State private var minimumScore = 70.0
    @State private var selectedIDs: Set<String>
    @State private var previewedHighlight: Highlight?
    @State private var player = AVPlayer()
    @State private var isExportingPreview = false
    @State private var previewExportError: String?

    init(
        sourceURL: URL,
        highlights: [Highlight],
        videoIndex: Int,
        videoCount: Int,
        onExport: @escaping ([Highlight]) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.sourceURL = sourceURL
        self.highlights = highlights
        self.videoIndex = videoIndex
        self.videoCount = videoCount
        self.onExport = onExport
        self.onSkip = onSkip

        let suggested = highlights
            .filter { $0.score >= 70 }
            .sorted { $0.score > $1.score }
            .prefix(15)
            .map(\.id)
        _selectedIDs = State(initialValue: Set(suggested))
    }

    private var visibleHighlights: [Highlight] {
        highlights
            .filter { Double($0.score) >= minimumScore }
            .sorted { $0.score > $1.score }
    }

    private var selectedHighlights: [Highlight] {
        visibleHighlights.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review candidates")
                    .font(.title2.bold())
                Text("Video \(videoIndex) of \(videoCount) · \(visibleHighlights.count) of \(highlights.count) shown")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Minimum AI highlight score")
                        Spacer()
                        Text("\(Int(minimumScore)) / 100")
                            .font(.body.monospacedDigit())
                    }
                    Slider(value: $minimumScore, in: 0...100, step: 1)
                }

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visibleHighlights, id: \.id) { highlight in
                            candidateRow(highlight)
                        }
                    }
                }
                .frame(minWidth: 390, maxWidth: 460)

                HStack {
                    Button("Skip This Video", action: onSkip)
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Export \(selectedHighlights.count) Selected") {
                        onExport(selectedHighlights)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedHighlights.isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Preview")
                    .font(.title2.bold())
                InlinePlayerView(player: player)
                    .frame(minWidth: 400, minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let highlight = previewedHighlight {
                    Text("\(timestamp(highlight.start)) – \(timestamp(highlight.end)) · \(Int(highlight.durationSeconds)) sec")
                        .font(.body.monospacedDigit())
                    Text("\(highlight.score) / 100 AI highlight score · \(highlight.momentType.rawValue)")
                        .foregroundStyle(.secondary)
                    Text(highlight.reasoning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let previewExportError {
                        Text(previewExportError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Choose a candidate")
                            .font(.headline)
                        Text("Select a candidate to preview that moment from the original video.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { expandWindowForReview() }
    }

    private func candidateRow(_ highlight: Highlight) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { selectedIDs.contains(highlight.id) },
                set: { isSelected in
                    if isSelected {
                        selectedIDs.insert(highlight.id)
                    } else {
                        selectedIDs.remove(highlight.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(highlight.score) / 100 · \(highlight.momentType.rawValue)")
                    .font(.headline.monospacedDigit())
                Text("\(timestamp(highlight.start)) – \(timestamp(highlight.end)) · \(Int(highlight.durationSeconds)) sec")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(highlight.reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            VStack(spacing: 6) {
                Button("Preview") { preview(highlight) }
                    .buttonStyle(.bordered)
                Button(isExportingPreview ? "Exporting…" : "Export…") {
                    exportPreview(highlight)
                }
                .buttonStyle(.bordered)
                .disabled(isExportingPreview)
            }
        }
        .padding(12)
        .background(previewedHighlight?.id == highlight.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func preview(_ highlight: Highlight) {
        let item = AVPlayerItem(url: sourceURL)
        item.forwardPlaybackEndTime = CMTime(seconds: highlight.end, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTime(seconds: highlight.start, preferredTimescale: 600))
        player.play()
        previewedHighlight = highlight
    }

    private func exportPreview(_ highlight: Highlight) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(highlight.id)_\(highlight.momentType.rawValue)_score\(highlight.score).mp4"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        isExportingPreview = true
        previewExportError = nil
        Task {
            do {
                try await ClipCutter.cutClip(source: sourceURL, start: highlight.start, end: highlight.end, output: outputURL)
                await MainActor.run {
                    isExportingPreview = false
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } catch {
                await MainActor.run {
                    isExportingPreview = false
                    previewExportError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func expandWindowForReview() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first else { return }
            let visibleFrame = window.screen?.visibleFrame ?? window.frame
            let width = min(1400, visibleFrame.width - 80)
            let height = min(900, visibleFrame.height - 80)
            guard window.frame.width < width || window.frame.height < height else { return }
            let frame = NSRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
            window.setFrame(frame, display: true, animate: true)
        }
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
