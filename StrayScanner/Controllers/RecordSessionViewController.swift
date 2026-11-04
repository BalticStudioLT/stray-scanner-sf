//
//  RecordSessionViewController.swift
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//
//  stray-scanner-sf: record screen rebuilt in code with Liquid Glass controls, view modes
//  (camera / depth / mix / point cloud / dim), live scan statistics and guidance.
//  Recording itself (DatasetEncoder, IMU, file formats) works exactly as before.
//

import Foundation
import UIKit
import Metal
import ARKit
import CoreData
import CoreMotion

let FpsDividers: [Int] = [1, 2, 4, 12, 60]
let AvailableFpsSettings: [Int] = FpsDividers.map { Int(60 / $0) }
let FpsUserDefaultsKey: String = "FPS"

class MetalView : UIView {
    override class var layerClass: AnyClass {
        get {
            return CAMetalLayer.self
        }
    }
    override var layer: CAMetalLayer {
        return super.layer as! CAMetalLayer
    }
}

enum TorchMode: Int {
    case off = 0, on = 1, alternate = 2
    var symbolName: String {
        switch self {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .alternate: return "bolt.horizontal.fill"
        }
    }
    var title: String {
        switch self {
        case .off: return "Light off"
        case .on: return "Light on"
        case .alternate: return "Light on/off every second (two light setups)"
        }
    }
}

class RecordSessionViewController : UIViewController, ARSessionDelegate {
    /// Folder of an earlier scan to continue in the same coordinates (its saved ARKit world map is loaded).
    var continueFrom: URL?
    private var relocalized = false
    private var unsupported: Bool = false
    private var arConfiguration: ARWorldTrackingConfiguration?
    private let session = ARSession()
    private let motionManager = CMMotionManager()
    private var renderer: ScanRenderer?
    private var uiTimer: Timer?
    private var startedRecording: Date?
    private var dataContext: NSManagedObjectContext!
    private var datasetEncoder: DatasetEncoder?
    private let imuOperationQueue = OperationQueue()
    private var chosenFpsSetting: Int = 0
    private let exposureController = ExposureController()
    private var chosenShutterSetting: ShutterSetting = ShutterSetting.defaultSetting
    private let qualityMonitor = ScanQualityMonitor()
    private var viewMode: ViewMode = .camera
    private var lastFrame: ARFrame?
    private var savedBrightness: CGFloat?
    private var statsExpanded = true
    private var lastAdvice: ScanAdvice?
    private var lastHaptic = Date.distantPast
    private var datasetBytes: Int64 = 0
    private var freeBytes: Int64?
    private var bytesPerSecond: Double = 0
    private var sizeCheckRunning = false
    private var lastSizeCheck = Date.distantPast
    private let wallGuide = WallSweepGuide()
    private var torchMode: TorchMode = .off
    private var torchTimer: Timer?
    private var torchIsOn = false
    private var worldMapTimer: Timer?
    private var autoDimmedForHeat = false
    private var cpuUsage: Double = 0
    private var frameCounter = 0
    var dismissFunction: Optional<() -> Void> = Optional.none

    // MARK: Views
    private let previewView = MetalPreviewView()
    private let closeButton = Glass.button(title: nil, symbol: "chevron.left")
    private let timerPanel = Glass.panel(cornerRadius: 18)
    private let timerDot = UIView()
    private let timeLabel = UILabel()
    private let trackingDot = UIView()
    private let layersButton = Glass.button(title: nil, symbol: "square.3.layers.3d")
    private let flashButton = Glass.button(title: nil, symbol: "bolt.slash.fill")
    private let cameraInset = MetalPreviewView()
    private let depthInset = MetalPreviewView()
    private let minimapInset = MetalPreviewView()
    private let insetStack = UIStackView()
    private let statsPanel = Glass.panel(cornerRadius: 20)
    private let statsLabel = UILabel()
    private let coverageRing = CoverageRingView()
    private let advicePanel = Glass.panel(cornerRadius: 22)
    private let adviceIcon = UIImageView()
    private let adviceLabel = UILabel()
    private let blurMeter = UIProgressView(progressViewStyle: .bar)
    private let pinButton = Glass.button(title: nil, symbol: "mappin.and.ellipse")
    private let pointHintLabel = UILabel()
    private let dockPanel = Glass.panel(cornerRadius: 34)
    private let modeControl = UISegmentedControl()
    private let fpsButton = Glass.button(title: "60 fps", symbol: nil)
    private let shutterButton = Glass.button(title: "1/250 s", symbol: "camera.aperture")
    private let recordButton = GlassRecordButton()

    func setDismissFunction(_ fn: Optional<() -> Void>) {
        self.dismissFunction = fn
    }

