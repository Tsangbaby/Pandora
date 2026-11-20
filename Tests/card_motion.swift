import Foundation
import CoreGraphics

// Storage and identity only: no layout, hit testing, interpolation or run loop.
@MainActor
final class UIView {
    enum Color { case black }
    struct AutoresizingMask: OptionSet {
        let rawValue: Int
        static let flexibleWidth = Self(rawValue: 1)
        static let flexibleHeight = Self(rawValue: 2)
    }

    var frame: CGRect
    var bounds: CGRect { CGRect(origin: .zero, size: frame.size) }
    var backgroundColor: Color?
    var alpha: CGFloat = 1
    var transform: CGAffineTransform = .identity
    var autoresizingMask: AutoresizingMask = []
    var isOpaque = true
    var isHidden = false
    var clipsToBounds = false
    var isUserInteractionEnabled = true
    var accessibilityElementsHidden = false
    private(set) weak var superview: UIView?
    private(set) var subviews: [UIView] = []

    init(frame: CGRect) { self.frame = frame }
    static func performWithoutAnimation(_ work: () -> Void) { work() }
    func addSubview(_ view: UIView) { insert(view, at: subviews.count) }
    func insertSubview(_ view: UIView, belowSubview sibling: UIView) {
        insert(view, at: subviews.firstIndex { $0 === sibling }!)
    }
    func insertSubview(_ view: UIView, aboveSubview sibling: UIView) {
        insert(view, at: subviews.firstIndex { $0 === sibling }! + 1)
    }
    private func insert(_ view: UIView, at index: Int) {
        precondition(view.superview == nil)
        subviews.insert(view, at: index)
        view.superview = self
    }
}

@MainActor
final class UIViewPropertyAnimator {
    enum Curve { case easeOut }
    enum Position { case end }
    enum State { case inactive, active }

    static var latest: UIViewPropertyAnimator?
    private(set) var state = State.inactive
    private(set) var stopCalls = 0
    var replayOnStop = false
    private let animations: () -> Void
    private var completions: [(Position) -> Void] = []

    init(duration: TimeInterval, curve: Curve, animations: @escaping () -> Void) {
        self.animations = animations
        Self.latest = self
    }
    func addCompletion(_ work: @escaping (Position) -> Void) { completions.append(work) }
    func startAnimation() {
        state = .active
        animations() // Apply model values, but don't deliver completion until asked.
    }
    func stopAnimation(_ withoutFinishing: Bool) {
        precondition(withoutFinishing)
        stopCalls += 1
        state = .inactive
        if replayOnStop { replayCompletion() } // Inject reentrancy, not UIKit behavior.
    }
    func complete() {
        precondition(state == .active)
        state = .inactive
        replayCompletion()
    }
    func replayCompletion() { completions.forEach { $0(.end) } }
}

@MainActor
private struct Card {
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let carrier = UIView(frame: .zero)
    let panel = UIView(frame: .zero)
    let motion: ProbeCardMotion
    var backdrop: UIView { root.subviews[0] }
    var clip: UIView { root.subviews[2] }
    var veil: UIView { clip.subviews[0] }
    var veilReset: Bool {
        clip.isHidden && clip.frame == .zero && veil.frame == .zero && veil.alpha == 0 && veil.transform.isIdentity
    }

    init() {
        root.addSubview(carrier)
        root.addSubview(panel)
        motion = ProbeCardMotion(root: root, carrier: carrier, panel: panel)
    }
}

@main
@MainActor
struct CardMotionTests {
    private static var trials = 0
    private static var checks = 0
    private static var failures = 0

