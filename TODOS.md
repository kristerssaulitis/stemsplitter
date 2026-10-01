# TODOS — StemSplitter

Deferred work from the CEO review (SELECTIVE EXPANSION, /autoplan 2026-10-01). Design doc:
`~/.gstack/projects/kristers/stemsplitter-no-branch-design-20261001.md`.

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

## DONE (2026-10-01)
- Audio-file import (Files app, `.fileImporter`).
- 4-stem model: htdemucs via `DemucsEngine`, mixer UI with mute/solo/presets/pitch/speed,
  mix + video export.
