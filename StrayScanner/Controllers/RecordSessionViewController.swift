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
    private var statsExpanded = UserDefaults.standard.bool(forKey: "StatsExpanded")
    private var hintHideWork: DispatchWorkItem?
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
    private var liveLink: PCLiveLink?
    private var torchCalibrationTimer: Timer?
    private var torchCalibrating = false
    private var isoTorchOff: Float?
    private var isoTorchOn: Float?
    static let use4KKey = "Use4KVideo"
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
    /// What each small view shows; tapping one swaps it with the big view.
    private var insetModes: [ViewMode] = [.camera, .depth, .map]
    private var configuredInsetLayers = Set<ObjectIdentifier>()
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
        updateFpsSetting()
        let pcSettings = PCLinkSettings.load()
        if pcSettings.live, let link = PCLiveLink(settings: pcSettings) {
            liveLink = link
            link.onSummary = { [weak self] good, text in
                guard let self = self, self.viewIfLoaded?.window != nil else { return }
                let alert = UIAlertController(title: good ? "PC: good to train" : "PC: rescan needed", message: text, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
            link.connect(scanName: nil, frame: nil)
        }
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(uiTick), userInfo: nil, repeats: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        uiTimer?.invalidate()
        uiTimer = nil
        setTorchMode(.off)
        liveLink?.disconnect()
        liveLink = nil
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
        if UserDefaults.standard.bool(forKey: RecordSessionViewController.use4KKey),
           let format = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            config.videoFormat = format
        }
        arConfiguration = config
        renderer?.previewInterval = max(1, config.videoFormat.framesPerSecond / 30)
        if !ARWorldTrackingConfiguration.isSupported || !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            print("AR is not supported.")
            unsupported = true
        } else {
            config.frameSemantics.insert(.sceneDepth)
            // Plane detection costs CPU; only the wall path guide needs it.
            config.planeDetection = wallGuide.isActive ? [.vertical] : []
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
        insetStack.axis = .horizontal
        insetStack.spacing = 6
        insetStack.alignment = .bottom
        for (index, inset) in [cameraInset, depthInset, minimapInset].enumerated() {
            inset.translatesAutoresizingMaskIntoConstraints = false
            inset.layer.cornerRadius = 16
            inset.layer.cornerCurve = .continuous
            inset.layer.borderWidth = 1
            inset.layer.borderColor = UIColor(white: 1, alpha: 0.3).cgColor
            inset.clipsToBounds = true
            inset.isHidden = true
            inset.tag = 600 + index
            inset.isAccessibilityElement = true
            inset.accessibilityTraits = .button
            inset.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(insetTapped(_:))))
            let caption = UILabel()
            caption.translatesAutoresizingMaskIntoConstraints = false
            caption.tag = 700
            caption.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
            caption.textColor = .white
            caption.backgroundColor = UIColor(white: 0, alpha: 0.45)
            caption.layer.cornerRadius = 6
            caption.layer.masksToBounds = true
            caption.textAlignment = .center
            inset.addSubview(caption)
            NSLayoutConstraint.activate([
                caption.bottomAnchor.constraint(equalTo: inset.bottomAnchor, constant: -5),
                caption.centerXAnchor.constraint(equalTo: inset.centerXAnchor),
                caption.heightAnchor.constraint(equalToConstant: 16),
                caption.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            ])
            insetStack.addArrangedSubview(inset)
        }
        updateInsetCaptions()

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
        adviceLabel.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        adviceLabel.numberOfLines = 1
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
        pinButton.isHidden = true

        pointHintLabel.translatesAutoresizingMaskIntoConstraints = false
        pointHintLabel.text = "Tap to switch view"
        pointHintLabel.textColor = UIColor(white: 1, alpha: 0.6)
        pointHintLabel.font = UIFont.systemFont(ofSize: 11, weight: .medium)
        pointHintLabel.isHidden = true

        // Bottom dock: view modes, fps, record, shutter.
        for (index, mode) in ViewMode.displayOrder.enumerated() {
            let image = UIImage(systemName: mode.symbolName)
            image?.accessibilityLabel = mode.title
            modeControl.insertSegment(with: image, at: index, animated: false)
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
            // Full screen: the picture fills everything behind the controls (cropped at the sides, not stretched).
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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

            // Small views sit in one row just above the advice banner, out of the way of the stats.
            insetStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            insetStack.bottomAnchor.constraint(equalTo: advicePanel.topAnchor, constant: -8),
            cameraInset.widthAnchor.constraint(equalToConstant: 72),
            cameraInset.heightAnchor.constraint(equalToConstant: 96),
            depthInset.widthAnchor.constraint(equalToConstant: 72),
            depthInset.heightAnchor.constraint(equalToConstant: 96),
            minimapInset.widthAnchor.constraint(equalToConstant: 72),
            minimapInset.heightAnchor.constraint(equalToConstant: 96),

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
            advicePanel.bottomAnchor.constraint(equalTo: dockPanel.topAnchor, constant: -10),
            adviceIcon.leadingAnchor.constraint(equalTo: advicePanel.contentView.leadingAnchor, constant: 14),
            adviceIcon.centerYAnchor.constraint(equalTo: adviceLabel.centerYAnchor),
            adviceIcon.widthAnchor.constraint(equalToConstant: 22),
            adviceIcon.heightAnchor.constraint(equalToConstant: 22),
            adviceLabel.leadingAnchor.constraint(equalTo: adviceIcon.trailingAnchor, constant: 10),
            adviceLabel.trailingAnchor.constraint(equalTo: advicePanel.contentView.trailingAnchor, constant: -14),
            adviceLabel.topAnchor.constraint(equalTo: advicePanel.contentView.topAnchor, constant: 8),
            blurMeter.leadingAnchor.constraint(equalTo: adviceLabel.leadingAnchor),
            blurMeter.trailingAnchor.constraint(equalTo: adviceLabel.trailingAnchor),
            blurMeter.topAnchor.constraint(equalTo: adviceLabel.bottomAnchor, constant: 5),
            blurMeter.heightAnchor.constraint(equalToConstant: 3),
            blurMeter.bottomAnchor.constraint(equalTo: advicePanel.contentView.bottomAnchor, constant: -8),

            pinButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            pinButton.centerYAnchor.constraint(equalTo: advicePanel.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 46),
            pinButton.heightAnchor.constraint(equalToConstant: 46),

            pointHintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
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
        pinButton.isHidden = false
        timerDot.backgroundColor = .systemRed
        datasetEncoder = DatasetEncoder(arConfiguration: arConfiguration!, fpsDivider: FpsDividers[chosenFpsSetting], exposureController: exposureController)
        var settings = exposureController.captureSettings()
        settings["torch_mode"] = ["off", "on", "alternate_1s"][torchMode.rawValue]
        if let folder = continueFrom {
            settings["continues_scan"] = folder.lastPathComponent
            settings["relocalized_at_start"] = relocalized
        }
        if torchMode == .alternate, let on = isoTorchOn, let off = isoTorchOff {
            settings["iso_torch_on"] = on
            settings["iso_torch_off"] = off
        }
        datasetEncoder?.writeCaptureSettings(settings)
        worldMapTimer?.invalidate()
        worldMapTimer = Timer.scheduledTimer(timeInterval: 20, target: self, selector: #selector(saveWorldMap), userInfo: nil, repeats: true)
        liveLink?.notifyRecording(scan: datasetEncoder?.directory.lastPathComponent, started: true)
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
        pinButton.isHidden = true
        timerDot.backgroundColor = UIColor(white: 1, alpha: 0.5)
        if let encoder = datasetEncoder {
            switch encoder.status {
                case .allGood:
                    saveRecording(started, encoder)
                    liveLink?.notifyRecording(scan: encoder.directory.lastPathComponent, started: false)
                    if PCLinkSettings.load().autoUpload {
                        PCUploader.shared.upload(directory: encoder.directory)
                    }
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
        flashHint()
    }

    @objc private func statsTapped() {
        statsExpanded.toggle()
        UserDefaults.standard.set(statsExpanded, forKey: "StatsExpanded")
        updateStatsText()
    }

    @objc private func modeChanged() {
        let index = modeControl.selectedSegmentIndex
        if index >= 0 && index < ViewMode.displayOrder.count {
            setViewMode(ViewMode.displayOrder[index], save: true)
        }
    }

    private func setViewMode(_ mode: ViewMode, save: Bool) {
        let previous = viewMode
        viewMode = mode
        normalizeInsets(previousMain: previous)
        renderer?.mode = mode
        modeControl.selectedSegmentIndex = ViewMode.displayOrder.firstIndex(of: mode) ?? 0
        if let title = view.viewWithTag(501) as? UILabel {
            title.text = mode == .dim ? "Dim · screen off to save battery" : mode.title
        }
        pointHintLabel.isHidden = true
        if mode == .pointCloud, let renderer = renderer {
            pointHintLabel.text = renderer.chaseCamera ? "Overview · tap for camera view" : "Camera view · tap for overview"
            flashHint()
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

    private func flashHint() {
        hintHideWork?.cancel()
        pointHintLabel.isHidden = false
        let work = DispatchWorkItem { [weak self] in self?.pointHintLabel.isHidden = true }
        hintHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
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
        let base = arConfiguration?.videoFormat.framesPerSecond ?? 60
        let fps = max(base / FpsDividers[chosenFpsSetting], 1)
        Glass.setTitle(fpsButton, "\(fps) fps")
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
        if wallGuide.isActive { wallGuide.update(frame: frame) }
        if frameCounter % 3 == 0 {
            var guides = wallGuide.isActive ? wallGuide.vertices() : []
            if let markers = liveLink?.markers { guides += markers }
            renderer?.guideVertices = guides
        }
        renderer?.render(frame: frame)
        if recording {
            if let encoder = datasetEncoder {
                var quality = qualityMonitor.currentQuality()
                quality.torchLevel = exposureController.torchLevel
                encoder.add(frame: frame, quality: quality)
                liveLink?.update(frame: frame, savedFrame: encoder.savedFrameCount - 1, quality: quality,
                                 pointCloud: renderer?.pointCloud, recording: true)
            } else {
                print("There is no video encoder. That can't be good.")
            }
        } else if let link = liveLink {
            var quality = qualityMonitor.currentQuality()
            quality.torchLevel = exposureController.torchLevel
            link.update(frame: frame, savedFrame: nil, quality: quality, pointCloud: renderer?.pointCloud, recording: false)
        }
    }

    // MARK: - HUD

    @objc private func uiTick() {
        refreshPCPreview()
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
            if torchCalibrating {
                advice = ScanAdvice(level: .info, text: "Calibrating light — hold still for 3 s", symbolName: "bolt.badge.clock")
            } else if continueFrom != nil && !relocalized {
                advice = ScanAdvice(level: .warning, text: "Continuing: point at the area you scanned last to line up", symbolName: "arrow.triangle.2.circlepath")
            } else if let pcHint = liveLink?.currentHint {
                advice = pcHint
            } else if startedRecording != nil, let gap = nearestPCGap() {
                advice = gap
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

    /// Turns the PC's gap markers (spots not yet seen from enough angles) into "where to point next".
    private var shownPreviewVersion = 0

    /// New preview splat from the PC → hand it to the renderer (the "PC preview" view and its small view).
    private func refreshPCPreview() {
        guard let link = liveLink, link.previewVersion != shownPreviewVersion else { return }
        shownPreviewVersion = link.previewVersion
        renderer?.setPreview(link.previewSplats)
        if viewMode != .pcPreview {
            applyAdvice(ScanAdvice(level: .good, text: "PC preview updated — tap the PC view to see it", symbolName: "desktopcomputer"))
        }
    }

    /// Where the PC wants you to go next (its target first, else the nearest gap marker).
    private func pcTargetAdvice() -> ScanAdvice? {
        guard let target = liveLink?.target, let frame = lastFrame else { return nil }
        let local4 = frame.camera.transform.inverse * SIMD4<Float>(target.point, 1)
        let (direction, symbol) = describeDirection(SIMD3<Float>(local4.x, local4.y, local4.z))
        let distance = simd_length(SIMD3<Float>(local4.x, local4.y, local4.z))
        return ScanAdvice(level: .info, text: String(format: "PC: %@ — %.1f m %@", target.text, distance, direction), symbolName: symbol)
    }

    private func describeDirection(_ target: SIMD3<Float>) -> (String, String) {
        let forward = -target.z, right = target.y, up = -target.x
        if forward < 0 && abs(forward) > max(abs(right), abs(up)) { return ("behind you", "arrow.uturn.backward") }
        if abs(right) > abs(up) && abs(right) > forward * 0.4 { return right > 0 ? ("to your right", "arrow.right") : ("to your left", "arrow.left") }
        if abs(up) > forward * 0.4 { return up > 0 ? ("higher up", "arrow.up") : ("lower down", "arrow.down") }
        return ("ahead", "scope")
    }

    private func nearestPCGap() -> ScanAdvice? {
        refreshPCPreview()
        if let target = pcTargetAdvice() { return target }
        guard let markers = liveLink?.markers, !markers.isEmpty, let frame = lastFrame else { return nil }
        let camera = frame.camera.transform
        let position = SIMD3<Float>(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let toCamera = camera.inverse
        var best: (distance: Float, local: SIMD3<Float>)?
        var nearby = 0
        for marker in markers {
            let p = SIMD3<Float>(marker.position.x, marker.position.y, marker.position.z)
            let d = simd_distance(p, position)
            guard d > 0.3, d < 5 else { continue }
            nearby += 1
            let local4 = toCamera * SIMD4<Float>(p, 1)
            let local = SIMD3<Float>(local4.x, local4.y, local4.z)
            // Prefer gaps roughly in front: cheap to fix without walking around.
            let cost = d + (local.z > 0 ? 1.5 : 0)
            if best == nil || cost < best!.distance { best = (cost, local) }
        }
        guard let target = best?.local else { return nil }
        // ARKit camera axes are fixed to the sensor: +x runs toward the Home-button end (down when held upright),
        // +y toward the phone's right edge, -z forward. Scans are filmed upright.
        let forward = -target.z
        let right = target.y, up = -target.x
        let distance = simd_length(target)
        let direction: String, symbol: String
        if forward < 0 && abs(forward) > max(abs(right), abs(up)) {
            direction = "behind you"; symbol = "arrow.uturn.backward"
        } else if abs(right) > abs(up) && abs(right) > forward * 0.4 {
            direction = right > 0 ? "to your right" : "to your left"; symbol = right > 0 ? "arrow.right" : "arrow.left"
        } else if abs(up) > forward * 0.4 {
            direction = up > 0 ? "higher up" : "lower down"; symbol = up > 0 ? "arrow.up" : "arrow.down"
        } else {
            direction = "ahead"; symbol = "scope"
        }
        return ScanAdvice(level: .info,
                          text: String(format: "PC: gap %.1f m %@ — film it from another angle (%d gaps nearby)", distance, direction, nearby),
                          symbolName: symbol)
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
        torchCalibrationTimer?.invalidate()
        torchCalibrationTimer = nil
        torchCalibrating = false
        exposureController.freezeISO = false
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
            // Calibrate: let auto-ISO settle with the light off, then on, and remember both ISOs, so the
            // lit frames use a lower ISO and don't burn out. (In Auto shutter iOS handles exposure itself.)
            torchIsOn = false
            exposureController.setTorch(on: false)
            isoTorchOff = nil
            isoTorchOn = nil
            torchCalibrating = true
            torchCalibrationTimer = Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(calibrationStep), userInfo: nil, repeats: true)
        }
    }

    @objc private func calibrationStep() {
        if isoTorchOff == nil {
            isoTorchOff = exposureController.currentISO
            torchIsOn = true
            exposureController.setTorch(on: true)
            return
        }
        isoTorchOn = exposureController.currentISO
        torchCalibrationTimer?.invalidate()
        torchCalibrationTimer = nil
        torchCalibrating = false
        exposureController.freezeISO = true
        torchTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(toggleTorch), userInfo: nil, repeats: true)
    }

    @objc private func toggleTorch() {
        torchIsOn.toggle()
        exposureController.setTorch(on: torchIsOn)
        if let iso = torchIsOn ? isoTorchOn : isoTorchOff {
            exposureController.setFixedISO(iso)
        }
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
                self?.refreshPlaneDetection()
            }
        ]
        for spacing in WallSweepGuide.spacings {
            let cm = Int((spacing * 100).rounded())
            guideItems.append(UIAction(title: "Stripes every \(cm) cm", state: wallGuide.spacing == spacing ? .on : .off) { [weak self] _ in
                self?.wallGuide.spacing = spacing
                self?.layersButton.menu = self?.makeLayersMenu()
                self?.refreshPlaneDetection()
            })
        }
        let guide = UIMenu(title: "Wall path guide (sweep floor ↔ ceiling)", options: .displayInline, children: guideItems)
        let has4K = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution != nil
        var fourK = toggle(has4K ? "4K video (30 fps, ~2× file size)" : "4K video (not supported on this phone)",
                           "4k.tv", RecordSessionViewController.use4KKey) { [weak self] in
            self?.startSession()
            self?.updateFpsSetting()
        }
        if !has4K || startedRecording != nil {
            fourK = UIAction(title: fourK.title, image: fourK.image, attributes: .disabled, state: fourK.state) { _ in }
        }
        let capture = UIMenu(title: "Capture", options: .displayInline, children: [fourK])
        return UIMenu(title: "", children: [insets, cloud, guide, capture])
    }

    /// Turns ARKit plane detection on/off without resetting tracking.
    private func refreshPlaneDetection() {
        guard let config = arConfiguration, !unsupported else { return }
        let wanted: ARWorldTrackingConfiguration.PlaneDetection = wallGuide.isActive ? [.vertical] : []
        guard config.planeDetection != wanted else { return }
        config.planeDetection = wanted
        session.run(config)
    }

    private func applyInsetSettings() {
        let defaults = UserDefaults.standard
        cameraInset.isHidden = !defaults.bool(forKey: "InsetCamera")
        depthInset.isHidden = !defaults.bool(forKey: "InsetDepth")
        minimapInset.isHidden = !defaults.bool(forKey: "InsetMinimap")
        updateRendererInsets()
    }

    private func updateRendererInsets() {
        guard let renderer = renderer else { return }
        var list: [(layer: CAMetalLayer, mode: ViewMode)] = []
        for (index, inset) in [cameraInset, depthInset, minimapInset].enumerated() where !inset.isHidden {
            let id = ObjectIdentifier(inset.metalLayer)
            if !configuredInsetLayers.contains(id) {
                configureInsetLayer(inset.metalLayer, renderer: renderer)
                configuredInsetLayers.insert(id)
            }
            list.append((inset.metalLayer, insetModes[index]))
        }
        renderer.insets = list
    }

    /// Small views show three different things, none of them the same as the big view.
    private func normalizeInsets(previousMain: ViewMode) {
        if let i = insetModes.firstIndex(of: viewMode) { insetModes[i] = previousMain }
        let pool: [ViewMode] = [.camera, .depth, .map, .pointCloud, .overlay]
        var seen = Set<ViewMode>([viewMode == .dim ? .camera : viewMode])
        for i in insetModes.indices {
            if seen.contains(insetModes[i]) || insetModes[i] == .dim {
                insetModes[i] = pool.first { !seen.contains($0) && !insetModes.contains($0) } ?? insetModes[i]
            }
            seen.insert(insetModes[i])
        }
        updateInsetCaptions()
        updateRendererInsets()
    }

    private func updateInsetCaptions() {
        for (index, inset) in [cameraInset, depthInset, minimapInset].enumerated() {
            let title = insetModes[index].title
            (inset.viewWithTag(700) as? UILabel)?.text = "  \(title)  "
            inset.accessibilityLabel = "\(title), tap to show big"
        }
    }

    /// Tapping a small view swaps it with the big view.
    @objc private func insetTapped(_ gesture: UITapGestureRecognizer) {
        guard let inset = gesture.view, viewMode != .dim else { return }
        let index = inset.tag - 600
        guard index >= 0 && index < insetModes.count else { return }
        let small = insetModes[index]
        UIView.transition(with: view, duration: 0.25, options: .transitionCrossDissolve, animations: {
            self.setViewMode(small, save: true)
            self.updateInsetCaptions()
            self.updateRendererInsets()
        })
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
        if !statsExpanded {
            // Compact: the two lines that matter while walking; tap the card for everything.
            let frames = datasetEncoder.map { " · \($0.savedFrameCount) fr" } ?? ""
            let cloud = renderer?.pointCloud
            let cover = String(format: " · %.0f m² · %.0f%% 3+ sides", cloud?.surfaceArea ?? 0, (cloud?.wellCoveredFraction ?? 0) * 100)
            var text = String(format: "%@ · blur %.1f px", exposure, m.blurPixels) + "\n"
                + String(format: "%.1f m away · moved %.1f m", m.medianDepth, m.distanceTravelled) + frames + cover
            // The PC link state is always shown, so it is obvious whether SplatForge is helping.
            if let link = liveLink { text += "\n" + link.statusText }
            else if PCLinkSettings.load().isConfigured { text += "\nPC live link off (Settings ▸ SplatForge PC)" }
            statsLabel.text = text
            return
        }
        var lines = [exposure, blur, motion]
        do {
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
            if let link = liveLink { lines.append(link.statusText) }
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
