
# Stray Scanner App — stray-scanner-sf fork

This is a fork of [strayrobots/scanner](https://github.com/strayrobots/scanner) (MIT licence) made for capturing scans for Gaussian splatting (SplatForge). Changes from upstream:

- **Short shutter.** A selector in the record screen (next to the fps button) chooses `Auto exp` (stock behaviour), `1/120 s`, `1/250 s` or `1/500 s` (default `1/250 s`). It uses `ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera` to set a custom exposure duration; ISO follows the light meter, clamped to the device's min/max ISO. ARKit tracking and LiDAR depth run exactly as before.
- **White balance and focus are locked while recording** so colours and sharpness don't drift between frames; they unlock when recording stops.
- **`exposure.csv`**: per-frame exposure time, exposure offset, ISO and white balance gains, frame numbers identical to `odometry.csv`. **`capture_settings.json`**: the chosen shutter setting and lock state. See [docs/format.md](docs/format.md#exposure-data-stray-scanner-sf-fork).
- **New record screen** (Liquid Glass on iOS 26+): view modes Camera / Depth (LiDAR in colour) / Mix / Points (live coloured point cloud, tap to switch overview ↔ camera view) / Dim (black screen, low brightness, haptic warnings). Live stats (exposure, ISO, motion-blur estimate, rotation speed vs. the limit for sharp frames, subject distance, distance moved, frames and dropped frames, scanned surface, free storage and minutes left, battery), a ring showing which directions have been filmed, and advice (slow down, too close/far, too dark, turn left/right to unscanned areas, tilt for floor/ceiling). The screen no longer auto-locks while recording.
- **Pin button** while recording saves the current pose to `markers.csv` (e.g. guided-tour stops). **`frame_quality.csv`** stores per-frame tracking state, speeds, blur estimate and depth so frames can be filtered before training. Scan list shows per-scan stats (shutter, frames, % sharp frames, pins, size).
- **Views menu** (layers button, top left): small Camera, LiDAR and Minimap (top view) windows, colour the point cloud by coverage (red = seen from one direction only, green = 4+ directions), and the **wall path guide**: vertical stripes every 30/50/80 cm on the wall you face; sweep floor ↔ ceiling at each stripe, it turns green, the banner tells you which way to step. The overview and minimap cut the ceiling away.
- **Light button**: off / on / alternate every second (two light setups; ISO frozen while alternating; level logged per frame).
- **Crash safety**: fragmented `rgb.mp4`, automatic recovery of unfinished scans, room map saved every 20 s and **Continue** to keep scanning in the same coordinates. Heat state and app CPU shown; when hot the preview gets lighter, at critical it switches to Dim and turns the light off. (iOS does not let apps read the real temperature or CPU clock.)
- All existing files (`rgb.mp4`, `depth/`, `confidence/`, `distortion/`, `odometry.csv`, `imu.csv`, `camera_matrix.csv`) are written exactly as upstream.
- Minimum iOS is 16.0. Bundle id `lt.nuskenuota.strayscanner`, app name "Stray SF", so it installs next to the App Store version.
- Installing with a free Apple ID (7-day signing): see [REINSTALL.md](REINSTALL.md).

A shorter shutter means less motion blur but a darker / noisier image in dim rooms; ISO is raised to compensate until it hits the device's maximum.

---

# Stray Scanner App (upstream README)

The goal of this app, is to allow easy access to raw RGB-D video datasets recorded using LiDAR enabled iOS devices. The app can be downloaded for free [on the iOS App Store](https://apps.apple.com/us/app/stray-scanner/id1557051662).

<img src="images/screenshot.jpg" style="width: 250px" alt="Stray Scanner RGB-D scanning view">

## Usage

Documentation can be found under the [docs](docs/) directory. The document [docs/format.md](docs/format.md) describes the data format and conventions used in the app.

## Related projects

- [StrayVisualizer](https://github.com/kekeblom/StrayVisualizer): a project to visualize the raw data collected by the app
- [MATLAB Scripts](https://github.com/PyojinKim/StrayScannerVisualizer): a set of tools to work with the data format in Matlab
- [Autolabel](https://github.com/ethz-asl/autolabel): an interactive volumetric labeling tool

## Contributing

Contributions are welcome. To contribute, simply open a pull request.

Some ideas for improvements include:
- Better scan viewer
- Better ways to organize scans, e.g. through tags
- Recording other modalities, such as audio, Wifi or GPS
- Direct upload to cloud services or S3

