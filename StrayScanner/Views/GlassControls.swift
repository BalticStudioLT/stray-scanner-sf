//
//  GlassControls.swift
//  StrayScanner
//
//  Liquid Glass styled building blocks for the record screen (stray-scanner-sf fork).
//  Uses UIGlassEffect / glass button configurations on iOS 26+, blur material before.
//

import UIKit

enum Glass {
    static func panel(cornerRadius: CGFloat, tint: UIColor? = nil) -> UIVisualEffectView {
        let view: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = tint
            view = UIVisualEffectView(effect: effect)
        } else {
            view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            if let tint = tint {
                view.contentView.backgroundColor = tint.withAlphaComponent(0.25)
            }
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }

    static func setTint(_ panel: UIVisualEffectView, _ tint: UIColor?) {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = tint
            panel.effect = effect
        } else {
            panel.contentView.backgroundColor = tint?.withAlphaComponent(0.25)
        }
    }

    static func button(title: String?, symbol: String?, prominent: Bool = false) -> UIButton {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = prominent ? .prominentGlass() : .glass()
        } else {
            configuration = .filled()
            configuration.baseBackgroundColor = UIColor(white: 1.0, alpha: prominent ? 0.3 : 0.14)
            configuration.cornerStyle = .capsule
        }
        configuration.baseForegroundColor = .white
        configuration.title = title
        if let symbol = symbol {
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePadding = 6
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        }
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            return updated
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func setTitle(_ button: UIButton, _ title: String) {
        var configuration = button.configuration
        configuration?.title = title
        button.configuration = configuration
    }
}

/// Large round record button: red dot that morphs into a rounded square while recording.
final class GlassRecordButton: UIControl {
    private let ring = CAShapeLayer()
    private let core = CALayer()
    private let background: UIVisualEffectView

    var isRecording: Bool = false {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        background = Glass.panel(cornerRadius: 41)
        super.init(frame: frame)
        background.isUserInteractionEnabled = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.lineWidth = 4
        layer.addSublayer(ring)
        core.backgroundColor = UIColor.systemRed.cgColor
        layer.addSublayer(core)
        accessibilityLabel = "Record"
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { return CGSize(width: 82, height: 82) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 6
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        if isRecording {
            let side: CGFloat = 30
            core.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            core.cornerRadius = 8
        } else {
            let side = bounds.width - inset * 2 - 12
            core.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            core.cornerRadius = side / 2
        }
        core.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1.0 }
    }
}

/// Ring of 12 segments: which compass directions have been filmed, and where the phone points now.
final class CoverageRingView: UIView {
    private var segments: [CAShapeLayer] = []
    private let count = ScanQualityMonitor.headingSectors

    override init(frame: CGRect) {
        super.init(frame: frame)
        for _ in 0..<count {
            let segment = CAShapeLayer()
            segment.fillColor = UIColor.clear.cgColor
            segment.lineWidth = 6
            segment.lineCap = .butt
            layer.addSublayer(segment)
            segments.append(segment)
        }
        isUserInteractionEnabled = false
        accessibilityLabel = "Scanned directions"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { return CGSize(width: 54, height: 54) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 4
        let step = 2 * CGFloat.pi / CGFloat(count)
        for (i, segment) in segments.enumerated() {
            // Sector 0 starts behind the user (yaw -180°); draw so "straight ahead" is at the top.
            let start = -CGFloat.pi / 2 + CGFloat(i) * step - CGFloat.pi + 0.06
            let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: start, endAngle: start + step - 0.12, clockwise: true)
            segment.frame = bounds
            segment.path = path.cgPath
        }
    }

    func update(covered: [Bool], current: Int) {
        for (i, segment) in segments.enumerated() {
            let isCovered = i < covered.count && covered[i]
            if i == current {
                segment.strokeColor = UIColor.white.cgColor
            } else if isCovered {
                segment.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9).cgColor
            } else {
                segment.strokeColor = UIColor(white: 1.0, alpha: 0.18).cgColor
            }
        }
    }
}
