import UIKit

// This view is never installed on the native app, the hosted view, or the root.
// Only the plug-in's own header and small parked card edge can start a pan.
final class ProbeGestureEdge: UIView, UIGestureRecognizerDelegate {
    let isDockTab: Bool
    var permitsGesture: (() -> Bool)?
    var onSwipe: ((WorkspaceEdgeMotion.Direction) -> Bool)?
    private let face = UIView()
    private let grip = UIView()

    init(dockTab: Bool) {
        isDockTab = dockTab
        super.init(frame: .zero)
        face.isUserInteractionEnabled = false
        grip.isUserInteractionEnabled = false
        if dockTab {
            face.backgroundColor = UIColor(white: 0.13, alpha: 0.94)
            face.layer.cornerRadius = 9
            face.layer.cornerCurve = .continuous
            face.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        grip.backgroundColor = dockTab ? UIColor(white: 0.79, alpha: 1) : .tertiaryLabel
        grip.layer.cornerRadius = 1.5
        addSubview(face)
        face.addSubview(grip)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = dockTab ? .button : .staticText
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Change bounds/center rather than frame, because the face is allowed
        // to move a few points during the local press gesture.
        face.bounds = CGRect(origin: .zero, size: bounds.size)
        face.center = CGPoint(x: bounds.midX, y: bounds.midY)
        grip.frame = CGRect(x: face.bounds.midX - 15, y: isDockTab ? face.bounds.midY - 1.5 : 3,
                            width: 30, height: 3)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              !isHidden, window != nil, permitsGesture?() == true else { return false }
        let speed = pan.velocity(in: self)
        return speed.y.isFinite && speed.x.isFinite && abs(speed.y) > 1.2 * abs(speed.x) &&
            (!isDockTab || speed.y < 0)
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began, .changed:
            let y = pan.translation(in: self).y
            if y.isFinite, !UIAccessibility.isReduceMotionEnabled {
                face.transform = CGAffineTransform(translationX: 0, y: min(6, max(-6, y * 0.10)))
            }
        case .ended:
            let direction = WorkspaceEdgeMotion.direction(for: pan.translation(in: self), velocity: pan.velocity(in: self))
            settle()
            if let direction, (!isDockTab || direction == .up), permitsGesture?() == true { _ = onSwipe?(direction) }
        case .cancelled, .failed:
            settle()
        default: break
        }
    }

    private func settle() {
        if UIAccessibility.isReduceMotionEnabled { resetPose(); return }
        UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) { [weak self] in
            self?.face.transform = .identity
        }
    }

    func resetPose() {
        face.layer.removeAllAnimations()
        UIView.performWithoutAnimation { face.transform = .identity }
    }

    override func accessibilityActivate() -> Bool {
        guard isDockTab, !isHidden, window != nil, permitsGesture?() == true else { return false }
        return onSwipe?(.up) == true
    }
}
