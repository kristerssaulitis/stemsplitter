import Foundation
import StemCore

// Day-1 benchmark spike — stub (plan T1/TE2).
// The real harness pins the shipping configuration: stereo dual-pass, 96-128 kbps
// AAC corpus, resample + overlap-add included, ANE residency via os_signpost
// (eng E3). It lands with the engine components; this stub only proves the
// package wiring (Spike → StemCore) and that the frozen contracts are usable
// from an executable.

print("StemSplitter spike — scaffold stub (real Day-1 harness lands with the engine)")

// Contract smoke: walk the frozen event surface.
let events: [PipelineEvent] = [
    .phase(.downloading),
    .phase(.decoding),
    .phase(.splitting),
    .eta(ETAEstimate(seconds: 90, isInitial: true)),
    .progress(fraction: 0.0),
    .peaks(StereoPeaks(left: 0.31, right: 0.27)),
    .progress(fraction: 0.5),
    .eta(ETAEstimate(seconds: 71, isInitial: false)),
    .progress(fraction: 1.0),
    .completed(
        SplitOutputs(
            vocalsURL: URL(fileURLWithPath: "/tmp/Caches/Splits/00000000-0000-0000-0000-000000000000/vocals.wav"),
            instrumentalURL: URL(fileURLWithPath: "/tmp/Caches/Splits/00000000-0000-0000-0000-000000000000/instrumental.wav")
        )
    ),
]
for event in events {
    print(event)
}

// Error surface smoke: approved user copy rides on StemError.
for error: StemError in [.noAudio, .corruptAsset, .diskFull, .cancelled] {
    print("\(error) -> \(error.userMessage ?? "<no copy — bespoke UI>")")
}
