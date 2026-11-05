//
//  UltraWideRecordViewController.swift
//  StrayScanner
//
//  Ultra-wide video mode (stray-scanner-sf fork). ARKit only gives apps the main wide camera, so
//  this mode records the 0.5× ultra-wide camera with AVFoundation instead — no LiDAR depth and no
//  ARKit poses (SplatForge aligns it with SfM, or registers it to a LiDAR scan of the same room).
//
//  Folder content: rgb.mp4, exposure.csv, frame_quality.csv (gyro-based blur estimate),
//  intrinsics.csv (per-frame lens intrinsics from the camera), camera_matrix.csv, imu.csv
//  (same format as the LiDAR scans), attitude.csv (CoreMotion orientation), capture_settings.json.
//  All timestamps are seconds of system uptime (same clock as CoreMotion and ARKit).
//

import Foundation
import UIKit
import AVFoundation
import CoreMotion
import CoreData
import CryptoKit
import SwiftUI
import ARKit

final class UltraWideRecordViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, ARSessionDelegate {
    var dismissFunction: (() -> Void)?
    /// LiDAR scan this pass adds to. The pass is saved in <scan>/passes/uw…/ and anchored to the scan's
    /// coordinates: ARKit relocalises in the scan's world map before and after the ultra-wide recording.
    var parentScan: URL?

