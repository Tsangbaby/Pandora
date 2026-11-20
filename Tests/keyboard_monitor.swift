import Foundation
import CoreGraphics

// Environment doubles only: axis-aligned offsets/bounds origins. Transform and
// scene values exercise rejection/identity gates, not transformed UIKit geometry.
// No UIKit, WindowServer, keyboard construction or remote process behavior.
public struct FakeUIColor {
    public let cgColor: CGColor
    init(whiteAlpha: CGFloat) { cgColor = CGColor(gray: 1, alpha: whiteAlpha) }
}

public class UIView: NSObject {
    public var bounds: CGRect
    public var offset: CGPoint
    public weak var superview: UIView?
    public private(set) var subviews: [UIView] = []
    public var backgroundColor: FakeUIColor? = nil
    public var isHidden = false
    public var alpha: CGFloat = 1
    public var transform: CGAffineTransform = .identity
    public var clipsToBounds = false
    public var window: UIWindow? { superview?.window }
    public init(_ bounds: CGRect, offset: CGPoint = .zero) {
        self.bounds = bounds; self.offset = offset; super.init()
    }
    public func addSubview(_ child: UIView) {
        precondition(child.superview == nil)
        child.superview = self; subviews.append(child)
    }
    private var screenOrigin: CGPoint {
        let parent = superview?.screenOrigin ?? .zero
        return CGPoint(x: parent.x + offset.x - bounds.origin.x,
                       y: parent.y + offset.y - bounds.origin.y)
    }
    fileprivate func rectFrom(_ rect: CGRect, _ source: UIView) -> CGRect {
        rect.offsetBy(dx: source.screenOrigin.x - screenOrigin.x,
                      dy: source.screenOrigin.y - screenOrigin.y)
    }
    public func convert(_ rect: CGRect, from view: UIView?) -> CGRect {
        guard let view = view, let current = window else {
            preconditionFailure("UIView conversion requires attached views and an explicit source")
        }
        precondition(view.window === current, "UIView.convert(from:) must stay in one window")
        return rectFrom(rect, view)
    }
    public func convert(_ rect: CGRect, to view: UIView?) -> CGRect {
        guard let view = view, let current = window else {
            preconditionFailure("UIView conversion requires attached views and an explicit destination")
        }
        precondition(view.window === current, "UIView.convert(to:) must stay in one window")
        return view.rectFrom(rect, self)
    }
}
public final class UIScreen: NSObject {}
public final class UIWindowScene: NSObject {}
public final class UIWindow: UIView {
    public let screen: UIScreen
    public var windowScene: UIWindowScene? = nil
    public var windowLevel: CGFloat = 10
    public override var window: UIWindow? { self }
    public init(screen: UIScreen) {
        self.screen = screen
        super.init(CGRect(x: 0, y: 0, width: 500, height: 1000),
                   offset: CGPoint(x: 100, y: 200))
    }
    public func convert(_ rect: CGRect, from window: UIWindow?) -> CGRect {
        guard let window = window else { preconditionFailure("Explicit source window required") }
        precondition(window.screen === screen, "UIWindow bridge must stay on one screen")
        return rectFrom(rect, window)
    }
}
public final class UIApplication: NSObject {
    public static let shared = UIApplication()
    public var windows: [UIWindow] = []
}
// Real Objective-C registration/discovery/isKind(of:); not an Apple keyboard.
@objc(UIInputSetHostView) class KeyboardHost: UIView {}
final class DerivedKeyboardHost: KeyboardHost {}

private let hostRect = CGRect(x: 40, y: 600, width: 300, height: 180)
private let keyRect = CGRect(x: 12, y: 8, width: 100, height: 20)
private let outsideRect = CGRect(x: 32, y: 568, width: 100, height: 20)
private let white = FakeUIColor(whiteAlpha: 1)

