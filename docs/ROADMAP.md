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
| 3 | Masks: moving objects (optical flow), sky, glass, mirrors | phone → PC | ☐ |
| 4 | Windows / glass without floaters (RT-Splatting idea) — **low priority**: owner 23:51, windows already come out well; only if a test shows a problem | PC (Fable) | ☐ |
| 5 | Mirrors (mirror plane + masks) | PC (Fable) | ☐ |
| 6 | LiDAR-anchored training (Structured-Li-GS idea) | PC (Fable) | ☐ |
| 7 | LOD: coarse far, detailed near, streamed chunks | PC + phone | ☐ |
| 8 | Compression + web streaming (SOG / streamed SOG / SPZ) | PC (+ phone reads it) | ☐ |
| 9 | MetalFX upscaling + variable-rate edges | phone | ☐ |
| 10 | AR occlusion: real objects (LiDAR) cover the splat | phone | ☐ |
| 11 | Frame reuse when still / slow (battery) | phone | ☐ |
| 12 | Better coverage guidance (area-weighted sphere of views) | phone | ☐ |
| 13 | Automatic guided-tour route from path + pins | PC | ☐ |
| 14 | Enhancement during training (Difix3D+ idea), per-job switch | PC (Fable) | ☐ |
| 15 | Sort-free "fast" viewer mode (Mobile-GS idea) | phone | ☐ |
| 16 | Splat training on the phone, no PC (PocketGS idea) | phone | ☐ |

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
