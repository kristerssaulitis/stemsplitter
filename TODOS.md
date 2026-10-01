# TODOS — StemSplitter

Deferred work from the CEO review (SELECTIVE EXPANSION, /autoplan 2026-10-01). Design doc:
`~/.gstack/projects/kristers/stemsplitter-no-branch-design-20261001.md`.

## TODO: Audio-file import (MP3/WAV/FLAC/M4A as input)
- **What:** Accept bare audio files, not just gallery videos.
- **Why:** Premise 2 deliberately made v1 video-native; audio import widens input surface without new pipeline work.
- **Pros:** One importer path, reuses the whole engine; matches StemLab's import surface.
- **Cons:** Dilutes the "videos on my phone" positioning if it ships before the wedge lands.
- **Context:** Design doc premise 2 defers this to v2. Add via `.fileImporter` alongside PhotosPicker; AVAssetReader path is identical once you have an URL.
- **Effort:** human S / CC S.
- **Priority:** P2.
- **Depends on:** v1 shipped.

## TODO: 4-stem model (vocals/drums/bass/other)
- **What:** Second model + adapter behind the existing StemSeparator protocol.
- **Why:** Premise 3's stated v2; the producer mental model of a "stem splitter."
- **Pros:** Engine already written against a chunk/overlap-add contract; app grows by one model + adapter.
- **Cons:** 3-6x model weight (app size toward StemLab's 367MB); htdemucs CoreML operator coverage is unproven — spike required.
- **Context:** Design doc Approach B caveat. Day-1 spike must confirm the conversion path for whichever family ships.
- **Effort:** human M / CC S-M.
- **Priority:** P2.
- **Depends on:** CoreML conversion spike for the 4-stem family.

## TODO: Chunk-level resume for interrupted splits
- **What:** Persist per-chunk progress so an interrupted split continues instead of restarting.
- **Why:** Long-video UX; v1 restarts from zero by explicit decision.
- **Pros:** 15-min video no longer re-spends minutes of CPU after a suspension.
- **Cons:** Persistence complexity in the pipeline; partial-state cleanup on cancel.
- **Context:** Design doc Constraints ("foreground-only" bullet). Only worth it after real users hit it.
- **Effort:** human M / CC M.
- **Priority:** P3.
- **Depends on:** v1 shipped + evidence long-video splits are common.

## TODO: 30-second preview split
- **What:** Split only the first ~30s first, let the user hear quality, then commit to the full run.
- **Why:** Delight-scan candidate; kills the "wait 90s to discover quality is bad" risk on long sources.
- **Pros:** Chunked pipeline already produces per-chunk output; preview is a stop-condition change.
- **Cons:** Two-phase UX changes the processing screen semantics mid-v1.
- **Context:** Deferred by CEO decision CEO-5 (P3).
- **Effort:** human S-M / CC S.
- **Priority:** P3.
- **Depends on:** v1 shipped.

## TODO: Share Extension / App Intents front door
- **What:** "Extract Vocals" in the OS share sheet; Siri/Shortcuts integration.
- **Why:** Approach C from the design session — closest to the moment of want.
- **Pros:** Novel front door no incumbent uses; zero app-switch.
- **Cons:** Extension memory ceilings threaten the speed bar directly; App Review scrutiny; hostile debugging.
- **Context:** Design doc Approach C, "logged for v3 exploration."
- **Effort:** human L / CC M-L.
- **Priority:** P3.
- **Depends on:** v2 (engine proven, model memory footprint known).