    private static func trial(_ run: (Card) -> Void) {
        UIViewPropertyAnimator.latest = nil
        run(Card())
        trials += 1
    }
    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("FAIL: \(label)")
        }
    }

    static func main() {
        let frame = CGRect(x: 20, y: 40, width: 240, height: 120)
        let moved = frame.offsetBy(dx: 5, dy: 8)

        trial { c in
            var calls = 0
            check(c.root.subviews.count == 4 && c.root.subviews[1] === c.carrier && c.root.subviews[3] === c.panel &&
                  [c.backdrop, c.clip, c.veil].allSatisfy { !$0.isUserInteractionEnabled && $0.accessibilityElementsHidden },
                  "01 inert overlay order")
            check(!c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 0, "02 initially clear")
            c.motion.prepare(frame: frame, generation: 1, reduceMotion: false)
            check(c.motion.blocksContent && !c.clip.isHidden && c.clip.frame == frame &&
                  c.veil.frame == c.clip.bounds && c.veil.alpha == 1 && c.backdrop.alpha == 0, "03 staged veil")
            c.motion.reveal(generation: 2) { calls += 1 }
            check(c.motion.blocksContent && calls == 0 && UIViewPropertyAnimator.latest == nil && c.veil.alpha == 1,
                  "04 mismatched generation cannot reveal")
            c.motion.clear()
            check(!c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 0, "05 clear while staged")
            c.motion.reveal(generation: 1) { calls += 1 }
            check(!c.motion.blocksContent && calls == 0 && UIViewPropertyAnimator.latest == nil,
                  "06 cleared generation cannot reveal")
        }

        trial { c in
            var calls = 0
            var sawRest = false
            c.motion.prepare(frame: frame, generation: 3, reduceMotion: false)
            c.motion.reveal(generation: 3) {
                calls += 1
                sawRest = !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 1
            }
            let animator = UIViewPropertyAnimator.latest!
            check(animator.state == .active && c.motion.blocksContent && calls == 0, "07 revealing still gates")
            check(c.backdrop.alpha == 1 && !c.clip.isHidden && c.veil.alpha == 0 && !c.veil.transform.isIdentity,
                  "08 reveal model values applied")
            animator.complete()
            check(calls == 1 && sawRest && animator.stopCalls == 0, "09 completion sees settled values")
            animator.replayCompletion()
            c.motion.reveal(generation: 3) { calls += 1 }
            check(calls == 1 && !c.motion.blocksContent && UIViewPropertyAnimator.latest === animator,
                  "10 settled callback is not repeated")
            c.motion.clear()
            check(c.veilReset && c.backdrop.alpha == 0 && !c.motion.blocksContent, "11 clear restores alpha after settle")
        }

        trial { c in
            var oldCalls = 0
            var newCalls = 0
            c.motion.prepare(frame: frame, generation: 4, reduceMotion: false)
            c.motion.reveal(generation: 4) { oldCalls += 1 }
            let old = UIViewPropertyAnimator.latest!
            // Reuse the token to test animator identity independently of generation.
            c.motion.prepare(frame: moved, generation: 4, reduceMotion: false)
            c.motion.reveal(generation: 4) { newCalls += 1 }
            let current = UIViewPropertyAnimator.latest!
            check(old !== current && old.stopCalls == 1 && current.state == .active, "12 replace active animator")
            old.replayCompletion()
            check(c.motion.blocksContent && current.state == .active && !c.clip.isHidden && c.clip.frame == moved &&
                  c.backdrop.alpha == 1, "13 retired completion leaves replacement revealing")
            check(oldCalls == 0 && newCalls == 0, "14 retired completion notifies neither callback")
            current.complete()
            check(oldCalls == 0 && newCalls == 1 && !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 1,
                  "15 only replacement completes")
        }

        trial { c in
            var calls = 0
            c.motion.prepare(frame: frame, generation: 5, reduceMotion: false)
            c.motion.reveal(generation: 5) { calls += 1 }
            let animator = UIViewPropertyAnimator.latest!
            animator.replayOnStop = true
            c.motion.clear()
            check(animator.stopCalls == 1 && animator.state == .inactive, "16 clear stops running animator")
            check(calls == 0 && !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 0,
                  "17 clear invalidates before stopping and resets visuals")
            animator.replayCompletion()
            check(calls == 0 && !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 0,
                  "18 delayed completion cannot undo clear")
        }

        trial { c in
            var calls = 0
            c.motion.prepare(frame: frame, generation: 6, reduceMotion: false)
            c.root.frame.size.width += 20
            c.motion.geometryChanged(to: moved)
            check(c.motion.blocksContent && c.clip.frame == moved && c.veil.frame == c.clip.bounds &&
                  c.backdrop.frame == c.root.bounds, "19 staged geometry refits overlays")
            c.motion.reveal(generation: 6) { calls += 1 }
            let animator = UIViewPropertyAnimator.latest!
            c.motion.geometryChanged(to: .zero)
            c.motion.geometryChanged(to: moved)
            check(c.motion.blocksContent && calls == 0 && animator.stopCalls == 0, "20 invalid or unchanged geometry is inert")
            c.motion.geometryChanged(to: frame)
            check(calls == 1 && animator.stopCalls == 1 && !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 1,
                  "21 changed geometry settles once")
            animator.replayCompletion()
            c.root.frame.size.height += 20
            c.motion.geometryChanged(to: moved)
            check(calls == 1 && !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 1 &&
                  c.backdrop.frame == c.root.bounds && UIViewPropertyAnimator.latest === animator,
                  "22 settled geometry refits without motion or callback")
        }

        trial { c in
            var calls = 0
            var sawRest = false
            c.motion.prepare(frame: frame, generation: 7, reduceMotion: true)
            check(c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 0, "23 reduced motion stages without veil")
            c.motion.geometryChanged(to: moved)
            check(c.motion.blocksContent && c.veilReset, "24 reduced motion geometry keeps veil hidden")
            c.motion.reveal(generation: 7) {
                calls += 1
                sawRest = !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 1
            }
            check(calls == 1 && sawRest, "25 reduced motion settles synchronously")
            check(UIViewPropertyAnimator.latest == nil, "26 reduced motion never creates animator")
            c.motion.reveal(generation: 7) { calls += 1 }
            c.motion.clear()
            check(calls == 1 && !c.motion.blocksContent && c.veilReset && c.backdrop.alpha == 0,
                  "27 reduced motion callback is once and clear restores alpha")
        }

        print("PANDORA_CARD_MOTION_TESTS trials=\(trials) checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
