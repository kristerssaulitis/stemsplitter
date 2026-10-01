import Foundation
import Combine
import AVFoundation

// MARK: - ResultModel

/// The mixer screen: every stem on one timeline, mute/solo, quick presets,
/// pitch/speed, and exports that render exactly what you hear.
@MainActor
public final class ResultModel: ObservableObject {

    /// One-tap mixes. `custom` = anything the user dialed in by hand.
    public enum Preset: String, CaseIterable, Identifiable {
        case all, karaoke, acapella, noDrums, drumsOnly

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .all: "Full mix"
            case .karaoke: "Karaoke"
            case .acapella: "Acapella"
            case .noDrums: "No drums"
            case .drumsOnly: "Drums only"
            }
        }

        var muted: Set<String> {
            switch self {
            case .all, .acapella, .drumsOnly: []
            case .karaoke: ["vocals"]
            case .noDrums: ["drums"]
            }
        }

        var soloed: Set<String> {
            switch self {
            case .acapella: ["vocals"]
            case .drumsOnly: ["drums"]
            default: []
            }
        }
    }

    public enum ExportKind: Equatable {
        case mix, video, stems, stem(String)
    }

    @Published public private(set) var muted: Set<String> = []
    @Published public private(set) var soloed: Set<String> = []
    @Published public var pitch: Int = 0 { didSet { applyMix() } }
    @Published public var rate: Double = 1 { didSet { applyMix() } }
    @Published public private(set) var isPlaying = false
    @Published public private(set) var exporting: ExportKind?
    @Published public private(set) var exportProgress: Double = 0
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var exportToastVisible = false

    public let title: String
    public let sourceURL: URL
    public let outputs: SplitOutputs
    public let splitSeconds: TimeInterval
    @Published public private(set) var hasVideo = false

    /// The lanes: model stems in display order (instrumental is export-only).
    public let tracks: [StemTrack]
    public let duration: TimeInterval

    private let mixer: StemMixer?

    public static let displayOrder = ["vocals", "drums", "bass", "other"]

    public init(title: String, sourceURL: URL, outputs: SplitOutputs, splitSeconds: TimeInterval) {
        self.title = title
        self.sourceURL = sourceURL
        self.outputs = outputs
        self.splitSeconds = splitSeconds
        var lanes = outputs.stems.filter { $0.name != "instrumental" }
        if lanes.isEmpty {  // 2-stem engines
            lanes = [StemTrack(name: "vocals", url: outputs.vocalsURL, peaks: []),
                     StemTrack(name: "instrumental", url: outputs.instrumentalURL, peaks: [])]
        }
        lanes.sort { (Self.displayOrder.firstIndex(of: $0.name) ?? 99) < (Self.displayOrder.firstIndex(of: $1.name) ?? 99) }
        tracks = lanes
        do {
            let m = try StemMixer(tracks: lanes.map { ($0.name, $0.url) })
            mixer = m
            duration = m.duration
        } catch {
            mixer = nil
            duration = Double(lanes.first?.peaks.count ?? 0) / Double(StemTrack.peaksPerSecond)
            errorMessage = "Couldn't open the stems for playback."
        }
        Task {
            let tracks = try? await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .video)
            hasVideo = !(tracks ?? []).isEmpty
        }
    }

    // MARK: Transport

    public var position: TimeInterval { mixer?.position ?? 0 }

    public func togglePlay() {
        guard let mixer else { return }
        if mixer.isPlaying {
            mixer.pause()
        } else {
            mixer.play(from: mixer.position >= duration - 0.05 ? 0 : mixer.position)
        }
        isPlaying = mixer.isPlaying
    }

    public func seek(toFraction fraction: Double) {
        mixer?.seek(to: min(max(fraction, 0), 1) * duration)
    }

    public func skip(_ seconds: Double) {
        mixer?.seek(to: min(max(position + seconds, 0), duration))
    }

    /// Call from the UI's frame tick: parks the transport at the end of the song.
    public func tick() {
        guard let mixer, mixer.isPlaying, mixer.position >= duration - 0.01 else { return }
        mixer.pause()
        mixer.seek(to: 0)
        isPlaying = false
    }

    public func stop() {
        mixer?.pause()
        isPlaying = false
    }

    // MARK: Mix

    public func toggleMute(_ name: String) {
        if muted.contains(name) { muted.remove(name) } else { muted.insert(name) }
        applyMix()
    }

    public func toggleSolo(_ name: String) {
        if soloed.contains(name) { soloed.remove(name) } else { soloed.insert(name) }
        applyMix()
    }

    public func isAudible(_ name: String) -> Bool {
        Self.gain(name, muted: muted, soloed: soloed) > 0
    }

    public func apply(_ preset: Preset) {
        muted = preset.muted
        soloed = preset.soloed
        applyMix()
    }

    public var activePreset: Preset? {
        Preset.allCases.first { $0.muted == muted && $0.soloed == soloed }
    }

    public var isNeutral: Bool { muted.isEmpty && soloed.isEmpty && pitch == 0 && rate == 1 }

    public func resetPitchAndSpeed() {
        pitch = 0
        rate = 1
    }

    nonisolated static func gain(_ name: String, muted: Set<String>, soloed: Set<String>) -> Float {
        if !soloed.isEmpty { return soloed.contains(name) ? 1 : 0 }
        return muted.contains(name) ? 0 : 1
    }

    private var gains: [Float] { tracks.map { Self.gain($0.name, muted: muted, soloed: soloed) } }

    private func applyMix() {
        mixer?.apply(gains: gains, pitch: Double(pitch), rate: rate)
    }

    // MARK: Export

    /// Renders (if needed) and returns the files to hand to the share sheet.
    public func export(_ kind: ExportKind) async -> [URL] {
        guard exporting == nil else { return [] }
        exporting = kind
        exportProgress = 0
        defer { exporting = nil }
        do {
            switch kind {
            case .stems:
                return try await stemFiles(only: nil)
            case .stem(let name):
                return try await stemFiles(only: name)
            case .mix:
                return [try await renderMix(kind: .wav, name: "\(fileStem) - \(mixLabel).wav")]
            case .video:
                let audio = try await renderMix(kind: .m4a, name: "mix.m4a", progressScale: 0.8)
                let out = Self.exportDirectory.appendingPathComponent("\(fileStem) - \(mixLabel).mp4")
                try await StemMixer.replaceAudio(video: sourceURL, audio: audio, to: out)
                try? FileManager.default.removeItem(at: audio)
                exportProgress = 1
                return [out]
            }
        } catch is CancellationError {
            return []
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            return []
        }
    }

    public func exportFinished() { exportToastVisible = true }
    public func dismissExportToast() { exportToastVisible = false }
    public func dismissError() { errorMessage = nil }

    /// Named copies ("Song - vocals.wav") so shared files make sense outside the app.
    /// Hard links: instant, no extra space. Pitch/speed changes render each stem.
    private func stemFiles(only: String?) async throws -> [URL] {
        let all = outputs.stems.isEmpty
            ? [StemTrack(name: "vocals", url: outputs.vocalsURL, peaks: []),
               StemTrack(name: "instrumental", url: outputs.instrumentalURL, peaks: [])]
            : outputs.stems.filter { only == nil || $0.name == only }
        let neutralPitch = pitch == 0 && rate == 1
        var urls: [URL] = []
        for (i, stem) in all.enumerated() {
            let out = Self.exportDirectory.appendingPathComponent("\(fileStem) - \(stem.name).wav")
            if neutralPitch {
                try? FileManager.default.removeItem(at: out)
                do { try FileManager.default.linkItem(at: stem.url, to: out) } catch {
                    try FileManager.default.copyItem(at: stem.url, to: out)
                }
            } else {
                let tracks = [(stem.name, stem.url)]
                let p = Double(pitch), r = rate
                try await Task.detached(priority: .userInitiated) {
                    try StemMixer.render(tracks: tracks, gains: [1], pitch: p, rate: r, kind: .wav, to: out)
                }.value
            }
            exportProgress = Double(i + 1) / Double(all.count)
            urls.append(out)
        }
        return urls
    }

    private func renderMix(kind: StemMixer.FileKind, name: String, progressScale: Double = 1) async throws -> URL {
        let out = Self.exportDirectory.appendingPathComponent(name)
        let tracks = self.tracks.map { ($0.name, $0.url) }
        let gains = self.gains, p = Double(pitch), r = rate
        let progress = ProgressRelay { [weak self] f in self?.exportProgress = f * progressScale }
        try await Task.detached(priority: .userInitiated) {
            try StemMixer.render(tracks: tracks, gains: gains, pitch: p, rate: r, kind: kind, to: out,
                                 progress: { progress.send($0) })
        }.value
        return out
    }

    /// "Karaoke", "vocals + bass", "+2 st 90%"…
    var mixLabel: String {
        var parts: [String] = []
        if let preset = activePreset, preset != .all {
            parts.append(preset.title)
        } else if activePreset == nil {
            parts.append(tracks.filter { isAudible($0.name) }.map(\.name).joined(separator: " + "))
        }
        if pitch != 0 { parts.append(String(format: "%+d st", pitch)) }
        if rate != 1 { parts.append("\(Int((rate * 100).rounded()))%") }
        return parts.isEmpty ? "mix" : parts.joined(separator: " ")
    }

    private var fileStem: String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Split" : cleaned
    }

    static var exportDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Throttled hop from the render thread to the main actor for progress updates.
private final class ProgressRelay: @unchecked Sendable {
    private let handler: @MainActor (Double) -> Void
    private var last = -1.0

    init(_ handler: @escaping @MainActor (Double) -> Void) { self.handler = handler }

    func send(_ fraction: Double) {
        guard fraction - last >= 0.01 || fraction >= 1 else { return }
        last = fraction
        let handler = self.handler
        Task { @MainActor in handler(fraction) }
    }
}
