# StemSplitter

Video-native, on-device stem splitter for iOS: pick a gallery video (or an audio file),
split it into vocals / drums / bass / other with htdemucs, mix them (mute, solo, presets,
pitch, speed) and export the mix, a video with the mix, or any stem as 24-bit WAV via the
share sheet. No account, no upload, nothing leaves your phone.

- Approved plan: `~/.gstack/projects/kristers/stemsplitter-no-branch-design-20261001.md`
- Test plan (QA governance): `~/.gstack/projects/kristers/kristers-no-branch-eng-review-test-plan-20261001-063500.md`
- Release/distribution: [`Release/APP_STORE.md`](Release/APP_STORE.md)
- Privacy policy page (App Store URL source): [`Release/privacy.html`](Release/privacy.html)

## Requirements

- Xcode (with an iOS 18+ simulator)
- iOS 18 minimum deployment target (the Core ML model needs it)
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

## The separation model (htdemucs)

The app ships Meta's htdemucs (4 stems: vocals, drums, bass, other; MIT licensed),
converted by the Mac app's tooling. `Models/` is gitignored — set it up once:

```sh
cp -R ../stemsplitter-mac/Models/htdemucs.mlpackage ../stemsplitter-mac/Models/htdemucs.mlmodelc Models/
```

(Or regenerate with `../stemsplitter-mac/tools/convert_htdemucs.py`.) The Xcode target
compiles `Models/htdemucs.mlpackage` into the app; `DemucsEngine` loads it on the GPU and
falls back to CPU if a sanity segment comes back silent (the iOS Simulator's GPU path
does this, so the simulator always uses CPU and is much slower than a device).
`DemucsEngineTests` run the real model when `Models/htdemucs.mlmodelc` exists.

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
