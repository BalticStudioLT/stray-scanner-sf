# Stray SF + SplatForge — roadmap and tests

Agreed with the owner on 2026-11-05 (23:00–23:48). Order = priority. Every item has a test that decides whether it
ships. "Phone" = this app (stray-scanner-sf), "PC" = SplatForge (Opus implements, Fable evaluates research items).
Test scans: `dotnuva_tractor` (outdoor, drone + phone), `kitchen_v2` (indoor), plus one new **test room** scan with a
window, a mirror and a person walking through (record once, reuse for every test below).

Status: ☐ not started · ◐ in progress · ☑ done

| # | Item | Where | Status |
|---|---|---|---|
| 1 | Live PC preview splat while scanning | PC + phone (phone ☑) | ◐ |
| 2 | Actionable live tips, target spot, end verdict | PC + phone (phone ☑) | ◐ |
| 3 | Masks: moving objects (optical flow), sky, glass, mirrors | phone → PC (phone: people + moving objects ☑, masks/ + masks.csv; sky/glass/mirror later; PC must use them) | ◐ |
| 4 | Windows / glass without floaters (RT-Splatting idea) — **low priority**: owner 23:51, windows already come out well; only if a test shows a problem | PC (Fable) | ☐ |
| 5 | Mirrors (mirror plane + masks) | PC (Fable) | ☐ |
| 6 | LiDAR-anchored training (Structured-Li-GS idea) | PC (Fable) | ☐ |
| 7 | LOD: coarse far, detailed near, streamed chunks | PC ☑ + phone ☑ (whole scene at L0, nearby chunks refined to L1/L2 within the Quality budget) | ☑ (needs owner test) |
| 8 | Compression + web streaming (SOG / streamed SOG / SPZ) | PC fmt=3 ☑ (26 B/splat) + phone reads it ☑; web export pending | ◐ |
| 9 | MetalFX upscaling + variable-rate edges | phone (MetalFX spatial ☑, dynamic resolution ☑ — full quality when still; AR at reduced res ☑; temporal/VRR not needed for now) | ☑ |
| 10 | AR occlusion: real objects (LiDAR) cover the splat | phone | ☑ (needs owner test) |
| 11 | Frame reuse when still / slow (battery) | phone (3D view draws only on change ☑; recorder preview at 30 fps ☑) | ☑ |
| 12 | Better coverage guidance (area-weighted sphere of views) | phone (tips to the nearest surface seen from one side only, works without PC ☑) | ☑ |
| 13 | Automatic guided-tour route from path + pins | PC | ☐ |
| 14 | Enhancement during training (Difix3D+ idea), per-job switch | PC (Fable) | ☐ |
| 15 | Sort-free "fast" viewer mode (Mobile-GS idea) | phone (weighted blended OIT while moving in Fastest ☑) | ☑ (needs owner test) |
| 16 | Splat training on the phone, no PC (PocketGS idea) | phone (v1 ☑: LiDAR-anchored isotropic splats, colour/opacity/size learnt on the GPU, phone_splat.ply; v2: learn positions + anisotropy, SSIM) | ◐ (needs owner test) |

## Tests

**1 Live preview.** Scan the test room for 2 min with the PC running. Pass: first preview ≤ 40 s after start, updates
every ≤ 30 s; in "PC preview" view the splat lines up with the camera (edges within ~5 cm at 2 m); no other GPU
training runs at the same time on the PC (queue paused or preview reports "GPU busy"); phone stays ≥ 20 fps preview.

**2 Tips.** Same scan, deliberately skip one corner and walk fast once. Pass: a tip names the skipped area within 30 s;
the target arrow points to it (left/right/behind correct); "walk slower" appears on the fast part; on stop the pop-up
says "rescan" and names the corner. Second run covering everything → "good to train".

**3 Masks.** Test room with a person walking through. Pass: masks cover the person in ≥ 90 % of their frames, ≤ 2 % false
mask on static walls; sky/window/mirror masks visually correct on 20 random frames; training with masks has no ghost of
the person (compare splats with/without masks from the same viewpoints).

**4 Glass (low priority, owner: windows already OK).** First just check existing scans; only work on it if a test fails. Test room window + one car window (tractor cab). Pass (Fable): fewer floaters behind glass (count splats
behind the window plane), held-out PSNR on window views ≥ baseline, background through glass visibly clearer.

**5 Mirrors.** Test room mirror. Pass: no "room behind the mirror" splats; mirror region held-out PSNR ≥ baseline.

**6 LiDAR anchoring.** kitchen_v2 + test room. Pass: ≥ 30 % fewer Gaussians at equal or better held-out PSNR/LPIPS;
walls flatter (plane fit RMS lower).

**7 LOD.** dotnuva_tractor full (3.8 M) on the phone. Pass: first image ≤ 3 s; walking close to the combine loads finer
chunks within 1 s; memory ≤ 1.5 GB; ≥ 30 fps in 3D view; no visible popping seams between chunks at normal speed.

**8 Compression.** Pass: file ≥ 10× smaller than PLY, PSNR drop ≤ 0.3 dB vs the PLY render from 20 fixed views; web tour
on a phone over 4G shows the scene ≤ 3 s; phone app opens it ≥ 2× faster than today.

**9 MetalFX.** Pass: ≥ 1.5× frame rate at "All splats" with no visible shimmer when orbiting slowly (side-by-side video);
can be turned off.

