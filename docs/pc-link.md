# Phone ⇄ SplatForge PC link (stray-scanner-sf)

The iPhone app talks plain HTTP / WebSocket to the **SplatForge Studio server** (`splatforge/studio.py`, port **8777**)
on the owner's PC. Over the internet this runs through **Tailscale** (Tailscale app on the iPhone + Tailscale on the PC,
same account); the app only needs the PC's Tailscale name (MagicDNS, e.g. `coolmaster`) or its `100.x.y.z` address.

Authentication: every request carries the Studio token (`A:\AI\SplatForge\.studio_token`) in the header **`X-Token`**
(the Studio also accepts `?t=<token>`). The phone stores host, port and token in its settings (Scans ▸ PC ▸ gear).

## 1. Already working with today's Studio (no PC changes)

| Phone feature | Studio endpoint |
|---|---|
| Test connection, PC status (CPU/RAM/GPU, running items with ETA, queue, worker beat) | `GET /api/system` |
| Training now (run, snapshots with step/PSNR/splats, progress, done) | `GET /api/live` |
| Job list, cancel a job | `GET /api/jobs`, `POST /api/cancel {"id": N}` |
| Results (projects, runs, PSNR, splats) | `GET /api/projects` |
| Full Studio inside the app (viewer, editing, show mode) | `GET /?t=<token>` in a web view |

## 2. To implement on the PC (SplatForge side)

All under the same server and token check (`H._auth`). JSON answers unless stated.

### 2.1 Upload a finished scan — already in SplatForge (`docs/PHONE_SCAN_API.md`, 2026-11-05)
The app uses it as is: `POST /api/scan/upload?name=<scan folder>&recipe=base|draft` with the zip as the body
(`Content-Length` set, `X-Token`), then polls `GET /api/scan/state?name=…` every 5 s until it has a `job`, then
`GET /api/scan/status?job=…` until `done` (shows `text`/`progress`, and PSNR from `result`) or `failed`.
"Quick draft" in the phone's PC settings sends `recipe=draft`.

### 2.2 Live link while scanning — WebSocket `GET /stray/live` (upgrade)
`http.server` cannot do WebSockets, so the app connects to **`ws://<host>:<Studio port + 1>/stray/live`**
(= `ws://coolmaster4:8778/stray/live`) with the same `X-Token` header. Suggested: a small listener using the
`websockets` package (BSD-3), bound like the Studio (127.0.0.1 + Tailscale address only).

Phone → PC:
- Text JSON `{"type":"hello","app":"stray-scanner-sf","protocol":1,"device":"iPhone","scan":null,"image_width":1920,"image_height":1440}`
- Text JSON `{"type":"recording_started","scan":"<folder>"}` / `{"type":"recording_stopped","scan":"<folder>"}`
  (after "stopped", the upload of that folder follows if the owner turned on auto-upload).
- Text JSON at ≤ 5 Hz: `{"type":"frame","t":<ARKit s>,"frame":<saved frame number or -1>,"recording":true,
  "pose_arkit_c2w_colmajor":[16 floats, ARKit camera-to-world, column-major, camera looks −Z, y up],
  "intrinsics":[fx,fy,cx,cy] (full image px),"tracking":"normal|limited|not_available","blur_px":0.8,
  "speed_mps":0.2,"turn_dps":12,"median_depth_m":1.6,"torch":0}`
- Binary ≤ 2 Hz, **new points since the last batch**: `"SFPT"` + uint32 LE count + count × (3 × float32 LE x,y,z in
  ARKit world metres, 4 × uint8 r,g,b,a). One point per 2 cm voxel, colours from the camera. Max 30 000 per batch.
- Text JSON `{"type":"reset_points"}`: the phone cleared its cloud (a recording started) — drop preview points.
- Binary 1 Hz: `"SFJP"` + int32 LE frame number + JPEG (long side 640 px, sensor orientation = landscape).

PC → phone (text JSON, any time):
- `{"type":"hint","text":"Scan the left corner again","level":"info|good|warning|bad","ttl":5}` — shown in the
  phone's advice banner (the phone's own warnings about blur/tracking still win).
- `{"type":"status","text":"coverage 72 %, 3 holes"}` — one line in the phone's stats card.
- `{"type":"markers","points":[[x,y,z],…],"color":[1,0,1]}` — up to 2000 world points (ARKit frame) drawn in the
  phone's camera/mix/point-cloud/minimap views, e.g. holes to fill. Send `[]` to clear.

Ideas for the PC side, in order of value: (1) voxel coverage from the streamed points + frame poses → markers at
holes and under-observed surfaces; (2) blur/overlap check per area from the poses → "go back to …" hints;
(3) a quick preview splat trained from the streamed JPEGs + points (Studio show mode).

### 2.3 Finished splats on the phone — planned app feature (needs these endpoints)
- `GET /stray/results` → `[{"project","run","psnr","splats","done":true,"bytes_ply","source_scan":"<stray folder or null>",
  "scan_to_splat":[16 floats or null]}]` — finished runs; `source_scan` and `scan_to_splat` (column-major 4×4 that maps
  ARKit world coordinates of that Stray scan into splat coordinates, including scale) let the phone show the splat
  **in AR exactly where it was scanned** (the app relocalizes with the scan's `worldmap.arexperience`).
- `GET /stray/splat?project=…&run=…&max=1500000` → splat for mobile: **binary little-endian PLY** in the standard 3DGS
  layout (x y z, f_dc_0..2, opacity, scale_0..2, rot_0..3; SH degree 0 is enough), sorted by importance and cut to
  `max` splats. Header `X-Splat-Count`. Gzip (`Content-Encoding: gzip`) welcome.

## 3. Scan files the importer should know about (all optional, old scans lack them)

- `capture_settings.json` → `"video_frame_offset": 0` means **video frame i = odometry row i = depth/confidence i**
  (fixed in the app on 2026-11-05). Missing key = old behaviour: video frame i = odometry row i + 1, and depth PNG i
  belongs to odometry row i (so depth is one frame older than the image it is paired with by index).
  Also `video_width/height/fps` (4K scans are 3840×2880 at 30 fps), `shutter_setting`, `torch_mode`,
  `iso_torch_on/off`, `continues_scan` (this scan continues another one in the same coordinates).
- `frame_quality.csv` → `frame` is the **odometry frame number**, not the video index (on old scans: row i + 1).
  Columns: tracking_state, tracking_reason, linear_speed_mps, angular_speed_dps, est_blur_px, median_depth_m,
  depth_confident_fraction, torch_level.
- `exposure.csv` (exposure time, ISO, white balance per frame), `markers.csv` (owner's pins, odometry pose
  convention), `worldmap.arexperience` (ARKit map; only useful on the phone).
- `rgb.mp4` is now a fragmented MP4 (readable after a crash; ffmpeg reads it normally).
