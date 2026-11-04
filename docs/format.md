
# Data Specification

This document describes the data format recorded by the app.

The collected datasets are each contained in a folder, named after a random hash, for example `71de12f9`. A dataset folder has the following directory structure:

```
camera_matrix.csv
odometry.csv
imu.csv
depth/
  - 000000.png
  - 000001.png
  - ...
confidence/
  - 000000.png
  - 000001.png
  - ...
distortion/          (optional, present when lens distortion data is available)
  - 000000.bin
  - 000001.bin
  - ...
rgb.mp4
exposure.csv         (stray-scanner-sf fork only)
capture_settings.json (stray-scanner-sf fork only)
frame_quality.csv    (stray-scanner-sf fork only)
markers.csv          (stray-scanner-sf fork only, present when pins were set)
worldmap.arexperience (stray-scanner-sf fork only, ARKit map of the room, saved every 20 s)
```

`rgb.mp4` is an HEVC encoded video, which contains the recorded data from the iPhone's camera.

The `depth/` directory contains the depth maps. One `.png` file per rgb frame. Each of these is a 16 bit grayscale png image. They have a height of 192 elements and width of 256 elements. The values are the measured depth in millimeters, for that pixel position. In [OpenCV](https://docs.opencv.org/4.5.5/), these can be read with `cv2.imread(depth_frame_path, -1)`.

The `confidence/` directory contains confidence maps corresponding to each depth map. They are grayscale png files encoding 192 x 256 element matrices. The values are either 0, 1 or 2. A higher value means a higher confidence.

The `camera_matrix.csv` is a 3 x 3 matrix containing the [camera intrinsic parameters](https://en.wikipedia.org/wiki/Camera_resectioning#Intrinsic_parameters) from the final recorded frame. This file is kept for backwards compatibility; for per-frame intrinsics use the `fx`, `fy`, `cx`, `cy` columns in `odometry.csv`.

The `odometry.csv` file contains the camera pose and intrinsics for each frame. The first line is a header. The meaning of the fields are:

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds |
| frame | Frame number to which this pose corresponds to e.g. `000005` |
| x | x coordinate in meters from when the session was started |
| y | y coordinate in meters from when the session was started |
| z | z coordinate in meters from when the session was started |
| qx | x component of quaternion representing camera pose rotation |
| qy | y component of quaternion representing camera pose rotation |
| qz | z component of quaternion representing camera pose rotation |
| qw | w component of quaternion representing camera pose rotation |
| fx | Horizontal focal length in pixels |
| fy | Vertical focal length in pixels |
| cx | Principal point x coordinate in pixels |
| cy | Principal point y coordinate in pixels |
| distortion_center_x | x coordinate of the lens distortion center in pixels (empty if unavailable) |
| distortion_center_y | y coordinate of the lens distortion center in pixels (empty if unavailable) |

The `distortion/` directory contains per-frame lens distortion lookup tables, present only when the device exposes calibration data. Each `.bin` file is a raw array of little-endian `float32` values mapping radial distance from the distortion center to a correction factor. The number of entries is `file_size_in_bytes / 4`. The filenames correspond to the `frame` field in `odometry.csv`.

The `imu.csv` file contains timestamps, linear acceleration readings and angular rotation readings. The first line is a header. The meaning of the fields are:

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds |
| a\_x | Acceleration in m/s^2 in x direction |
| a\_y | Acceleration in m/s^2 in y direction |
| a\_z | Acceleration in m/s^2 in z direction |
| alpha\_x | Rotation in rad/s around the x-axis |
| alpha\_y | Rotation in rad/s around the y-axis |
| alpha\_z | Rotation in rad/s around the z-axis |


## Exposure data (stray-scanner-sf fork)

This fork adds two files. All files above are unchanged, so existing tools keep working and can ignore the new ones.

`exposure.csv` holds the real exposure of every saved frame. The first line is a header. There is exactly one row per row of `odometry.csv`, with the same `timestamp` and `frame` values.

| Field | <div style="width: 500px">Meaning</div> |
|---|---|
| timestamp | Timestamp in seconds (same as `odometry.csv`) |
| frame | Frame number, e.g. `000005` (same as `odometry.csv`, `depth/`, `confidence/`) |
| exposure_duration_s | Exposure (shutter) time of the frame in seconds, from `ARFrame.camera.exposureDuration`. 1/250 s ≈ `0.004` |
| exposure_offset | `ARFrame.camera.exposureOffset`, the exposure offset ARKit reports for the frame (EV) |
| iso | ISO of the capture device when the frame arrived |
| white_balance_r | Red white balance gain of the capture device (`deviceWhiteBalanceGains`) |
| white_balance_g | Green white balance gain |
| white_balance_b | Blue white balance gain |

`iso` and the white balance columns are empty if the device does not expose a configurable capture device.

`capture_settings.json` describes how the scan was recorded, written when recording starts:

| Key | Meaning |
|---|---|
| shutter_setting | `"Auto"`, `"1/120"`, `"1/250"` or `"1/500"` (the selector in the record screen) |
| requested_exposure_duration_s | Requested shutter time in seconds, `null` for Auto |
| iso_mode | `"auto"` (stock automatic exposure) or `"auto_shutter_priority"` (fixed shutter, ISO follows the meter between the device's min and max ISO) |
| white_balance_locked, focus_locked | Whether white balance and focus were locked for the recording |
| white_balance_gains_at_start | `[r, g, b]` gains at the start of recording |
| lens_position_at_start | Locked focus lens position (0 = near, 1 = far) |
| iso_at_start, exposure_duration_s_at_start | Exposure at the start of recording |
| iso_min, iso_max, exposure_duration_min_s, exposure_duration_max_s | Limits of the active camera format |
| exposure_control_available | `false` if the device does not support exposure control (then everything is automatic) |
| fps_divider | Every n-th camera frame was saved (1 = 60 fps, 2 = 30 fps, ...) |

Note: with a fixed shutter the ISO is still adjusted automatically while recording (in small steps, about 5 times per second) so the brightness stays usable when you move between bright and dark areas. Use the per-frame `iso` column if you need photometric consistency.

## Frame quality and markers (stray-scanner-sf fork)

`frame_quality.csv` has one row per row of `odometry.csv` (same `timestamp` and `frame`), so frames can be filtered before training:

| Field | Meaning |
|---|---|
| timestamp, frame | Same as `odometry.csv` |
| tracking_state | `normal`, `limited` or `not_available` (ARKit tracking state) |
| tracking_reason | For `limited`: `initializing`, `excessive_motion`, `insufficient_features`, `relocalizing` |
| linear_speed_mps | Camera speed in m/s (smoothed) |
| angular_speed_dps | Camera rotation speed in degrees/s (smoothed) |
| est_blur_px | Estimated motion blur in pixels of the full-size image: (rotation speed × focal length + speed × focal length / subject distance) × exposure time. Under 1.5 px is sharp, over 3 px is visibly blurred |
| median_depth_m | Median LiDAR depth of the central half of the image (0 = unknown, updated every 4th camera frame) |
| depth_confident_fraction | Share of LiDAR pixels with high confidence (0–1) |
| torch_level | Phone light brightness 0–1 as reported by the camera (it ramps, so it lags a switch by a few frames). With the light set to alternate, frames split into a lit and an unlit set |

`markers.csv` lists the points the user pinned with the pin button while recording, e.g. stops for a guided tour:

| Field | Meaning |
|---|---|
| marker | 1, 2, 3, … |
| timestamp | Time of the pin (same clock as `odometry.csv`) |
| frame | Last saved frame number when the pin was set |
| x, y, z, qx, qy, qz, qw | Camera pose at that moment, same convention as `odometry.csv` |

## Crash safety and continuing a scan (stray-scanner-sf fork)

- `rgb.mp4` is written as a fragmented MP4 (1 s fragments). If the app is killed while recording (e.g. the phone overheats), the video stays playable up to the last fragment, and the CSV/PNG files are complete up to the last saved frame. On the next launch such a scan appears in the list as "Recovered scan".
- `worldmap.arexperience` is ARKit's map of the room (`ARWorldMap`, NSKeyedArchiver), saved every 20 s and at the end. "Continue" on a scan starts a new recording that relocalizes in that map, so its `odometry.csv` poses are in the **same coordinate system** as the earlier scan. Its `capture_settings.json` then contains `"continues_scan": "<folder of the earlier scan>"` and `"relocalized_at_start"`. Start recording after the advice banner stops saying "Continuing: point at the area you scanned last".
- `capture_settings.json` also records `"torch_mode"`: `off`, `on` or `alternate_1s`.