**10 AR occlusion.** Pass: a hand or person in front of a placed splat hides it correctly (edge error ≤ a few pixels),
no flicker on static scenes.

**11 Frame reuse.** Pass: viewer standing still uses ≤ 10 % GPU; scanning battery drain −15 % or better over 10 min
compared with today (same route).

**12 Coverage guidance.** Object scan (e.g. a chair) with and without the new guide. Pass: same or better PSNR with
≥ 20 % fewer frames.

**13 Tour route.** Test room + kitchen with 3–5 pins. Pass: route visits every pin, no path through walls, owner approves
it as a usable first draft.

**14 Enhancement.** Pass (Fable): sharper novel views (LPIPS better) without inventing content: the owner checks 10
views for fake details (tiles, windows, text). Off by default for client tours until approved.

**15 Fast mode.** Pass: ≥ 2× frame rate vs the current GPU sort at 3 M splats; artefacts acceptable to the owner on the
tractor and kitchen; normal mode stays default.

**16 Phone training.** Pass: a 1-min scan gives a viewable splat on the phone in ≤ 5 min, phone does not overheat
(thermal state ≤ serious), PSNR within 2 dB of the PC draft.

## Already done 2026-11-05 (tested on the phone by the owner)
Full GPU sort ("much better"), per-splat covariance encoding, best-first + pruned splats (opt=1), SH1 colour, level from
PC up vector, new viewer UI, full-screen recorder, unique small views, GPU point cloud while scanning.

## 2026-11-11 — SplatForge LOD v4 + review #6
- [x] LOD index v3/v4: `cell_m` level pick (≤ `pick_px` px, `hysteresis` going coarser), L2 as delta over L1 (L1 covariances ÷ growth²), ≤4 chunk requests in flight, chunk files cached on disk per index.
- [x] `start_view`: 3D view opens at the PC's camera with its vertical FOV; double-tap returns there; `i2s_` (one-photo) splats orbit only ±45°.
- [x] Clamped Jacobian + footprint culling (big splats at the screen edge no longer pop or smear).
- Test: open a large LOD scene twice (second open instant from cache); walk close → L2 appears without double-bright splats; edge of screen while orbiting has no popping.

## 2026-11-25 — new iPhone 16 Pro, self-review (owner: "specially UI and performance with a scan quality")

Found by reading the code and the owner's old-phone settings (4K, 1/500 s, 2.5 saved frames/s):

**Scan quality**
- [x] Video quality setting (Standard / High / Maximum): explicit HEVC bit rate, one key frame per second, no frame reordering. Default High (≈ 3× the old bit rate). Before, iOS chose a low rate that smears fine texture.
- [x] Sharp photos (beta, off by default): ARKit high-resolution frames (≈ 12 MP) once or twice a second while steady, `stills/` + `stills.csv` with own pose and intrinsics. Saved only; SplatForge does not train on them yet (note to Opus).
- [x] Recording could report "all good" after the video writer failed (a later status overwrote the error) and could hang at Stop when the writer had failed. Both fixed; a failed writer now shows "Recording failed" while scanning.
- [x] The video file is finished before the scan is zipped/sent (it was finished asynchronously).
- [x] Capture choices (4K, quality, photos) are locked while recording: changing 4K mid-scan would have changed the video size under the encoder.
- [x] Hints: "Focus locks at start — aim about 2 m away" before recording when pointing closer than 0.8 m; "Phone can't keep up" when frames are skipped.
- [x] PC side (splatforge/stray.py): the frame pick window follows the saved frame rate. At 2.5 fps the fixed window of 3 dropped two of every three frames.
- [ ] PC: train on `stills/`; drop frames with limited tracking (needs a real-scan A/B).

**Performance**
- [x] Run builds are now optimized (Release). The app on the phone had always been an unoptimized Debug build: slower loading, decoding, mask and PNG work.
- [x] Scan list: per-scan numbers cached (were re-read from CSV and ~20 000 files on every appearance); thumbnails cached.
- [x] Viewer: 120 Hz on ProMotion phones while orbiting; on 8 GB phones the default quality is 2 M splats and streaming may use up to 8 M.
- [x] Storage check while recording: every 10 s after the first 45 s (was every 3 s over all files).
- [ ] Viewer memory: projected records only for visible splats, SH as 8-bit (from SplatForge's notes).

**UI**
- [x] Three tabs: Scans / Splats / Settings. Splats tab: phone-scan splats first and newest first, splats trained on the phone, other PC splats, then PC status; finished jobs folded away.
- [x] Scan list: thumbnail, own name (rename), length, sharp %, size, "On PC" / "Splat" badges, swipe to rename or delete (with confirmation).
- [x] Settings tab: PC pairing state and test, capture choices, scanning guide. Connection errors say what to do ("Studio is not running — start studio.bat").
- [x] "Training now" card reads SplatForge's `live` block (was the last snapshot: step 22 001 while the job was at 34 500; PSNR never showed).
- [x] Dark launch screen; "Saving the scan…" shown while files are finished; clear error when a scan could not be saved.
- [x] App also builds for the Simulator (MetalFX optional), with Debug-only launch arguments for screenshots.
- [ ] 4D splat playback in the app (owner 01:03).

Tests for the owner: one scan on High with the usual settings → compare wall texture with an old scan; rename/delete from the list; Splats tab shows the scan's project at the top after training.
