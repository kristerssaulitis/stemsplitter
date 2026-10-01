# APP_STORE.md — StemSplitter v1 release runbook

Source of truth: approved plan
`~/.gstack/projects/kristers/stemsplitter-no-branch-design-20261001.md` — Distribution
Plan, Constraints (privacy posture), T11, and the CEO/eng review obligations. T11 owns
this surface: "privacy policy page + App Store labels + TestFlight setup. Verify: labels
declare no collection; TestFlight external build installs."

## Distribution path

Personal Apple Developer Program ($99/yr) → local Xcode builds → TestFlight external
testing → App Store submission. No CI/CD in v1 (revisit when a repo and release cadence
exist). Builds are CLI-verified with the DEVELOPER_DIR command pair in `README.md`;
final archives happen in Xcode (Product → Archive).

## App Store privacy nutrition labels

**StemSplitter declares "No Data Collection."** In App Store Connect (App Privacy):
answer **No** to "Do you or your third-party partners collect data from this app?" —
no data types are declared in any category.

Why this is true (plan Review Section 3, Security & Threat Model):

- No network stack, no auth, no accounts, no analytics, no ads — nothing leaves the
  device; the app has no server.
- No third-party packages in v1 (Apple frameworks + the bundled model only), so no
  third-party SDK data collection to disclose.
- `PhotosPicker` is out-of-process — the app never receives photo-library access.
- Split outputs live in app caches (`Caches/Splits/<uuid>/`) and are purged on next
  launch; only user-initiated share/Save-to-Files exports persist.

**Standing rule:** the label must remain true — no analytics may be added later without
changing the label (plan S3).

## Privacy manifest (PrivacyInfo.xcprivacy)

`Release/PrivacyInfo.xcprivacy` ships these declarations, all true of the shipped app:

| Key | Value | Basis |
|---|---|---|
| `NSPrivacyTracking` | `false` | No tracking of any kind |
| `NSPrivacyTrackingDomains` | `[]` (empty) | No tracking; no network at all |
| `NSPrivacyCollectedDataTypes` | `[]` (empty) | "No data collection" label |
| `NSPrivacyAccessedAPITypes` | `NSPrivacyAccessedAPICategoryDiskSpace` → `E174.1` | Plan-mandated disk preflight: check free space before writing split output (~32 MB/minute ×1.2 + 1 GB headroom; frozen contract `StemError.preflight`) |

File-timestamp, system-boot-time, and active-keyboard categories are **not** declared —
the app does not use them. If the implementation ever adds a required-reason API, update
the manifest in the same change.

**Install step (before archiving):** copy `Release/PrivacyInfo.xcprivacy` into the app
target directory (`App/`) and add it to the StemSplitter target's resources in
`StemSplitter.xcodeproj` (Copy Bundle Resources). It must be present in the uploaded
archive or App Store Connect flags the build.

## Privacy policy URL (mandatory)

A static page that states the app collects nothing: [`Release/privacy.html`](privacy.html).

1. **Fill the contact placeholder** in the page's Contact section (marked
   `TODO(contact)`) — do not publish without it.
2. Host the page at any static host (the plan requires only "a static page — the app
   collects nothing").
3. Set the URL in App Store Connect (App Information → Privacy Policy URL) and as the
   review-notes link.

## TestFlight notes

Prerequisite: Apple Developer Program enrollment (plan dependency; T11's "TestFlight
external build installs" verification needs it plus a physical device).

1. Configure signing in `StemSplitter.xcodeproj` (the project currently builds with
   `CODE_SIGNING_ALLOWED=NO` — flip that off / set a team when signing lands).
2. Archive: Xcode → Product → Archive (generic iOS device destination).
3. Distribute: Organizer → Distribute App → TestFlight (App Store Connect upload).
4. Enable dSYM upload for App Store Connect crash reporting (plan Section 8).
5. Internal testing first, then an external group. Gate: an external tester build
   **installs and runs the full flow on a physical iPhone** (picker → split → result →
   share) — that closes T11's verification.
6. TestFlight is the feedback channel in v1 (plan Section 8: no server, no analytics).

Demand gate (CEO amendment): App Store submission **beyond** TestFlight is conditional
on the plan's Assignment outreach producing ≥3 unprompted asks/offers. The founder may
override explicitly.

## Gate-device bar (verify before submission)

Gate device per the 2026-10-01 addendum: **iPhone 17 (A19)**. The simulator has no
Neural Engine — these are device-only checks, run via the benchmark harness / Day-1
spike protocol (plan T1/TE2) pinned to the shipping configuration (stereo dual-pass,
96–128 kbps AAC corpus, resample + overlap-add included, ANE residency logged).

| Gate | Bar | On miss |
|---|---|---|
| Speed | 3-minute video splits < 90 s wall-clock ON the iPhone 17 | >135 s (1.5×) → tiered processing fallback; >180 s (2×) → revisit premise 4 scope with the founder |
| Quality | Blind listen beats StemLab on the same compressed-social-video corpus | Revisit the gate policy before building further |
| Memory | < 400 MB `phys_footprint` (Xcode memory gauge) during a 15-minute split | Fix the streaming invariant before release |
| Size | App Store download size < 150 MB | Trim the bundled model first |
| Stability | Crash-free through the flow including no-audio, cancel, and disk-full paths | Blocker |
| License | Model weights verified commercial-OK (Day-1, up front — launch blocker) | Non-commercial weights rejected outright |

## Submission checklist

- [ ] `Release/privacy.html` contact placeholder filled; page hosted; URL set in App Store Connect
- [ ] App Store privacy labels set: **no data collection**
- [ ] `PrivacyInfo.xcprivacy` copied into the app target and present in the archive
- [ ] Model weights license verified commercial-OK
- [ ] Benchmark passed on iPhone 17: < 90 s / 3-min video, < 400 MB peak, blind listen
- [ ] TestFlight external build installed and full flow smoke-tested on a physical device
- [ ] dSYM upload enabled (crash reporting)
- [ ] Release-build smoke of the full flow on the founder's device
