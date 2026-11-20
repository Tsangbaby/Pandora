import UIKit

struct ProbeOutsideKeyboardObservation {
    let frames: [CGRect] // Positive geometry only, in the owned root's coordinates.
    let scanCompleted: Bool
    // Even a complete local scan cannot prove absence of a remote-process keyboard.
}

enum ProbeKeyboardMonitor {
    // Read existing UIKit views only. No private getters, new keyboard/windows,
    // view loading, registration, text inspection or responder changes.
    // A notification's unscaled frame is never accepted as outside-card evidence.
    static func outsideKeyboard(in root: UIView, hostedView: UIView?) -> ProbeOutsideKeyboardObservation {
        guard Thread.isMainThread, let carrierWindow = root.window else {
            return ProbeOutsideKeyboardObservation(frames: [], scanCompleted: false)
        }
        let types = ["UIInputSetHostView"].compactMap { NSClassFromString($0) }
        guard !types.isEmpty else {
            return ProbeOutsideKeyboardObservation(frames: [], scanCompleted: false)
        }
        let windows = UIApplication.shared.windows
        guard windows.count <= 64 else {
            return ProbeOutsideKeyboardObservation(frames: [], scanCompleted: false)
        }
        // Same-level ordering and same-window sibling stacking are ambiguous.
        // Only a DIFFERENT strictly higher-level window is positive front evidence.
        let candidates = windows.filter {
            $0 !== carrierWindow && $0.screen === carrierWindow.screen &&
                $0.windowScene === carrierWindow.windowScene && !$0.isHidden && $0.alpha > 0.01 &&
                $0.windowLevel > carrierWindow.windowLevel
        }
        var frames: [CGRect] = []
        var visited = 0
        for window in candidates {
            func converted(_ item: UIView) -> CGRect? {
                guard item.window === window else { return nil }
                // UIView conversion stays within a window. UIWindow's overload
                // is the supported bridge between the two same-screen windows.
                let inSource = item.convert(item.bounds, to: window)
                let inCarrier = carrierWindow.convert(inSource, from: window)
                let result = root.convert(inCarrier, from: carrierWindow)
                return ProbeKeyboardLayout.isFiniteRect(result) ? result : nil
            }
            guard let windowBounds = converted(window) else { continue }
            var queue: [(UIView, CGRect, Bool)] = [(window, windowBounds, false)]
            var cursor = 0
            while cursor < queue.count {
                guard visited < 256 else {
                    return ProbeOutsideKeyboardObservation(frames: frames, scanCompleted: false)
                }
                let (item, ancestorClip, insideHost) = queue[cursor]
                cursor += 1
                visited += 1
                if item === hostedView || item.isHidden || item.alpha <= 0.01 || !item.transform.isIdentity { continue }
                guard let bounds = converted(item) else { continue }
                let visible = bounds.intersection(ancestorClip).intersection(root.bounds)
                let isHost = types.contains(where: { item.isKind(of: $0) })
                // Never emit the input wrapper's whole bounds merely because a
                // child exists. Require an actually filled descendant rectangle.
                // Transparent/drawing-only/remote content remains unobserved.
                let fillAlpha = item.backgroundColor?.cgColor.alpha ?? 0
                if insideHost && !isHost && fillAlpha > 0.01 && !visible.isNull &&
                    visible.width > 1 && visible.height > 1 {
                    frames.append(visible)
                }
                let clip = item.clipsToBounds ? visible : ancestorClip
                if clip.isNull { continue }
                let children = item.subviews
                // Bound BEFORE iteration; no unbudgeted contains() child walk.
                guard children.count <= 512 - queue.count else {
                    return ProbeOutsideKeyboardObservation(frames: frames, scanCompleted: false)
                }
                for child in children { queue.append((child, clip, insideHost || isHost)) }
            }
        }
        return ProbeOutsideKeyboardObservation(frames: frames, scanCompleted: true)
    }
}
