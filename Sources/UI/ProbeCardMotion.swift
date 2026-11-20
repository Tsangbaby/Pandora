import UIKit

/// Local mount visuals only. The controller owns native commit, input routing, and teardown.
@MainActor
final class ProbeCardMotion {
    private enum Phase {
        case idle
        case staged(frame: CGRect, generation: UInt64, reduceMotion: Bool)
        case revealing(frame: CGRect, generation: UInt64, animator: UIViewPropertyAnimator, onSettled: () -> Void)
        case settled
    }

    private weak var root: UIView?
    private let backdrop = UIView(frame: .zero)
    private let veilClip = UIView(frame: .zero)
    private let veil = UIView(frame: .zero)
    private var phase: Phase = .idle

    init(root: UIView, carrier: UIView, panel: UIView) {
        let siblings = root.subviews
        guard let carrierIndex = siblings.firstIndex(where: { $0 === carrier }),
              let panelIndex = siblings.firstIndex(where: { $0 === panel }),
              carrierIndex < panelIndex else {
            preconditionFailure("Install the card carrier below the panel before creating its motion.")
        }
        self.root = root

        for overlay in [backdrop, veilClip, veil] {
            overlay.isUserInteractionEnabled = false
            overlay.accessibilityElementsHidden = true
        }
        backdrop.backgroundColor = .black
        backdrop.alpha = 0
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        veilClip.isOpaque = false
        veilClip.clipsToBounds = true
        veilClip.isHidden = true
        veil.backgroundColor = .black
        veil.alpha = 0
        veilClip.addSubview(veil)

        root.insertSubview(backdrop, belowSubview: carrier)
        root.insertSubview(veilClip, aboveSubview: carrier)
    }

    /// A gate for the controller; the decorative views never intercept hits.
    var blocksContent: Bool {
        switch phase {
        case .staged, .revealing: return true
        case .idle, .settled: return false
        }
    }

    /// Receives the validated native readback in root coordinates, before activation.
    func prepare(frame: CGRect, generation: UInt64, reduceMotion: Bool) {
        clear()
        guard Self.isValid(frame), installedRoot != nil else { return }
        phase = .staged(frame: frame, generation: generation, reduceMotion: reduceMotion)
        if !reduceMotion { placeVeil(in: frame) }
    }

    /// Call only after native success. Reduce Motion settles synchronously.
    func reveal(generation: UInt64, onSettled: @escaping () -> Void) {
        guard case let .staged(frame, currentGeneration, reduceMotion) = phase,
              currentGeneration == generation else { return }
        guard let root = installedRoot else { clear(); return }
        fitBackdrop(to: root.bounds)

        if reduceMotion {
            rest(committed: true, stopAnimator: false)
            onSettled()
            return
        }

        let lift = min(6, frame.height * 0.08)
        let animator = UIViewPropertyAnimator(duration: 0.28, curve: .easeOut, animations: { [weak self] in
            guard let self = self else { return }
            self.backdrop.alpha = 1
            self.veil.alpha = 0
            self.veil.transform = CGAffineTransform(translationX: 0, y: -lift)
        })
        phase = .revealing(frame: frame, generation: generation, animator: animator, onSettled: onSettled)
        animator.addCompletion { [weak self, weak animator] _ in
            guard let animator = animator else { return }
            self?.settle(generation: generation, animator: animator, stopAnimator: false)
        }
        animator.startAnimation()
    }

    /// Only successful geometry readbacks belong here; failures go through clear().
    func geometryChanged(to frame: CGRect) {
        guard Self.isValid(frame) else { return }
        guard let root = installedRoot else { clear(); return }
        fitBackdrop(to: root.bounds)

        switch phase {
        case let .staged(previous, generation, reduceMotion) where frame != previous:
            phase = .staged(frame: frame, generation: generation, reduceMotion: reduceMotion)
            if !reduceMotion { placeVeil(in: frame) }
        case let .revealing(previous, generation, animator, _) where frame != previous:
            settle(generation: generation, animator: animator, stopAnimator: true)
        default:
            break
        }
    }

    func clear() {
        rest(committed: false, stopAnimator: true)
    }

    private var installedRoot: UIView? {
        guard let root = root, backdrop.superview === root, veilClip.superview === root else { return nil }
        return root
    }

    private func fitBackdrop(to bounds: CGRect) {
        guard backdrop.frame != bounds else { return }
        UIView.performWithoutAnimation { backdrop.frame = bounds }
    }

    private func placeVeil(in frame: CGRect) {
        UIView.performWithoutAnimation {
            veilClip.frame = frame
            veil.frame = veilClip.bounds
            veil.alpha = 1
            veilClip.isHidden = false
        }
    }

    private func settle(generation: UInt64, animator: UIViewPropertyAnimator, stopAnimator: Bool) {
        guard case let .revealing(_, currentGeneration, currentAnimator, onSettled) = phase,
              currentGeneration == generation, currentAnimator === animator else { return }
        let committed = installedRoot != nil
        rest(committed: committed, stopAnimator: stopAnimator)
        if committed { onSettled() }
    }

    private func rest(committed: Bool, stopAnimator: Bool) {
        let previous = phase
        // Invalidate before touching the animator, even if a generation gets reused.
        phase = committed ? .settled : .idle
        if stopAnimator, case let .revealing(_, _, animator, _) = previous, animator.state == .active {
            animator.stopAnimation(true)
        }
        UIView.performWithoutAnimation {
            backdrop.alpha = committed ? 1 : 0
            veilClip.isHidden = true
            veilClip.frame = .zero
            veil.alpha = 0
            veil.transform = .identity
            veil.frame = .zero
        }
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite &&
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.size.width.isFinite && frame.size.height.isFinite &&
            frame.size.width > 0 && frame.size.height > 0 &&
            frame.maxX.isFinite && frame.maxY.isFinite
    }
}