    // MARK: - Lifecycle

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root
        buildLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        self.dataContext = appDelegate.persistentContainer.newBackgroundContext()
        self.renderer = ScanRenderer(layer: previewView.metalLayer)
        session.delegate = self
        imuOperationQueue.qualityOfService = .userInitiated
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    override var prefersStatusBarHidden: Bool { return false }
    override var preferredStatusBarStyle: UIStatusBarStyle { return .lightContent }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        chosenFpsSetting = UserDefaults.standard.integer(forKey: FpsUserDefaultsKey)
        chosenShutterSetting = ShutterSetting.load()
        updateFpsSetting()
        updateShutterButton()
        setViewMode(ViewMode.load(), save: false)
        applyInsetSettings()
        renderer?.showCoverage = UserDefaults.standard.bool(forKey: "ShowCoverage")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        startSession()
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(uiTick), userInfo: nil, repeats: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        uiTimer?.invalidate()
        uiTimer = nil
        setTorchMode(.off)
        restoreBrightness()
        UIApplication.shared.isIdleTimerDisabled = false
        datasetEncoder = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.pause()
    }

    private func startSession() {
        let config = ARWorldTrackingConfiguration()
        arConfiguration = config
        if !ARWorldTrackingConfiguration.isSupported || !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("AR is not supported.")
            unsupported = true
        } else {
            config.frameSemantics.insert(.sceneDepth)
            config.planeDetection = [.vertical]
            if let folder = continueFrom,
               let data = try? Data(contentsOf: folder.appendingPathComponent(DatasetEncoder.worldMapFileName)),
               let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                config.initialWorldMap = map
            }
            session.run(config)
            // Apply the shutter after the session has configured the camera.
            exposureController.apply(chosenShutterSetting)
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        view.addSubview(previewView)
        previewView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(previewTapped)))

        // Top bar: back, timer, tracking state.
        closeButton.accessibilityLabel = "Back"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        trackingDot.translatesAutoresizingMaskIntoConstraints = false
        trackingDot.backgroundColor = .systemYellow
        trackingDot.layer.cornerRadius = 5
        timerPanel.contentView.addSubview(trackingDot)
        configurePill(timerPanel, dot: timerDot, label: timeLabel, dotColor: UIColor(white: 1, alpha: 0.5), text: "00:00:00")
        layersButton.accessibilityLabel = "Views and path guide"
        layersButton.showsMenuAsPrimaryAction = true
        layersButton.menu = makeLayersMenu()
        flashButton.accessibilityLabel = "Light"
        flashButton.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
        if !exposureController.hasTorch { flashButton.isEnabled = false }

        // Small views (camera, LiDAR, minimap), shown from the views menu.
        insetStack.translatesAutoresizingMaskIntoConstraints = false
        insetStack.axis = .vertical
        insetStack.spacing = 8
        insetStack.alignment = .trailing
        for (inset, name) in [(cameraInset, "Camera"), (depthInset, "LiDAR depth"), (minimapInset, "Minimap")] {
            inset.translatesAutoresizingMaskIntoConstraints = false
            inset.layer.cornerRadius = 14
            inset.layer.cornerCurve = .continuous
            inset.layer.borderWidth = 1
            inset.layer.borderColor = UIColor(white: 1, alpha: 0.35).cgColor
            inset.clipsToBounds = true
            inset.isHidden = true
            inset.accessibilityLabel = name
            insetStack.addArrangedSubview(inset)
        }

        // Stats card with direction ring.
        statsLabel.numberOfLines = 0
        statsLabel.textColor = .white
        statsLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        coverageRing.translatesAutoresizingMaskIntoConstraints = false
        statsPanel.contentView.addSubview(statsLabel)
        statsPanel.contentView.addSubview(coverageRing)
        statsPanel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(statsTapped)))

        // Advice banner with blur meter.
        adviceIcon.translatesAutoresizingMaskIntoConstraints = false
        adviceIcon.tintColor = .white
        adviceIcon.contentMode = .scaleAspectFit
        adviceLabel.translatesAutoresizingMaskIntoConstraints = false
        adviceLabel.textColor = .white
        adviceLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        adviceLabel.numberOfLines = 2
        adviceLabel.adjustsFontSizeToFitWidth = true
        adviceLabel.minimumScaleFactor = 0.8
        blurMeter.translatesAutoresizingMaskIntoConstraints = false
        blurMeter.trackTintColor = UIColor(white: 1, alpha: 0.15)
        blurMeter.layer.cornerRadius = 2
        blurMeter.clipsToBounds = true
        advicePanel.contentView.addSubview(adviceIcon)
        advicePanel.contentView.addSubview(adviceLabel)
        advicePanel.contentView.addSubview(blurMeter)

        pinButton.accessibilityLabel = "Pin this spot"
        pinButton.addTarget(self, action: #selector(pinTapped), for: .touchUpInside)
        pinButton.isEnabled = false

        pointHintLabel.translatesAutoresizingMaskIntoConstraints = false
        pointHintLabel.text = "Tap to switch view"
        pointHintLabel.textColor = UIColor(white: 1, alpha: 0.6)
        pointHintLabel.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        pointHintLabel.isHidden = true

        // Bottom dock: view modes, fps, record, shutter.
        for mode in ViewMode.allCases {
            let image = UIImage(systemName: mode.symbolName)
            image?.accessibilityLabel = mode.title
            modeControl.insertSegment(with: image, at: mode.rawValue, animated: false)
        }
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentTintColor = UIColor(white: 1, alpha: 0.3)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        fpsButton.addTarget(self, action: #selector(fpsButtonTapped), for: .touchUpInside)
        fpsButton.accessibilityLabel = "Frame rate"
        shutterButton.addTarget(self, action: #selector(shutterButtonTapped), for: .touchUpInside)
        shutterButton.accessibilityLabel = "Shutter speed"
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)

        let modeTitle = UILabel()
        modeTitle.translatesAutoresizingMaskIntoConstraints = false
        modeTitle.tag = 501
        modeTitle.textColor = UIColor(white: 1, alpha: 0.75)
        modeTitle.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        modeTitle.textAlignment = .center

        let controlsRow = UIStackView(arrangedSubviews: [fpsButton, recordButton, shutterButton])
        controlsRow.translatesAutoresizingMaskIntoConstraints = false
        controlsRow.axis = .horizontal
        controlsRow.alignment = .center
        controlsRow.distribution = .equalCentering

        dockPanel.contentView.addSubview(modeControl)
        dockPanel.contentView.addSubview(modeTitle)
        dockPanel.contentView.addSubview(controlsRow)

        [insetStack, statsPanel, advicePanel, pinButton, pointHintLabel, dockPanel, closeButton, layersButton, flashButton, timerPanel].forEach { view.addSubview($0) }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: safe.topAnchor),
            previewView.heightAnchor.constraint(equalTo: previewView.widthAnchor, multiplier: 4.0 / 3.0),

            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            closeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            layersButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            layersButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            layersButton.widthAnchor.constraint(equalToConstant: 44),
            layersButton.heightAnchor.constraint(equalToConstant: 44),
            flashButton.leadingAnchor.constraint(equalTo: layersButton.trailingAnchor, constant: 8),
            flashButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            flashButton.widthAnchor.constraint(equalToConstant: 44),
            flashButton.heightAnchor.constraint(equalToConstant: 44),

            timerPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            timerPanel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            timerPanel.heightAnchor.constraint(equalToConstant: 36),

            insetStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            insetStack.topAnchor.constraint(equalTo: statsPanel.bottomAnchor, constant: 8),
            cameraInset.widthAnchor.constraint(equalToConstant: 96),
            cameraInset.heightAnchor.constraint(equalToConstant: 128),
            depthInset.widthAnchor.constraint(equalToConstant: 96),
            depthInset.heightAnchor.constraint(equalToConstant: 128),
            minimapInset.widthAnchor.constraint(equalToConstant: 128),
            minimapInset.heightAnchor.constraint(equalToConstant: 128),

            statsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            statsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            statsPanel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 10),
            statsLabel.leadingAnchor.constraint(equalTo: statsPanel.contentView.leadingAnchor, constant: 14),
            statsLabel.topAnchor.constraint(equalTo: statsPanel.contentView.topAnchor, constant: 10),
            statsLabel.bottomAnchor.constraint(equalTo: statsPanel.contentView.bottomAnchor, constant: -10),
            statsLabel.trailingAnchor.constraint(equalTo: coverageRing.leadingAnchor, constant: -10),
            coverageRing.trailingAnchor.constraint(equalTo: statsPanel.contentView.trailingAnchor, constant: -12),
            coverageRing.centerYAnchor.constraint(equalTo: statsPanel.contentView.centerYAnchor),
            coverageRing.widthAnchor.constraint(equalToConstant: 54),
            coverageRing.heightAnchor.constraint(equalToConstant: 54),
            statsPanel.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),

            advicePanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            advicePanel.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -8),
            advicePanel.bottomAnchor.constraint(equalTo: previewView.bottomAnchor, constant: -10),
            adviceIcon.leadingAnchor.constraint(equalTo: advicePanel.contentView.leadingAnchor, constant: 14),
            adviceIcon.centerYAnchor.constraint(equalTo: adviceLabel.centerYAnchor),
            adviceIcon.widthAnchor.constraint(equalToConstant: 22),
            adviceIcon.heightAnchor.constraint(equalToConstant: 22),
            adviceLabel.leadingAnchor.constraint(equalTo: adviceIcon.trailingAnchor, constant: 10),
            adviceLabel.trailingAnchor.constraint(equalTo: advicePanel.contentView.trailingAnchor, constant: -14),
            adviceLabel.topAnchor.constraint(equalTo: advicePanel.contentView.topAnchor, constant: 10),
            blurMeter.leadingAnchor.constraint(equalTo: adviceLabel.leadingAnchor),
            blurMeter.trailingAnchor.constraint(equalTo: adviceLabel.trailingAnchor),
            blurMeter.topAnchor.constraint(equalTo: adviceLabel.bottomAnchor, constant: 6),
            blurMeter.heightAnchor.constraint(equalToConstant: 4),
            blurMeter.bottomAnchor.constraint(equalTo: advicePanel.contentView.bottomAnchor, constant: -10),

            pinButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            pinButton.centerYAnchor.constraint(equalTo: advicePanel.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 52),
            pinButton.heightAnchor.constraint(equalToConstant: 52),

            pointHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pointHintLabel.bottomAnchor.constraint(equalTo: advicePanel.topAnchor, constant: -6),

            dockPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            dockPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            dockPanel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -6),
            modeControl.topAnchor.constraint(equalTo: dockPanel.contentView.topAnchor, constant: 14),
            modeControl.leadingAnchor.constraint(equalTo: dockPanel.contentView.leadingAnchor, constant: 16),
            modeControl.trailingAnchor.constraint(equalTo: dockPanel.contentView.trailingAnchor, constant: -16),
            modeControl.heightAnchor.constraint(equalToConstant: 34),
            modeTitle.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 4),
            modeTitle.centerXAnchor.constraint(equalTo: dockPanel.contentView.centerXAnchor),
            controlsRow.topAnchor.constraint(equalTo: modeTitle.bottomAnchor, constant: 6),
            controlsRow.leadingAnchor.constraint(equalTo: dockPanel.contentView.leadingAnchor, constant: 18),
            controlsRow.trailingAnchor.constraint(equalTo: dockPanel.contentView.trailingAnchor, constant: -18),
            controlsRow.bottomAnchor.constraint(equalTo: dockPanel.contentView.bottomAnchor, constant: -14),
            recordButton.widthAnchor.constraint(equalToConstant: 82),
            recordButton.heightAnchor.constraint(equalToConstant: 82),
            fpsButton.widthAnchor.constraint(equalToConstant: 104),
            shutterButton.widthAnchor.constraint(equalToConstant: 104),
        ])
        // Keep the dock below the preview when there is room; on short screens it may overlap it.
        let gap = dockPanel.topAnchor.constraint(greaterThanOrEqualTo: previewView.bottomAnchor, constant: 10)
        gap.priority = .defaultHigh
        gap.isActive = true
        updateStatsText()
        applyAdvice(ScanAdvice(level: .info, text: "Starting camera…", symbolName: "camera.fill"))
    }

    private func configurePill(_ panel: UIVisualEffectView, dot: UIView, label: UILabel, dotColor: UIColor, text: String) {
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = dotColor
        dot.layer.cornerRadius = 5
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .white
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        panel.contentView.addSubview(dot)
        panel.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: panel.contentView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: panel.contentView.centerYAnchor),
        ])
        if panel === timerPanel {
            NSLayoutConstraint.activate([
                trackingDot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
                trackingDot.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -12),
                trackingDot.centerYAnchor.constraint(equalTo: panel.contentView.centerYAnchor),
                trackingDot.widthAnchor.constraint(equalToConstant: 10),
                trackingDot.heightAnchor.constraint(equalToConstant: 10),
            ])
        } else {
            label.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -12).isActive = true
        }
    }

    // MARK: - IMU

    private func startRawIMU() {
        if self.motionManager.isAccelerometerAvailable {
            self.motionManager.accelerometerUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startAccelerometerUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving accelerometer data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawAccelerometer(data: data)
            }
        } else {
            print("Accelerometer not available on this device.")
        }

        if self.motionManager.isGyroAvailable {
            self.motionManager.gyroUpdateInterval = 1.0 / 1200.0 // Set update rate
            self.motionManager.startGyroUpdates(to: imuOperationQueue) { (data, error) in
                guard let data = data else {
                    if let error = error {
                        print("Error retrieving gyroscope data: \(error.localizedDescription)")
                    }
                    return
                }
                self.datasetEncoder?.addRawGyroscope(data: data)
            }
        } else {
            print("Gyroscope not available on this device.")
        }
    }

    private func stopRawIMU() {
        if self.motionManager.isAccelerometerActive {
            self.motionManager.stopAccelerometerUpdates()
            print("Stopped accelerometer updates.")
        }
        if self.motionManager.isGyroActive {
            self.motionManager.stopGyroUpdates()
            print("Stopped gyroscope updates.")
        }
    }

    // MARK: - Recording

    @objc private func recordTapped() {
        if unsupported {
            showUnsupportedAlert()
            return
        }
        if startedRecording == nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        self.startedRecording = Date()
        recordButton.isRecording = true
        qualityMonitor.resetForRecording()
        renderer?.resetPointCloud()
        datasetBytes = 0
        bytesPerSecond = 0
        exposureController.lockForRecording()
        shutterButton.isEnabled = false
        fpsButton.isEnabled = false
        closeButton.isEnabled = false
        pinButton.isEnabled = true
        timerDot.backgroundColor = .systemRed
        datasetEncoder = DatasetEncoder(arConfiguration: arConfiguration!, fpsDivider: FpsDividers[chosenFpsSetting], exposureController: exposureController)
        var settings = exposureController.captureSettings()
        settings["torch_mode"] = ["off", "on", "alternate_1s"][torchMode.rawValue]
        if let folder = continueFrom {
            settings["continues_scan"] = folder.lastPathComponent
            settings["relocalized_at_start"] = relocalized
        }
        datasetEncoder?.writeCaptureSettings(settings)
        worldMapTimer?.invalidate()
        worldMapTimer = Timer.scheduledTimer(timeInterval: 20, target: self, selector: #selector(saveWorldMap), userInfo: nil, repeats: true)
        startRawIMU()
        updateTime()
    }

    private func stopRecording() {
        guard let started = self.startedRecording else {
            print("Hasn't started recording. Something is wrong.")
            return
        }
        startedRecording = nil
        recordButton.isRecording = false
        worldMapTimer?.invalidate()
        worldMapTimer = nil
        saveWorldMap()
        // Stop IMU updates
        stopRawIMU()
        datasetEncoder?.wrapUp()
        exposureController.unlockAfterRecording()
        shutterButton.isEnabled = true
        fpsButton.isEnabled = true
        closeButton.isEnabled = true
        pinButton.isEnabled = false
        timerDot.backgroundColor = UIColor(white: 1, alpha: 0.5)
        if let encoder = datasetEncoder {
            switch encoder.status {
                case .allGood:
                    saveRecording(started, encoder)
                case .videoEncodingError:
                    showError()
                case .directoryCreationError:
                    showError()
            }
        } else {
            print("No dataset encoder. Something is wrong.")
        }
        restoreBrightness()
        self.dismissFunction?()
    }

    private func saveRecording(_ started: Date, _ encoder: DatasetEncoder) {
        let sessionCount = countSessions()

        let duration = Date().timeIntervalSince(started)
        let entity = NSEntityDescription.entity(forEntityName: "Recording", in: self.dataContext)!
        let recording: Recording = Recording(entity: entity, insertInto: self.dataContext)
        recording.setValue(datasetEncoder!.id, forKey: "id")
        recording.setValue(duration, forKey: "duration")
        recording.setValue(started, forKey: "createdAt")
        recording.setValue("Recording \(sessionCount)", forKey: "name")
        recording.setValue(datasetEncoder!.rgbFilePath.relativeString, forKey: "rgbFilePath")
        recording.setValue(datasetEncoder!.depthFilePath.relativeString, forKey: "depthFilePath")
        do {
            try self.dataContext.save()
        } catch let error as NSError {
            print("Could not save recording. \(error), \(error.userInfo)")
        }
    }

    private func showError() {
        let controller = UIAlertController(title: "Error",
            message: "Something went wrong when encoding video. This should not have happened. You might want to file a bug report.",
            preferredStyle: .alert)
        controller.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Default Action"), style: .default, handler: { _ in
            self.dismiss(animated: true, completion: nil)
        }))
        self.present(controller, animated: true, completion: nil)
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        guard startedRecording == nil else { return }
        dismissFunction?()
    }

    @objc private func pinTapped() {
        guard startedRecording != nil, let frame = lastFrame, let encoder = datasetEncoder else { return }
        encoder.addMarker(frame: frame)
        if #available(iOS 17.5, *) {
            UIImpactFeedbackGenerator(style: .medium, view: view).impactOccurred()
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        updateStatsText()
    }

    @objc private func previewTapped() {
        guard viewMode == .pointCloud, let renderer = renderer else { return }
        renderer.chaseCamera.toggle()
        pointHintLabel.text = renderer.chaseCamera ? "Overview · tap for camera view" : "Camera view · tap for overview"
    }

    @objc private func statsTapped() {
        statsExpanded.toggle()
        updateStatsText()
    }

    @objc private func modeChanged() {
        if let mode = ViewMode(rawValue: modeControl.selectedSegmentIndex) {
            setViewMode(mode, save: true)
        }
    }

    private func setViewMode(_ mode: ViewMode, save: Bool) {
        viewMode = mode
        renderer?.mode = mode
        modeControl.selectedSegmentIndex = mode.rawValue
        if let title = view.viewWithTag(501) as? UILabel {
            title.text = mode == .dim ? "Dim · screen off to save battery" : mode.title
        }
        pointHintLabel.isHidden = mode != .pointCloud
        if mode == .pointCloud, let renderer = renderer {
            pointHintLabel.text = renderer.chaseCamera ? "Overview · tap for camera view" : "Camera view · tap for overview"
        }
        if mode == .dim {
            let screen = view.window?.windowScene?.screen
            if savedBrightness == nil { savedBrightness = screen?.brightness }
            screen?.brightness = 0.05
            statsPanel.alpha = 0.6
            dockPanel.alpha = 0.6
        } else {
            restoreBrightness()
            statsPanel.alpha = 1
            dockPanel.alpha = 1
        }
        if save { mode.save() }
    }

    private func restoreBrightness() {
        if let brightness = savedBrightness {
            view.window?.windowScene?.screen.brightness = brightness
            savedBrightness = nil
        }
    }

    @objc func fpsButtonTapped() {
        chosenFpsSetting = (chosenFpsSetting + 1) % AvailableFpsSettings.count
        updateFpsSetting()
        UserDefaults.standard.set(chosenFpsSetting, forKey: FpsUserDefaultsKey)
    }

    @objc func shutterButtonTapped() {
        let all = ShutterSetting.allCases
        let index = all.firstIndex(of: chosenShutterSetting) ?? 0
        chosenShutterSetting = all[(index + 1) % all.count]
        chosenShutterSetting.save()
        updateShutterButton()
        exposureController.apply(chosenShutterSetting)
    }

    private func updateFpsSetting() {
        Glass.setTitle(fpsButton, "\(AvailableFpsSettings[chosenFpsSetting]) fps")
    }

    private func updateShutterButton() {
        let label = exposureController.isAvailable ? chosenShutterSetting.label : ShutterSetting.auto.label
        Glass.setTitle(shutterButton, label == "Auto" ? "Auto" : label)
        if !exposureController.isAvailable {
            shutterButton.isEnabled = false
        }
    }

    // MARK: - Frames

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lastFrame = frame
        let recording = startedRecording != nil
        frameCounter += 1
        qualityMonitor.update(frame: frame, recording: recording)
        if case .normal = frame.camera.trackingState { relocalized = true }
        if wallGuide.isActive {
            wallGuide.update(frame: frame)
            if frameCounter % 3 == 0 { renderer?.guideVertices = wallGuide.vertices() }
        } else if !(renderer?.guideVertices.isEmpty ?? true) {
            renderer?.guideVertices = []
        }
        renderer?.render(frame: frame)
        if recording {
            if let encoder = datasetEncoder {
                var quality = qualityMonitor.currentQuality()
                quality.torchLevel = exposureController.torchLevel
                encoder.add(frame: frame, quality: quality)
            } else {
                print("There is no video encoder. That can't be good.")
            }
        }
    }

    // MARK: - HUD

    @objc private func uiTick() {
        updateTime()
        updateTracking()
        updateStatsText()
        coverageRing.update(covered: qualityMonitor.coveredSectors, current: qualityMonitor.headingSector)
        let seconds = startedRecording.map { Date().timeIntervalSince($0) } ?? 0
        let thermal = ProcessInfo.processInfo.thermalState
        handleHeat(thermal)
        var advice = qualityMonitor.advice(recording: startedRecording != nil,
                                           recordingSeconds: seconds,
                                           underexposed: exposureController.isUnderexposed && torchMode == .off,
                                           thermalState: thermal,
                                           freeMinutes: freeMinutes)
        if advice.level.rawValue < ScanAdvice.Level.warning.rawValue {
            if continueFrom != nil && !relocalized {
                advice = ScanAdvice(level: .warning, text: "Continuing: point at the area you scanned last to line up", symbolName: "arrow.triangle.2.circlepath")
            } else if let guide = wallGuide.advice() {
                advice = guide
            }
        }
        applyAdvice(advice)
        let blurRatio = qualityMonitor.blurPixels / ScanQualityMonitor.blurBadLimit
        blurMeter.setProgress(min(max(blurRatio, 0.02), 1), animated: true)
        blurMeter.progressTintColor = qualityMonitor.blurPixels > ScanQualityMonitor.blurBadLimit ? .systemRed
            : (qualityMonitor.blurPixels > ScanQualityMonitor.blurGoodLimit ? .systemYellow : .systemGreen)
        refreshStorage()
    }

    private func updateTime() {
        guard let started = self.startedRecording else {
            timeLabel.text = "00:00:00"
            return
        }
        let seconds = Date().timeIntervalSince(started)
        let minutes: Int = Int(floor(seconds / 60).truncatingRemainder(dividingBy: 60))
        let hours: Int = Int(floor(seconds / 3600))
        let roundSeconds: Int = Int(floor(seconds.truncatingRemainder(dividingBy: 60)))
        timeLabel.text = String(format: "%02d:%02d:%02d", hours, minutes, roundSeconds)
    }

    private func updateTracking() {
        switch qualityMonitor.trackingState {
        case .normal:
            trackingDot.backgroundColor = .systemGreen
        case .limited:
            trackingDot.backgroundColor = .systemYellow
        case .notAvailable:
            trackingDot.backgroundColor = .systemRed
        }
    }

    // MARK: - Heat

    private func handleHeat(_ state: ProcessInfo.ThermalState) {
        if frameCounter % 4 == 0 || cpuUsage == 0 { cpuUsage = RecordSessionViewController.appCPUUsage() }
        let hot = state == .serious || state == .critical
        renderer?.lowPower = hot
        if state == .critical && !autoDimmedForHeat && viewMode != .dim {
            autoDimmedForHeat = true
            setViewMode(.dim, save: false)
            if torchMode != .off { setTorchMode(.off) }
        }
    }

    /// CPU used by this app, in percent of one core (can exceed 100 on several cores).
    private static func appCPUUsage() -> Double {
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threadList = threads else { return 0 }
        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        return total
    }

    // MARK: - World map (continue after a crash)

    @objc private func saveWorldMap() {
        guard let directory = datasetEncoder?.directory else { return }
        session.getCurrentWorldMap { map, error in
            guard let map = map else {
                if let error = error { print("World map not available: \(error.localizedDescription)") }
                return
            }
            DispatchQueue.global(qos: .utility).async {
                DatasetEncoder.writeWorldMap(map, directory: directory)
            }
        }
    }

    // MARK: - Light

    @objc private func flashTapped() {
        let next = TorchMode(rawValue: (torchMode.rawValue + 1) % 3) ?? .off
        setTorchMode(next)
    }

    private func setTorchMode(_ mode: TorchMode) {
        torchMode = mode
        torchTimer?.invalidate()
        torchTimer = nil
        exposureController.freezeISO = mode == .alternate
        var configuration = flashButton.configuration
        configuration?.image = UIImage(systemName: mode.symbolName)
        flashButton.configuration = configuration
        flashButton.accessibilityValue = mode.title
        switch mode {
        case .off:
            torchIsOn = false
            exposureController.setTorch(on: false)
        case .on:
            torchIsOn = true
            exposureController.setTorch(on: true)
        case .alternate:
            torchIsOn = true
            exposureController.setTorch(on: true)
            torchTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(toggleTorch), userInfo: nil, repeats: true)
        }
    }

    @objc private func toggleTorch() {
        torchIsOn.toggle()
        exposureController.setTorch(on: torchIsOn)
    }

    // MARK: - Views menu

    private func makeLayersMenu() -> UIMenu {
        let defaults = UserDefaults.standard
        func toggle(_ title: String, _ symbol: String, _ key: String, _ apply: @escaping () -> Void) -> UIAction {
            let on = defaults.bool(forKey: key)
            return UIAction(title: title, image: UIImage(systemName: symbol), state: on ? .on : .off) { [weak self] _ in
                defaults.set(!on, forKey: key)
                apply()
                self?.layersButton.menu = self?.makeLayersMenu()
            }
        }
        let insets = UIMenu(title: "Small views", options: .displayInline, children: [
            toggle("Camera", "camera.fill", "InsetCamera") { [weak self] in self?.applyInsetSettings() },
            toggle("LiDAR depth", "dot.radiowaves.left.and.right", "InsetDepth") { [weak self] in self?.applyInsetSettings() },
            toggle("Minimap (top view)", "map.fill", "InsetMinimap") { [weak self] in self?.applyInsetSettings() },
        ])
        let cloud = UIMenu(title: "Point cloud", options: .displayInline, children: [
            toggle("Colour by coverage (red = scan more)", "paintpalette.fill", "ShowCoverage") { [weak self] in
                self?.renderer?.showCoverage = UserDefaults.standard.bool(forKey: "ShowCoverage")
            },
        ])
        var guideItems: [UIMenuElement] = [
            UIAction(title: "Off", state: wallGuide.spacing == nil ? .on : .off) { [weak self] _ in
                self?.wallGuide.spacing = nil
                self?.layersButton.menu = self?.makeLayersMenu()
            }
        ]
        for spacing in WallSweepGuide.spacings {
            let cm = Int((spacing * 100).rounded())
            guideItems.append(UIAction(title: "Stripes every \(cm) cm", state: wallGuide.spacing == spacing ? .on : .off) { [weak self] _ in
                self?.wallGuide.spacing = spacing
                self?.layersButton.menu = self?.makeLayersMenu()
            })
        }
        let guide = UIMenu(title: "Wall path guide (sweep floor ↔ ceiling)", options: .displayInline, children: guideItems)
        return UIMenu(title: "", children: [insets, cloud, guide])
    }

    private func applyInsetSettings() {
        let defaults = UserDefaults.standard
        cameraInset.isHidden = !defaults.bool(forKey: "InsetCamera")
        depthInset.isHidden = !defaults.bool(forKey: "InsetDepth")
        minimapInset.isHidden = !defaults.bool(forKey: "InsetMinimap")
        if let renderer = renderer {
            if renderer.cameraInsetLayer == nil && !cameraInset.isHidden { configureInsetLayer(cameraInset.metalLayer, renderer: renderer) }
            if renderer.depthInsetLayer == nil && !depthInset.isHidden { configureInsetLayer(depthInset.metalLayer, renderer: renderer) }
            if renderer.minimapLayer == nil && !minimapInset.isHidden { configureInsetLayer(minimapInset.metalLayer, renderer: renderer) }
            renderer.cameraInsetLayer = cameraInset.isHidden ? nil : cameraInset.metalLayer
            renderer.depthInsetLayer = depthInset.isHidden ? nil : depthInset.metalLayer
            renderer.minimapLayer = minimapInset.isHidden ? nil : minimapInset.metalLayer
        }
    }

    private func configureInsetLayer(_ layer: CAMetalLayer, renderer: ScanRenderer) {
        layer.device = renderer.metalDevice
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
    }

    private var freeMinutes: Double? {
        guard let free = freeBytes, bytesPerSecond > 1000 else { return nil }
        return Double(free) / bytesPerSecond / 60
    }

    private func updateStatsText() {
        let m = qualityMonitor
        var exposure = "Auto exposure"
        if let frame = lastFrame {
            let duration = frame.camera.exposureDuration
            let shutter = duration > 0 ? "1/\(Int((1 / duration).rounded())) s" : "–"
            let iso = exposureController.snapshot().map { "ISO \(Int($0.iso))" } ?? ""
            let wb = exposureController.isCaptureLocked ? " · WB+focus locked" : ""
            exposure = "\(shutter) \(iso)\(wb)"
        }
        let blur = String(format: "Blur %.1f px · turn %.0f°/s (max %.0f)", m.blurPixels, m.angularSpeedDegrees, m.maxAngularSpeedForSharpFrames)
        let distance = m.medianDepth > 0 ? String(format: "%.1f m", m.medianDepth) : "–"
        let motion = String(format: "Subject %@ · walk %.2f m/s · moved %.1f m", distance, m.linearSpeed, m.distanceTravelled)
        var lines = [exposure, blur, motion]
        if statsExpanded {
            let frames = datasetEncoder.map { "Frames \($0.savedFrameCount) · dropped \($0.droppedFrames) · pins \($0.markerCount)" } ?? "Not recording"
            let cloud = renderer?.pointCloud
            let surface = String(format: "Scanned ≈ %.0f m² · %.0f%% seen from 3+ sides · LiDAR %.0f%%",
                                 cloud?.surfaceArea ?? 0, (cloud?.wellCoveredFraction ?? 0) * 100, m.confidentFraction * 100)
            let heatNames: [ProcessInfo.ThermalState: String] = [.nominal: "normal", .fair: "warm", .serious: "hot (lighter preview)", .critical: "critical"]
            let heat = String(format: "Heat %@ · app CPU %.0f%%", heatNames[ProcessInfo.processInfo.thermalState] ?? "?", cpuUsage)
            var storage = "Free " + ByteCountFormatter.string(fromByteCount: freeBytes ?? 0, countStyle: .file)
            if startedRecording != nil {
                storage += " · scan " + ByteCountFormatter.string(fromByteCount: datasetBytes, countStyle: .file)
                if let minutes = freeMinutes { storage += String(format: " · ~%.0f min left", minutes) }
            }
            let battery = UIDevice.current.batteryLevel
            if battery >= 0 { storage += String(format: " · battery %.0f%%", battery * 100) }
            lines += [frames, surface, storage, heat]
        }
        statsLabel.text = lines.joined(separator: "\n")
    }

    private func applyAdvice(_ advice: ScanAdvice) {
        if advice != lastAdvice {
            adviceLabel.text = advice.text
            adviceIcon.image = UIImage(systemName: advice.symbolName)
            let tint: UIColor?
            switch advice.level {
            case .bad: tint = UIColor.systemRed.withAlphaComponent(0.55)
            case .warning: tint = UIColor.systemOrange.withAlphaComponent(0.45)
            case .good: tint = UIColor.systemGreen.withAlphaComponent(0.3)
            case .info: tint = UIColor.systemBlue.withAlphaComponent(0.35)
            }
            Glass.setTint(advicePanel, tint)
            lastAdvice = advice
        }
        // Buzz for serious problems so the screen doesn't need watching (useful in dim mode).
        if advice.level == .bad, startedRecording != nil, Date().timeIntervalSince(lastHaptic) > 2.0 {
            if #available(iOS 17.5, *) {
                UINotificationFeedbackGenerator(view: view).notificationOccurred(.warning)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            lastHaptic = Date()
        }
    }

    private func refreshStorage() {
        guard !sizeCheckRunning, Date().timeIntervalSince(lastSizeCheck) > 3 else { return }
        sizeCheckRunning = true
        lastSizeCheck = Date()
        let directory = datasetEncoder?.directory
        let started = startedRecording
        DispatchQueue.global(qos: .utility).async {
            let free = RecordSessionViewController.freeDiskBytes()
            let size = directory.map { RecordSessionViewController.directorySize($0) } ?? 0
            DispatchQueue.main.async {
                self.freeBytes = free
                self.datasetBytes = size
                if let started = started {
                    let elapsed = Date().timeIntervalSince(started)
                    if elapsed > 5 { self.bytesPerSecond = Double(size) / elapsed }
                }
                self.sizeCheckRunning = false
            }
        }
    }

    private static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Misc

    private func showUnsupportedAlert() {
        let alert = UIAlertController(title: "Unsupported device", message: "This device doesn't seem to have the required level of ARKit support.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            self.dismissFunction?()
        }))
        self.present(alert, animated: true)
    }

    private func countSessions() -> Int {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return 0 }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Recording")
        do {
            let fetched: [NSManagedObject] = try appDelegate.persistentContainer.viewContext.fetch(request)
            return fetched.count
        } catch let error {
            print("Could not fetch sessions for counting. \(error.localizedDescription)")
        }
        return 0
    }
}