    private enum Phase { case idle, aligningStart, ready, recording, aligningEnd, finished }
    private var phase: Phase = .idle
    private let arSession = ARSession()
    private let arPreview = MetalPreviewView()
    private var arRenderer: ScanRenderer?
    private var normalFrames = 0
    private var alignStarted = Date()
    private var anchors: [String: Any] = [:]
    private var latestAttitude: CMQuaternion?
    private let altimeter = CMAltimeter()
    private var motionFile: FileHandle?
    private var altitudeFile: FileHandle?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "ultrawide.capture", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "ultrawide.write")
    private var device: AVCaptureDevice?
    private var exposureController = ExposureController(device: nil)
    private var shutter: ShutterSetting = ShutterSetting.load()
    private var use4K = UserDefaults.standard.bool(forKey: "UltraWide4K")
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var latestGyro = SIMD3<Double>(0, 0, 0)
    private let gyroLock = NSLock()

    // Recording state (touched on captureQueue while recording).
    private var recording = false
    private var startedAt: Date?
    private var folder: URL?
    private var videoEncoder: VideoEncoder?
    private var exposureFile: FileHandle?
    private var qualityFile: FileHandle?
    private var intrinsicsFile: FileHandle?
    private var attitudeFile: FileHandle?
    private var imuEncoder: IMUEncoder?
    private var frameIndex = 0
    private var wroteCameraMatrix = false
    private var lastBlur: Float = 0
    private var videoSize = CGSize(width: 1920, height: 1440)
    private var videoFPS = 60

    // UI
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let previewHost = UIView()
    private let closeButton = Glass.button(title: nil, symbol: "chevron.left")
    private let timerPanel = Glass.panel(cornerRadius: 18)
    private let timeLabel = UILabel()
    private let statsPanel = Glass.panel(cornerRadius: 18)
    private let statsLabel = UILabel()
    private let advicePanel = Glass.panel(cornerRadius: 20)
    private let adviceLabel = UILabel()
    private let dockPanel = Glass.panel(cornerRadius: 34)
    private let formatButton = Glass.button(title: "1440p", symbol: nil)
    private let shutterButton = Glass.button(title: "1/250", symbol: "camera.aperture")
    private let flashButton = Glass.button(title: nil, symbol: TorchMode.off.symbolName)
    // Light: same modes as LiDAR scans (off / on / alternate every second with ISO calibration).
    private var torchMode: TorchMode = .off
    private var torchIsOn = false
    private var torchTimer: Timer?
    private var torchCalibrationTimer: Timer?
    private var isoTorchOn: Float?
    private var isoTorchOff: Float?
    /// Settings copied from the parent scan (shown once, written to capture_settings.json).
    private var inheritedFromParent: [String: Any] = [:]
    private let recordButton = GlassRecordButton()
    private var uiTimer: Timer?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        buildLayout()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else { self.adviceLabel.text = "Camera access is off (Settings ▸ Stray SF)"; return }
                if self.parentScan != nil {
                    self.prepareAnchoredPass()
                } else {
                    self.configureSession()
                }
            }
        }
        uiTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if recording { stopRecording() }
        uiTimer?.invalidate()
        stopTorch()
        captureQueue.async { self.captureSession.stopRunning() }
        arSession.pause()
        altimeter.stopRelativeAltitudeUpdates()
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Camera

    private func configureSession() {
        guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            adviceLabel.text = "This phone has no ultra-wide camera"
            recordButton.isEnabled = false
            return
        }
        self.device = device
        exposureController = ExposureController(device: device)
        captureQueue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .inputPriority
            if self.captureSession.inputs.isEmpty, let input = try? AVCaptureDeviceInput(device: device), self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
            }
            if self.captureSession.outputs.isEmpty, self.captureSession.canAddOutput(self.videoOutput) {
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                self.videoOutput.alwaysDiscardsLateVideoFrames = false
                self.videoOutput.setSampleBufferDelegate(self, queue: self.captureQueue)
                self.captureSession.addOutput(self.videoOutput)
            }
            self.selectFormat(device)
            if let connection = self.videoOutput.connection(with: .video), connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.cachedTorchDevice = self.torchDevice
                self.inheritParentSettings()
                self.exposureController.apply(self.shutter)
                self.setTorchMode(self.torchMode)
                self.updateButtons()
            }
        }
    }

    /// 4:3 1920×1440 at 60 fps by default; 4K (16:9, 30 fps) when chosen.
    private func selectFormat(_ device: AVCaptureDevice) {
        var best: (format: AVCaptureDevice.Format, score: Double, fps: Int)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { continue }
            let maxFPS = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let w = Double(dims.width), h = Double(dims.height)
            var score = 0.0
            let fps: Int
            if use4K {
                guard dims.width == 3840, maxFPS >= 29 else { continue }
                fps = 30
                score = h
            } else {
                guard maxFPS >= 59, dims.width <= 1920 else { continue }
                fps = 60
                score = w * h + (abs(w / h - 4.0 / 3.0) < 0.01 ? 1e7 : 0)
            }
            if best == nil || score > best!.score { best = (format, score, fps) }
        }
        guard let chosen = best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(chosen.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(chosen.format.formatDescription)
            videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
            videoFPS = chosen.fps
        } catch {
            print("Ultra-wide: could not set format: \(error.localizedDescription)")
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let exposure = device.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0
        gyroLock.lock()
        let gyro = latestGyro
        gyroLock.unlock()
        var fx: Float = 0, fy: Float = 0, cx: Float = 0, cy: Float = 0
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            let k = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
            fx = k.columns.0.x; fy = k.columns.1.y; cx = k.columns.2.x; cy = k.columns.2.y
        }
        // Rotation blur: angular speed × focal length × exposure (pixels of the full frame).
        let angular = Float(sqrt(gyro.x * gyro.x + gyro.y * gyro.y + gyro.z * gyro.z))
        let focal = fx > 0 ? fx : Float(videoSize.width) * 0.45
        let blur = angular * focal * Float(exposure)
        lastBlur = blur
        guard recording, let encoder = videoEncoder, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let frame = frameIndex
        frameIndex += 1
        encoder.add(frame: VideoEncoderInput(buffer: pixelBuffer, time: time), currentFrame: frame)
        let number = String(format: "%06d", frame)
        let iso = device?.iso ?? 0
        let gains = device?.deviceWhiteBalanceGains
        let offset = device?.exposureTargetOffset ?? 0
        let torch = torchDevice?.torchLevel ?? 0
        writeQueue.async {
            self.exposureFile?.write("\(time), \(number), \(exposure), \(offset), \(iso), \(gains?.redGain ?? 0), \(gains?.greenGain ?? 0), \(gains?.blueGain ?? 0)\n".data(using: .utf8)!)
            self.qualityFile?.write(String(format: "%.6f, %@, no_tracking, , 0, %.2f, %.3f, 0, 0, %.2f\n", time, number, Double(angular) * 180 / Double.pi, Double(blur), Double(torch)).data(using: .utf8)!)
            if fx > 0 {
                self.intrinsicsFile?.write("\(time), \(number), \(fx), \(fy), \(cx), \(cy)\n".data(using: .utf8)!)
                if !self.wroteCameraMatrix, let folder = self.folder {
                    self.wroteCameraMatrix = true
                    try? "\(fx), 0.0, \(cx)\n0.0, \(fy), \(cy)\n0.0, 0.0, 1.0".write(to: folder.appendingPathComponent("camera_matrix.csv"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    // MARK: - Recording

    static let motionHeader = "timestamp, qx, qy, qz, qw, rot_x, rot_y, rot_z, gravity_x, gravity_y, gravity_z, user_acc_x, user_acc_y, user_acc_z, mag_x, mag_y, mag_z, mag_accuracy\n"

    // MARK: - Anchoring to the LiDAR scan

    private func prepareAnchoredPass() {
        guard let folder = makeFolder() else { return }
        self.folder = folder
        func open(_ name: String, _ header: String) -> FileHandle? {
            let url = folder.appendingPathComponent(name)
            try? header.write(to: url, atomically: true, encoding: .utf8)
            let handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            return handle
        }
        attitudeFile = open("attitude.csv", "timestamp, qx, qy, qz, qw\n")
        motionFile = open("motion.csv", UltraWideRecordViewController.motionHeader)
        altitudeFile = open("altitude.csv", "timestamp, relative_altitude_m, pressure_kpa\n")
        FileManager.default.createFile(atPath: folder.appendingPathComponent(DatasetEncoder.inProgressMarker).path, contents: nil)
        anchors["parent_scan"] = parentScan?.lastPathComponent
        anchors["attitude_reference"] = "CMAttitudeReferenceFrame.xArbitraryCorrectedZVertical (same as attitude.csv / motion.csv)"
        anchors["pose_convention"] = "arkit_c2w_colmajor: ARKit camera-to-world (camera looks -Z, y up) of the WIDE camera; odometry: x,y,z,qx,qy,qz,qw exactly like odometry.csv (OpenCV camera)"
        startMotion()   // runs through both ARKit phases and the recording, so attitude links them
        startAlignment()
    }

    private func startAlignment() {
        guard let parent = parentScan,
              let data = try? Data(contentsOf: parent.appendingPathComponent(DatasetEncoder.worldMapFileName)),
              let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            adviceLabel.text = "This scan has no saved room map — recording without anchors"
            if phase == .aligningEnd, case let (folder, started)? = pendingFinish { finishPass(folder: folder, started: started); dismissFunction?() }
            else { phase = .ready; configureSession() }
            return
        }
        if phase != .aligningEnd { phase = .aligningStart }
        normalFrames = 0
        alignStarted = Date()
        if arRenderer == nil {
            arRenderer = ScanRenderer(layer: arPreview.metalLayer)
            arRenderer?.mode = .camera
        }
        arPreview.isHidden = false
        previewHost.isHidden = true
        arSession.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = map
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        updateButtons()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        arRenderer?.render(frame: frame)
        guard phase == .aligningStart || phase == .aligningEnd else { return }
        if case .normal = frame.camera.trackingState { normalFrames += 1 } else { normalFrames = 0 }
        let waited = Date().timeIntervalSince(alignStarted)
        // Relocalised and stable for ~0.5 s → record the anchor; give up after 25 s.
        guard normalFrames >= 30 || waited > 25 else { return }
        let key = phase == .aligningStart ? "start" : "end"
        if normalFrames >= 30 { anchors[key] = anchorDictionary(frame) } else { anchors[key + "_failed"] = "not relocalised within 25 s" }
        arSession.pause()
        arPreview.isHidden = true
        previewHost.isHidden = false
        if phase == .aligningStart {
            phase = .ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.configureSession() }
        } else if case let (folder, started)? = pendingFinish {
            pendingFinish = nil
            finishPass(folder: folder, started: started)
            dismissFunction?()
        }
        updateButtons()
    }

    private func anchorDictionary(_ frame: ARFrame) -> [String: Any] {
        let m = frame.camera.transform
        let k = frame.camera.intrinsics
        let q = (simd_quatf(m) * simd_quatf(ix: 1, iy: 0, iz: 0, r: 0)).vector
        gyroLock.lock()
        let att = latestAttitude
        gyroLock.unlock()
        var d: [String: Any] = [
            "t": frame.timestamp,
            "arkit_c2w_colmajor": [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] },
            "odometry": [m.columns.3.x, m.columns.3.y, m.columns.3.z, q.x, q.y, q.z, q.w],
            "wide_intrinsics": [k.columns.0.x, k.columns.1.y, k.columns.2.x, k.columns.2.y],
            "wide_image_size": [Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)],
        ]
        if let a = att { d["attitude_q"] = [a.x, a.y, a.z, a.w] }
        return d
    }

    /// Factory transform between the wide and ultra-wide cameras (iOS 17+), row-major 4×3 [R | t], metres.
    private func wideToUltraWideExtrinsics() -> [Float]? {
        guard #available(iOS 17.0, *), let ultra = device,
              let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let data = AVCaptureDevice.extrinsicMatrix(from: wide, to: ultra),
              data.count >= MemoryLayout<matrix_float4x3>.size else { return nil }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float4x3.self) }
        return [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z] }
    }

    @objc private func recordTapped() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        if parentScan != nil && phase != .ready { return }
        guard let folder = self.folder ?? makeFolder() else { return }
        self.folder = folder
        phase = .recording
        func open(_ name: String, _ header: String) -> FileHandle? {
            let url = folder.appendingPathComponent(name)
            try? header.write(to: url, atomically: true, encoding: .utf8)
            let handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            return handle
        }
        exposureFile = open("exposure.csv", "timestamp, frame, exposure_duration_s, exposure_offset, iso, white_balance_r, white_balance_g, white_balance_b\n")
        qualityFile = open("frame_quality.csv", "timestamp, frame, tracking_state, tracking_reason, linear_speed_mps, angular_speed_dps, est_blur_px, median_depth_m, depth_confident_fraction, torch_level\n")
        intrinsicsFile = open("intrinsics.csv", "timestamp, frame, fx, fy, cx, cy\n")
        if attitudeFile == nil { attitudeFile = open("attitude.csv", "timestamp, qx, qy, qz, qw\n") }
        if motionFile == nil { motionFile = open("motion.csv", UltraWideRecordViewController.motionHeader) }
        if altitudeFile == nil { altitudeFile = open("altitude.csv", "timestamp, relative_altitude_m, pressure_kpa\n") }
        imuEncoder = IMUEncoder(url: folder.appendingPathComponent("imu.csv"))
        FileManager.default.createFile(atPath: folder.appendingPathComponent(DatasetEncoder.inProgressMarker).path, contents: nil)
        exposureController.lockForRecording()
        var settings = exposureController.captureSettings()
        settings["camera"] = "ultra_wide"
        settings["lidar"] = false
        settings["poses"] = false
        settings["video_width"] = Int(videoSize.width)
        settings["video_height"] = Int(videoSize.height)
        settings["video_fps"] = videoFPS
        settings["video_frame_offset"] = 0
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("capture_settings.json"))
        }
        if parentScan == nil { startMotion() }
        settings["parent_scan"] = parentScan?.lastPathComponent ?? NSNull()
        settings["torch_mode"] = ["off", "on", "alternate_1s"][torchMode.rawValue]
        if torchMode == .alternate, let on = isoTorchOn, let off = isoTorchOff {
            settings["iso_torch_on"] = on
            settings["iso_torch_off"] = off
        }
        if !inheritedFromParent.isEmpty { settings["inherited_from_parent"] = inheritedFromParent }
        settings["wide_to_ultrawide_extrinsics"] = wideToUltraWideExtrinsics() ?? NSNull()
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("capture_settings.json"))
        }
        let encoder = VideoEncoder(file: folder.appendingPathComponent("rgb.mp4"), width: videoSize.width, height: videoSize.height, framesPerSecond: videoFPS)
        captureQueue.async {
            self.frameIndex = 0
            self.wroteCameraMatrix = false
            self.videoEncoder = encoder
            self.recording = true
        }
        startedAt = Date()
        recordButton.isRecording = true
        updateButtons()
    }

    private func stopRecording() {
        guard let started = startedAt, let folder = folder else { return }
        startedAt = nil
        recordButton.isRecording = false
        captureQueue.sync {
            self.recording = false
            self.videoEncoder?.finishEncoding()
            self.videoEncoder = nil
        }
        if parentScan != nil {
            // Close the pass: back to ARKit to anchor the end pose in the scan's coordinates.
            phase = .aligningEnd
            stopTorch()
            captureQueue.async { self.captureSession.stopRunning() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.startAlignment() }
            pendingFinish = (folder, started)
            return
        }
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
        finishPass(folder: folder, started: started)
    }

    private var pendingFinish: (URL, Date)?

    private func finishPass(folder: URL, started: Date) {
        motion.stopDeviceMotionUpdates()
        motion.stopAccelerometerUpdates()
        motion.stopGyroUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        writeQueue.sync {
            [exposureFile, qualityFile, intrinsicsFile, attitudeFile].forEach { try? $0?.close() }
        }
        imuEncoder?.done()
        imuEncoder = nil
        exposureController.unlockAfterRecording()
        stopTorch()
        writeQueue.sync {
            try? motionFile?.close()
            try? altitudeFile?.close()
        }
        if !anchors.isEmpty, let data = try? JSONSerialization.data(withJSONObject: anchors, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("anchors.json"))
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(DatasetEncoder.inProgressMarker))
        phase = .finished
        if let parent = parentScan {
            // Part of the parent scan: uploading the scan sends the pass with it.
            if PCLinkSettings.load().autoUpload { PCUploader.shared.upload(directory: parent) }
        } else {
            saveRecording(folder: folder, started: started)
            if PCLinkSettings.load().autoUpload { PCUploader.shared.upload(directory: folder) }
        }
        updateButtons()
        dismissFunction?()
    }

    private func startMotion() {
        guard !motion.isGyroActive else { return }
        motionQueue.qualityOfService = .userInitiated
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = 1.0 / 400.0
            motion.startGyroUpdates(to: motionQueue) { data, _ in
                guard let data = data else { return }
                let rate = SIMD3<Double>(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
                self.gyroLock.lock()
                self.latestGyro = rate
                self.gyroLock.unlock()
                if let accel = self.motion.accelerometerData?.acceleration {
                    self.imuEncoder?.add(timestamp: data.timestamp, linear: simd_double3(accel.x, accel.y, accel.z), angular: simd_double3(rate.x, rate.y, rate.z))
                }
            }
        }
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 1.0 / 400.0
            motion.startAccelerometerUpdates()
        }
        if motion.isDeviceMotionAvailable {
            // Continuous across the ARKit anchors and the ultra-wide recording: attitude (gyro + gravity,
            // magnetometer-corrected yaw), bias-corrected rotation rate, gravity, user acceleration, magnetic field.
            motion.deviceMotionUpdateInterval = 1.0 / 100.0
            motion.showsDeviceMovementDisplay = true
            motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: motionQueue) { data, _ in
                guard let data = data else { return }
                let q = data.attitude.quaternion
                self.gyroLock.lock()
                self.latestAttitude = q
                self.gyroLock.unlock()
                let r = data.rotationRate, g = data.gravity, a = data.userAcceleration, m = data.magneticField.field
                let attitudeLine = "\(data.timestamp), \(q.x), \(q.y), \(q.z), \(q.w)\n"
                let motionLine = "\(data.timestamp), \(q.x), \(q.y), \(q.z), \(q.w), \(r.x), \(r.y), \(r.z), \(g.x), \(g.y), \(g.z), \(a.x), \(a.y), \(a.z), \(m.x), \(m.y), \(m.z), \(data.magneticField.accuracy.rawValue)\n"
                self.writeQueue.async {
                    self.attitudeFile?.write(attitudeLine.data(using: .utf8)!)
                    self.motionFile?.write(motionLine.data(using: .utf8)!)
                }
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: motionQueue) { data, _ in
                guard let data = data else { return }
                let line = "\(data.timestamp), \(data.relativeAltitude.doubleValue), \(data.pressure.doubleValue)\n"
                self.writeQueue.async { self.altitudeFile?.write(line.data(using: .utf8)!) }
            }
        }
    }

    private func makeFolder() -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let base = parentScan.map { $0.appendingPathComponent("passes", isDirectory: true) } ?? documents
        var hasher = SHA256()
        hasher.update(data: Data(UUID().uuidString.utf8))
        let name = "uw" + hasher.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
        let url = base.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            adviceLabel.text = "Could not create the scan folder"
            return nil
        }
    }

    private func saveRecording(folder: URL, started: Date) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let context = appDelegate.persistentContainer.viewContext
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: context)!
        let recording = Recording(entity: entity, insertInto: context)
        recording.id = UUID()
        recording.duration = Date().timeIntervalSince(started)
        recording.createdAt = started
        recording.name = "Ultra-wide"
        recording.rgbFilePath = "\(folder.lastPathComponent)/rgb.mp4"
        recording.depthFilePath = "\(folder.lastPathComponent)/depth/"
        try? context.save()
        NotificationCenter.default.post(name: NSNotification.Name("sessionsChanged"), object: nil)
    }

    // MARK: - UI

    // MARK: - Light

    /// The torch sits next to the wide camera; the ultra-wide device usually controls it too, else use the wide one.
    private var cachedTorchDevice: AVCaptureDevice?
    private var torchDevice: AVCaptureDevice? {
        if let d = cachedTorchDevice { return d }
        if let d = device, d.hasTorch { return d }
        if let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), d.hasTorch { return d }
        return nil
    }

    private func setTorchLight(_ on: Bool) {
        torchIsOn = on
        guard let d = torchDevice else { return }
        do {
            try d.lockForConfiguration()
            if on { try d.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) }
            else if d.isTorchModeSupported(.off) { d.torchMode = .off }
            d.unlockForConfiguration()
        } catch {
            print("torch: \(error)")
        }
    }

    @objc private func flashTapped() {
        setTorchMode(TorchMode(rawValue: (torchMode.rawValue + 1) % 3) ?? .off)
    }

    private func setTorchMode(_ mode: TorchMode) {
        torchMode = mode
        torchTimer?.invalidate(); torchTimer = nil
        torchCalibrationTimer?.invalidate(); torchCalibrationTimer = nil
        exposureController.freezeISO = false
        var configuration = flashButton.configuration
        configuration?.image = UIImage(systemName: mode.symbolName)
        flashButton.configuration = configuration
        flashButton.accessibilityValue = mode.title
        switch mode {
        case .off: setTorchLight(false)
        case .on: setTorchLight(true)
        case .alternate:
            // Same as LiDAR scans: meter ISO with the light off, then on, and use the lower ISO for lit frames.
            setTorchLight(false)
            isoTorchOff = nil; isoTorchOn = nil
            torchCalibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if self.isoTorchOff == nil {
                    self.isoTorchOff = self.exposureController.currentISO
                    self.setTorchLight(true)
                    return
                }
                self.isoTorchOn = self.exposureController.currentISO
                timer.invalidate()
                self.torchCalibrationTimer = nil
                self.exposureController.freezeISO = true
                self.torchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.setTorchLight(!self.torchIsOn)
                    if let iso = self.torchIsOn ? self.isoTorchOn : self.isoTorchOff { self.exposureController.setFixedISO(iso) }
                }
            }
        }
    }

    private func stopTorch() {
        torchTimer?.invalidate(); torchTimer = nil
        torchCalibrationTimer?.invalidate(); torchCalibrationTimer = nil
        exposureController.freezeISO = false
        setTorchLight(false)
    }

    /// An add-on pass records like the scan it belongs to: same shutter and same light mode.
    private func inheritParentSettings() {
        guard let parent = parentScan, inheritedFromParent.isEmpty,
              let data = try? Data(contentsOf: parent.appendingPathComponent("capture_settings.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let label = json["shutter_setting"] as? String, let s = ShutterSetting.allCases.first(where: { $0.label == label }) {
            shutter = s
            inheritedFromParent["shutter_setting"] = label
        }
        if let mode = json["torch_mode"] as? String {
            torchMode = ["off": TorchMode.off, "on": .on, "alternate_1s": .alternate][mode] ?? .off
            inheritedFromParent["torch_mode"] = mode
        }
        if !inheritedFromParent.isEmpty {
            adviceLabel.text = "Same as the scan: \(shutter.label) s · \(torchMode.title)"
        }
    }

    @objc private func shutterTapped() {
        let all = ShutterSetting.allCases
        shutter = all[((all.firstIndex(of: shutter) ?? 0) + 1) % all.count]
        shutter.save()
        exposureController.apply(shutter)
        updateButtons()
    }

    @objc private func formatTapped() {
        guard !recording else { return }
        use4K.toggle()
        UserDefaults.standard.set(use4K, forKey: "UltraWide4K")
        if let device = device {
            captureQueue.async {
                self.captureSession.beginConfiguration()
                self.selectFormat(device)
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.exposureController.apply(self.shutter)
                    self.updateButtons()
                }
            }
        }
    }

    @objc private func closeTapped() {
        guard !recording else { return }
        dismissFunction?()
    }

    private func updateButtons() {
        Glass.setTitle(shutterButton, shutter.label)
        Glass.setTitle(formatButton, use4K ? "4K 30" : "1440p 60")
        let aligning = phase == .aligningStart || phase == .aligningEnd
        shutterButton.isEnabled = !recording && !aligning && exposureController.isAvailable
        flashButton.isEnabled = !recording && !aligning && torchDevice != nil
        formatButton.isEnabled = !recording && !aligning
        closeButton.isEnabled = !recording && phase != .aligningEnd
        recordButton.isEnabled = !aligning
        previewLayer.videoGravity = .resizeAspect
    }

    @objc private func tick() {
        if let started = startedAt {
            let s = Int(Date().timeIntervalSince(started))
            timeLabel.text = String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        } else {
            timeLabel.text = "00:00:00"
        }
        let exposure = device.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0
        let iso = device?.iso ?? 0
        let shutterText = exposure > 0 ? "1/\(Int((1 / exposure).rounded())) s" : "–"
        statsLabel.text = String(format: "Ultra-wide %d×%d @ %d · %@ · ISO %.0f\nBlur %.1f px · no LiDAR / no poses (SfM on the PC) · %d frames",
                                 Int(videoSize.width), Int(videoSize.height), videoFPS, shutterText, iso, lastBlur, frameIndex)
        let level: ScanAdvice.Level
        if phase == .aligningStart || phase == .aligningEnd {
            adviceLabel.text = phase == .aligningStart
                ? "Lining up with the LiDAR scan — point at what you scanned"
                : "Closing the pass — point at the scanned room again"
            Glass.setTint(advicePanel, UIColor.systemBlue.withAlphaComponent(0.35))
            return
        }
        if lastBlur > ScanQualityMonitor.blurBadLimit {
            adviceLabel.text = String(format: "Slow down — blur %.1f px", lastBlur)
            level = .bad
        } else if lastBlur > ScanQualityMonitor.blurGoodLimit {
            adviceLabel.text = String(format: "A bit slower — blur %.1f px", lastBlur)
            level = .warning
        } else {
            adviceLabel.text = recording ? "Good pace — keep 60–80 % overlap between views" : "Ultra-wide: great for tight rooms and ceilings"
            level = .good
        }
        let tint: UIColor = level == .bad ? UIColor.systemRed.withAlphaComponent(0.55)
            : (level == .warning ? UIColor.systemOrange.withAlphaComponent(0.45) : UIColor.systemGreen.withAlphaComponent(0.3))
        Glass.setTint(advicePanel, tint)
    }

    private func buildLayout() {
        previewHost.translatesAutoresizingMaskIntoConstraints = false
        previewHost.layer.addSublayer(previewLayer)
        previewLayer.session = captureSession
        previewLayer.videoGravity = .resizeAspect
        view.addSubview(previewHost)
        arPreview.translatesAutoresizingMaskIntoConstraints = false
        arPreview.isHidden = true
        view.addSubview(arPreview)

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.accessibilityLabel = "Back"
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timeLabel.textColor = .white
        timerPanel.contentView.addSubview(timeLabel)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.numberOfLines = 0
        statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statsLabel.textColor = .white
        statsPanel.contentView.addSubview(statsLabel)
        adviceLabel.translatesAutoresizingMaskIntoConstraints = false
        adviceLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        adviceLabel.textColor = .white
        adviceLabel.adjustsFontSizeToFitWidth = true
        advicePanel.contentView.addSubview(adviceLabel)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        formatButton.addTarget(self, action: #selector(formatTapped), for: .touchUpInside)
        flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
        flashButton.accessibilityLabel = "Light"
        let row = UIStackView(arrangedSubviews: [formatButton, flashButton, recordButton, shutterButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalCentering
        dockPanel.contentView.addSubview(row)
        [statsPanel, advicePanel, dockPanel, closeButton, timerPanel].forEach { view.addSubview($0) }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previewHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewHost.topAnchor.constraint(equalTo: safe.topAnchor),
            previewHost.heightAnchor.constraint(equalTo: previewHost.widthAnchor, multiplier: 4.0 / 3.0),
            arPreview.leadingAnchor.constraint(equalTo: previewHost.leadingAnchor),
            arPreview.trailingAnchor.constraint(equalTo: previewHost.trailingAnchor),
            arPreview.topAnchor.constraint(equalTo: previewHost.topAnchor),
            arPreview.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            timerPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            timerPanel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            timerPanel.heightAnchor.constraint(equalToConstant: 36),
            timeLabel.leadingAnchor.constraint(equalTo: timerPanel.contentView.leadingAnchor, constant: 14),
            timeLabel.trailingAnchor.constraint(equalTo: timerPanel.contentView.trailingAnchor, constant: -14),
            timeLabel.centerYAnchor.constraint(equalTo: timerPanel.contentView.centerYAnchor),
            statsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            statsPanel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            statsLabel.leadingAnchor.constraint(equalTo: statsPanel.contentView.leadingAnchor, constant: 14),
            statsLabel.trailingAnchor.constraint(equalTo: statsPanel.contentView.trailingAnchor, constant: -14),
            statsLabel.topAnchor.constraint(equalTo: statsPanel.contentView.topAnchor, constant: 8),
            statsLabel.bottomAnchor.constraint(equalTo: statsPanel.contentView.bottomAnchor, constant: -8),
            advicePanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            advicePanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            advicePanel.bottomAnchor.constraint(equalTo: previewHost.bottomAnchor, constant: -10),
            adviceLabel.leadingAnchor.constraint(equalTo: advicePanel.contentView.leadingAnchor, constant: 14),
            adviceLabel.trailingAnchor.constraint(equalTo: advicePanel.contentView.trailingAnchor, constant: -14),
            adviceLabel.topAnchor.constraint(equalTo: advicePanel.contentView.topAnchor, constant: 10),
            adviceLabel.bottomAnchor.constraint(equalTo: advicePanel.contentView.bottomAnchor, constant: -10),
            dockPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            dockPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            dockPanel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: dockPanel.contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: dockPanel.contentView.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: dockPanel.contentView.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: dockPanel.contentView.trailingAnchor, constant: -18),
            recordButton.widthAnchor.constraint(equalToConstant: 82),
            recordButton.heightAnchor.constraint(equalToConstant: 82),
            formatButton.widthAnchor.constraint(equalToConstant: 96),
            shutterButton.widthAnchor.constraint(equalToConstant: 96),
            flashButton.widthAnchor.constraint(equalToConstant: 52),
            flashButton.heightAnchor.constraint(equalToConstant: 52),
        ])
        updateButtons()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = previewHost.bounds
    }
}

/// SwiftUI entry for the ultra-wide mode.

struct UltraWideSessionView: View {
    @Environment(\.dismiss) private var dismiss
    var parentScan: URL? = nil

    var body: some View {
        UltraWideRepresentable(parentScan: parentScan, onDone: { dismiss() })
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
    }
}

private struct UltraWideRepresentable: UIViewControllerRepresentable {
    let parentScan: URL?
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> UltraWideRecordViewController {
        let controller = UltraWideRecordViewController()
        controller.parentScan = parentScan
        controller.dismissFunction = onDone
        return controller
    }

    func updateUIViewController(_ controller: UltraWideRecordViewController, context: Context) {}
}