@discardableResult
private func child(_ parent: UIView, _ rect: CGRect = keyRect,
                   fill: FakeUIColor? = nil) -> UIView {
    let view = UIView(CGRect(origin: .zero, size: rect.size), offset: rect.origin)
    view.backgroundColor = fill
    parent.addSubview(view)
    return view
}

private final class Rig {
    let screen = UIScreen()
    let carrier: UIWindow
    let root = UIView(CGRect(x: 0, y: 0, width: 400, height: 800),
                      offset: CGPoint(x: 20, y: 40))
    let owned = UIView(CGRect(x: 0, y: 0, width: 400, height: 800))
    init() {
        carrier = UIWindow(screen: screen)
        carrier.addSubview(root); root.addSubview(owned)
        UIApplication.shared.windows = [carrier]
    }
    func overlay(level: CGFloat = 11, screen: UIScreen? = nil) -> UIWindow {
        let window = UIWindow(screen: screen ?? self.screen)
        window.windowLevel = level
        UIApplication.shared.windows.append(window)
        return window
    }
    func host(_ parent: UIView, _ rect: CGRect = hostRect) -> KeyboardHost {
        let view = KeyboardHost(CGRect(origin: .zero, size: rect.size), offset: rect.origin)
        parent.addSubview(view)
        return view
    }
    func scan() -> ProbeOutsideKeyboardObservation {
        ProbeKeyboardMonitor.outsideKeyboard(in: root, hostedView: owned)
    }
}

@main private enum KeyboardMonitorTests {
    static var checks = 0, failures = 0
    static func check(_ value: Bool, _ label: String) {
        checks += 1
        if !value { failures += 1; print("FAIL: \(label)") }
    }
    static func hasFrames(_ result: ProbeOutsideKeyboardObservation, _ expected: [CGRect]) -> Bool {
        result.scanCompleted && result.frames == expected
    }
    static func empty(_ r: Rig) -> Bool { hasFrames(r.scan(), []) }

