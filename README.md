# StemSplitter

Video-native, on-device stem splitter for iOS: pick a gallery video (MP4/MOV), split it
into vocals + instrumental, play both stems, export WAV 44.1 kHz/24-bit via the share
sheet. One flow — no account, no upload, nothing leaves your phone.

- Approved plan: `~/.gstack/projects/kristers/stemsplitter-no-branch-design-20261001.md`
- Test plan (QA governance): `~/.gstack/projects/kristers/kristers-no-branch-eng-review-test-plan-20261001-063500.md`
- Release/distribution: [`Release/APP_STORE.md`](Release/APP_STORE.md)
- Privacy policy page (App Store URL source): [`Release/privacy.html`](Release/privacy.html)

## Requirements

- Xcode (with iOS 17+ simulator; the repo assumes Xcode 16+)
- iOS 17 minimum deployment target
- Gate/benchmark device per the 2026-10-01 plan addendum: **iPhone 17 (A19)** — the
  simulator has no Neural Engine, so the performance bar is verified on device only
- Personal Apple Developer Program membership for TestFlight/App Store (plan T11)

## Setup

Open the project in Xcode:

```
open StemSplitter.xcodeproj
```

Select the **StemSplitter** scheme and run on a simulator or device. No third-party
package dependencies exist, so no resolution step is needed.

## CLI builds

`xcode-select` on this machine points at CommandLineTools, so plain `xcodebuild`/`swift`
fail without a developer dir. The exact commands that work here (verified):

```sh
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Build the app itself from the command line (no simulator device needed — the generic
destination is correct; `CODE_SIGNING_ALLOWED=NO` because no signing is configured until
TestFlight setup lands, plan T11):

```sh
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project StemSplitter.xcodeproj -scheme StemSplitter \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/dd \
  -quiet build CODE_SIGNING_ALLOWED=NO
```

## Architecture map

One-screen single-flow UI (picker → processing → result) on a model-agnostic streaming
engine (plan Approach B, Stem Engine):

```
StemSplitter.app
 UI LAYER (SwiftUI, Sources/StemUI)        ENGINE LAYER (Sources/StemCore)
 AppFlowView ──state──> ProcessingView     AudioExtractor (AVFoundation)
     │                    │                ├─ AVAssetReader audio-only decode
     │                    v                ├─ AVAudioConverter → 44.1 kHz
 PhotosPicker       ResultView            └─ no-audio / iCloud / offline errors
 (out-of-process,   ├─ source selector
  no library perms) ├─ stem cards +       StemEngine (actor, StemEngineProtocol)
                    │  long-press share    ├─ Chunker (size + overlap)
                    └─ ShareLink WAV       ├─ STFT/ISTFT (vDSP) + overlap-add
                                           ├─ MDXSeparator (CoreML, ANE)
 SUPPORT (Sources/StemCore/Support)        ├─ complement: instrumental := source − vocals
 SplitStore     Caches/Splits/<uuid>/,     └─ WAVWriter (24-bit streaming, RF64 > 4 GB)
                purged on next launch
 ETACalibrator  persisted per-device,     PipelineEvent (Contracts/) — the ONE event
                keyed by model ID         surface engine → SwiftUI (progress, peaks,
 ModelStore     bundled .mlmodelc,        ETA, failure); exactly one terminal event.
                preloaded at launch       BenchmarkHarness — timings, memory profile,
                                          wall-clock linearity (plan T1/TE2 spike).
```

Status against the plan's task list (T1–T11, TE1–TE7): the frozen contracts
(`PipelineEvent`, `StemError`, `StemEngineProtocol`), the `StemUI` design tokens, the app
target, and the test target exist; engine/support/UI-flow components land in their homes
per the plan. `Contracts/` is FROZEN — implement against it, never edit it.

Key invariants (plan Review Sections 1–2, obligations):

- Streaming pipeline, no whole-file float buffers; peak < 400 MB on a 15-minute split.
- Instrumental is derived by complement subtraction so stems sum to the source exactly.
- Output WAV 44.1 kHz/24-bit; mono sources upmix dual-mono; other sample rates pass an
  explicit resample stage.
- Cancel discards partial output; interrupted splits land on a user-confirmed
  "Start again"; split WAVs live only in caches and are purged on next launch — share /
  Save to Files is the only persistence path.

## Dropping in the real CoreML model

The separation model ships as a pre-converted, bundled CoreML model (plan: "ModelStore
(bundled .mlmodelc)"). To install the real one:

1. **Pick weights (license first).** v1 uses a 2-stem MDX-class model; the Day-1 spike
   (plan T1/TE2) selects it. Non-commercial weights are rejected up front — the license
   must allow commercial App Store distribution before anything else happens.
2. **Convert to CoreML.** One-time macOS step with `coremltools`: load the ONNX/PyTorch
   weights, export a 2-stem CoreML program with the model's training-contract STFT
   window/hop and chunk shapes baked in. Keep the model ID + version string stable —
   ETA calibration is keyed by it.
3. **Compile.**
   ```sh
   xcrun coremlcompiler compile <Model>.mlmodel App/
   ```
   This produces `App/<Model>.mlmodelc`.
4. **Add it to the app target.** Drag the `.mlmodelc` into `App/` and add it to the
   StemSplitter target's resources in `StemSplitter.xcodeproj` (Copy Bundle Resources).
5. **Load via ModelStore.** `Sources/StemCore/Support/ModelStore.swift` loads the bundled
   compiled model at launch (async preload — the OS compiled-model cache removes
   first-split compile latency) and surfaces `ModelLoadError` as the "couldn't start —
   reinstall" alert if the resource is missing or corrupt. Compute-unit placement targets
   the Neural Engine; a transparent CPU fallback only costs speed.

Until the real model lands, the spike stub (`Spike/Sources/main.swift`) is the Day-1
benchmark harness home.

## Privacy posture

On-device only: no cloud, no upload, no account, no network calls, no analytics, no
third-party packages. `PhotosPicker` runs out of process, so the app never requests
photo-library permission. Split outputs live in `Caches/Splits/<uuid>/` and are purged on
the next launch; nothing is collected and nothing leaves the device. See
`Release/privacy.html` (the published policy page) and `Release/APP_STORE.md` (App Store
privacy labels and the `PrivacyInfo.xcprivacy` manifest).

## Distribution

Local Xcode builds → TestFlight external testing → App Store submission. No CI/CD in v1.
The full runbook — privacy labels ("no data collection"), TestFlight steps, and the
iPhone 17 gate-device bar — is in [`Release/APP_STORE.md`](Release/APP_STORE.md).