    static func main() {
        check(NSClassFromString("UIInputSetHostView") != nil &&
              NSStringFromClass(KeyboardHost.self) == "UIInputSetHostView", "01 real ObjC class lookup")
        var r = Rig()
        let excluded = child(r.overlay(), r.root.bounds)
        child(r.host(excluded), fill: white)
        check(hasFrames(ProbeKeyboardMonitor.outsideKeyboard(in: r.root, hostedView: excluded), []),
              "02 hostedView prunes even in an otherwise eligible window")
        r = Rig(); child(r.host(r.overlay()), fill: white)
        let found = r.scan()
        check(hasFrames(found, [outsideRect]), "03 higher-level white fill emits only the actual child")
        check(ProbeKeyboardLayout.hostedScene(source: r.root.bounds.size, available: r.root.bounds,
              outsideKeyboardFrames: found.frames) == .returnToNative, "04 overlap returns native, never minifies")
        let top = CGRect(x: 0, y: 0, width: 400, height: 400)
        let topCard = CGRect(x: 100, y: 0, width: 200, height: 400)
        check(ProbeKeyboardLayout.hostedScene(source: r.root.bounds.size, available: top,
              outsideKeyboardFrames: found.frames) == .present(topCard), "05 nonoverlap preserves full fitted card")
        r = Rig(); child(r.host(r.root), fill: white)
        check(empty(r), "06 carrier sibling stacking is ambiguous, not positive evidence")
        r = Rig(); let derived = DerivedKeyboardHost(CGRect(origin: .zero, size: hostRect.size), offset: hostRect.origin)
        r.overlay().addSubview(derived); child(derived, fill: white)
        check(hasFrames(r.scan(), [outsideRect]), "07 real isKind includes host subclasses")
        r = Rig(); let lookalike = child(r.overlay(), hostRect)
        child(lookalike, fill: white)
        check(empty(r), "08 filled content outside a recognized host is not evidence")
        r = Rig(); r.host(r.overlay()).backgroundColor = white
        check(empty(r), "09 empty input wrapper is ignored even when it has a fill")
        r = Rig(); child(r.host(r.overlay()), fill: white).isHidden = true
        check(empty(r), "10 hidden content is not positive evidence")
        r = Rig(); child(r.host(r.overlay()), fill: white).alpha = 0.01
        check(empty(r), "11 view alpha boundary is excluded")
        r = Rig(); child(r.host(r.overlay()), fill: white).bounds.size.width = 1
        check(empty(r), "12 one-point content width is excluded")
        r = Rig(); child(r.host(r.overlay()), fill: white).bounds.size.height = 0
        check(empty(r), "13 zero-height content is excluded")
        r = Rig(); child(r.host(r.overlay()), fill: white).alpha = 0.0101
        check(hasFrames(r.scan(), [outsideRect]), "14 content just above view alpha boundary is evidence")
        r = Rig(); child(r.host(r.overlay(level: 9)), fill: white)
        check(empty(r), "15 lower-level keyboard is behind card and excluded")
        r = Rig(); child(r.host(r.overlay(level: r.carrier.windowLevel.nextUp)), fill: white)
        check(hasFrames(r.scan(), [outsideRect]), "16 even the smallest strictly higher level is eligible")
        r = Rig(); child(r.host(r.overlay(screen: UIScreen())), fill: white)
        check(empty(r), "17 another screen is excluded by identity")
        r = Rig(); let hiddenWindow = r.overlay(); child(r.host(hiddenWindow), fill: white); hiddenWindow.isHidden = true
        check(empty(r), "18 hidden window is excluded")
        r = Rig(); let faintWindow = r.overlay(); child(r.host(faintWindow), fill: white); faintWindow.alpha = 0.01
        check(empty(r), "19 window alpha boundary is excluded")
        faintWindow.alpha = 0.0101
        check(hasFrames(r.scan(), [outsideRect]), "20 window above alpha boundary is eligible")
        r = Rig(); let ancestor = child(r.overlay(), r.root.bounds); child(r.host(ancestor), fill: white)
        ancestor.isHidden = true
        check(empty(r), "21 hidden ancestor prunes descendants")
        ancestor.isHidden = false; ancestor.alpha = 0.01
        check(empty(r), "22 transparent ancestor prunes descendants")
        r = Rig(); let hiddenHost = r.host(r.overlay()); child(hiddenHost, fill: white); hiddenHost.isHidden = true
        check(empty(r), "23 hidden host is excluded")
        hiddenHost.isHidden = false; hiddenHost.alpha = 0.01
        check(empty(r), "24 transparent host is excluded")
        r = Rig()
        let clip = child(r.overlay(), CGRect(x: 50, y: 540, width: 200, height: 100))
        clip.clipsToBounds = true
        let clippedHost = r.host(clip, CGRect(x: 50, y: 50, width: 300, height: 180))
        child(clippedHost, CGRect(x: 80, y: 35, width: 100, height: 30), fill: white)
        check(hasFrames(r.scan(), [CGRect(x: 160, y: 585, width: 70, height: 15)]),
              "25 ancestor clip intersects filled child exactly on both axes")
        clip.bounds.size.height = 40
        check(empty(r), "26 fully clipped host has no positive child geometry")
        clip.clipsToBounds = false
        check(hasFrames(r.scan(), [CGRect(x: 160, y: 585, width: 100, height: 30)]),
              "27 nonclipping ancestor allows child overflow")
        clip.bounds.size.width = CGFloat.infinity
        check(empty(r), "28 invalid ancestor bounds prune subtree")
        r = Rig(); let invalidHost = r.host(r.overlay()); child(invalidHost, fill: white)
        invalidHost.bounds.size.width = CGFloat.infinity
        check(empty(r), "29 invalid host bounds prune filled descendants")
        r = Rig(); child(r.host(r.overlay(), CGRect(x: 40, y: 900, width: 300, height: 80)), fill: white)
        check(empty(r), "30 filled content outside root but within window is excluded")
        r = Rig(); let narrow = r.host(r.overlay(), CGRect(x: 40, y: 600, width: 1, height: 180))
        narrow.clipsToBounds = true
        child(narrow, CGRect(x: 0, y: 8, width: 100, height: 20), fill: white)
        check(empty(r), "31 child clipped to one point of visible width is excluded")
        r = Rig(); r.root.bounds.origin = CGPoint(x: 10, y: 20)
        r.carrier.bounds.origin = CGPoint(x: 2, y: 3)
        let shifted = r.overlay(); shifted.offset = CGPoint(x: 130, y: 240)
        shifted.bounds.origin = CGPoint(x: 5, y: 7)
        let shiftedHost = r.host(shifted); shiftedHost.bounds.origin = CGPoint(x: 3, y: 4)
        child(shiftedHost, fill: white).bounds.origin = CGPoint(x: 6, y: 9)
        check(hasFrames(r.scan(), [CGRect(x: 66, y: 620, width: 100, height: 20)]),
              "32 legal window bridge preserves offsets and nonzero bounds origins")
        r = Rig(); let outer = r.host(r.overlay()); outer.backgroundColor = white
        let intermediary = child(outer, CGRect(origin: .zero, size: hostRect.size))
        let inner = r.host(intermediary, CGRect(x: 40, y: 30, width: 160, height: 80))
        inner.backgroundColor = white; child(inner, fill: white)
        check(hasFrames(r.scan(), [CGRect(x: 72, y: 598, width: 100, height: 20)]),
              "33 walk through ordinary and nested hosts without emitting either wrapper")
        r = Rig(); let unattached = UIView(r.root.bounds)
        let noCarrier = ProbeKeyboardMonitor.outsideKeyboard(in: unattached, hostedView: nil)
        check(!noCarrier.scanCompleted && noCarrier.frames.isEmpty, "34 missing carrier means unknown/incomplete")
        r = Rig(); child(r.host(r.overlay()), fill: white)
        for _ in 0..<63 { _ = r.overlay() } // Carrier + one positive window + 63 = 65.
        let tooMany = r.scan()
        check(!tooMany.scanCompleted && tooMany.frames.isEmpty, "35 65 windows refuse even early evidence")
        UIApplication.shared.windows.removeLast()
        check(hasFrames(r.scan(), [outsideRect]), "36 exactly 64 windows scan and retain evidence")

        r = Rig(); let limitHost = r.host(r.overlay()); child(limitHost, fill: white)
        for _ in 0..<252 { child(limitHost, .zero) }
        let lastKey = CGRect(x: 140, y: 8, width: 30, height: 20)
        child(limitHost, lastKey, fill: white) // Window + host + 254 descendants = 256.
        check(hasFrames(r.scan(), [outsideRect, CGRect(x: 160, y: 568, width: 30, height: 20)]),
              "37 visits exactly 256 nodes, including the final filled descendant")
        r = Rig(); child(r.host(r.overlay()), fill: white) // First window: 3 visits.
        let laterHost = r.host(r.overlay())
        for _ in 0..<251 { child(laterHost, .zero) }
        child(laterHost, lastKey, fill: white) // 3 + window + host + 252 descendants = 257.
        let partial = r.scan()
        check(!partial.scanCompleted && partial.frames == [outsideRect],
              "38 global visit 257 refuses; only first window's positive survives")
        r = Rig(); let wideHost = r.host(r.overlay()); child(wideHost, fill: white)
        for _ in 0..<509 { child(wideHost, .zero) } // Two entries + 510 children = 512.
        let atQueueLimit = r.scan()
        check(!atQueueLimit.scanCompleted && atQueueLimit.frames == [outsideRect],
              "39 queue 512 admits children; visit cap still marks scan incomplete")
        child(wideHost, .zero)
        let overQueueLimit = r.scan()
        check(!overQueueLimit.scanCompleted && overQueueLimit.frames.isEmpty,
              "40 queue 513 refuses the child list before even its first positive")
        r = Rig()
        check(empty(r), "41 empty local scan completes but cannot prove remote keyboard absence")
        r = Rig(); let sameBefore = r.overlay(level: r.carrier.windowLevel)
        let sameAfter = r.overlay(level: r.carrier.windowLevel)
        child(r.host(sameBefore), fill: white); child(r.host(sameAfter), fill: white)
        UIApplication.shared.windows = [sameBefore, r.carrier, sameAfter]
        check(empty(r), "42 neither same-level window is evidence, regardless of list order")

        // Full root-sized wrapper, shifted down 60pt in root coordinates so an
        // overflowing child can be inside the card/root but outside the host clip.
        let fullFrame = CGRect(x: 20, y: 100, width: 400, height: 800)
        r = Rig(); let fullClip = r.host(r.overlay(), fullFrame); fullClip.clipsToBounds = true
        child(fullClip, CGRect(x: 130, y: -45, width: 100, height: 20), fill: white)
        check(empty(r), "43 full-frame host with a filled child wholly outside its clip emits nothing")
        r = Rig(); let fullHost = r.host(r.overlay(), fullFrame)
        child(fullHost, CGRect(x: 130, y: 500, width: 100, height: 20), fill: white)
        let belowCard = r.scan()
        check(hasFrames(belowCard, [CGRect(x: 130, y: 560, width: 100, height: 20)]) &&
              ProbeKeyboardLayout.hostedScene(source: r.root.bounds.size, available: top,
                  outsideKeyboardFrames: belowCard.frames) == .present(topCard),
              "44 full-frame wrapper intersects the card but only its nonoverlapping child counts")
        r = Rig(); child(r.host(r.overlay(), fullFrame))
        check(empty(r), "45 default nil descendant background is not presumed to be filled")
        r = Rig(); let clearChildHost = r.host(r.overlay(), fullFrame); clearChildHost.backgroundColor = white
        child(clearChildHost, fill: FakeUIColor(whiteAlpha: 0))
        check(empty(r), "46 clear child is not evidence even with a filled input wrapper")
        r = Rig(); let faintFill = child(r.host(r.overlay()), fill: FakeUIColor(whiteAlpha: 0.01))
        let atFillThreshold = r.scan()
        faintFill.backgroundColor = FakeUIColor(whiteAlpha: 0.0101)
        check(hasFrames(atFillThreshold, []) && hasFrames(r.scan(), [outsideRect]),
              "47 fill alpha must be strictly above 0.01 (independent of view alpha)")
        r = Rig(); let edgeHost = r.host(r.overlay(), fullFrame); edgeHost.clipsToBounds = true
        child(edgeHost, CGRect(x: 130, y: -10, width: 100, height: 30), fill: white)
        check(hasFrames(r.scan(), [CGRect(x: 130, y: 60, width: 100, height: 20)]),
              "48 partially clipped child emits exactly the visible fill, not child or wrapper bounds")
        r = Rig(); let otherScene = r.overlay(); child(r.host(otherScene), fill: white)
        r.carrier.windowScene = UIWindowScene(); otherScene.windowScene = UIWindowScene()
        let crossScene = r.scan()
        otherScene.windowScene = r.carrier.windowScene
        check(hasFrames(crossScene, []) && hasFrames(r.scan(), [outsideRect]),
              "49 same-screen other scene is excluded, same scene identity is accepted")
        r = Rig(); let transformedHost = r.host(r.overlay()); let transformedKey = child(transformedHost, fill: white)
        transformedHost.transform = CGAffineTransform(translationX: 1, y: 0)
        let transformedAncestor = r.scan()
        transformedHost.transform = .identity
        transformedKey.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        let transformedContent = r.scan()
        transformedKey.transform = .identity
        check(hasFrames(transformedAncestor, []) && hasFrames(transformedContent, []) &&
              hasFrames(r.scan(), [outsideRect]), "50 nonidentity ancestor or content prunes the branch")
        print("PANDORA_KEYBOARD_MONITOR_TESTS checks=\(checks) failures=\(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
