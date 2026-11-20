import Foundation
import CoreGraphics

// Environmental observations, NOT the input owner's state or proof of keyboard
// placement. Notifications can be missed when the controller did not yet exist.
struct ProbeKeyboardEnvironment {
    enum Observation: Equatable {
        case unknown
        case hidden
        case frame(CGRect)
    }
    private(set) var observation: Observation = .unknown

    mutating func recordFrame(_ frame: CGRect?) {
        guard let frame = frame, ProbeKeyboardLayout.isFiniteRect(frame) else {
            observation = .unknown
            return
        }
        observation = .frame(frame) // A zero/offscreen frame is not fabricated as hide.
    }

    mutating func recordHidden() { observation = .hidden }

    // A new session does NOT clear this cache. Ending a presentation says
    // nothing about the physical keyboard, and does not end marked text.
    var accessibilitySummary: String {
        switch observation {
        case .unknown: return "键盘状态尚未观察；卡片保持基础比例"
        case .hidden: return "已收到收键盘通知；卡片保持基础比例"
        case .frame: return "已收到键盘位置通知；同卡键盘不再次缩放整个 App"
        }
    }
}

enum ProbeKeyboardDecision: Equatable {
    case present(CGRect)
    case returnToNative
    case insufficientSpace
}

enum ProbeKeyboardLayout {
    static func isFiniteRect(_ rect: CGRect) -> Bool {
        return !rect.isNull && !rect.isInfinite && rect.size.width >= 0 && rect.size.height >= 0 &&
            [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy { $0.isFinite }
    }

    // Explicitly the complete-Scene host mode established by the target videos:
    // Notes manages editing viewport/caret while its keyboard travels with it.
    // Notification frame is NOT subtracted from the carrier a second time.
    // Only independently observed visible outside-keyboard geometry may demand
    // a native return; this is not a generalized split/resize implementation.
    static func hostedScene(source: CGSize, available: CGRect,
                            outsideKeyboardFrames: [CGRect]) -> ProbeKeyboardDecision {
        guard isFiniteRect(available),
              let base = ProbeGeometry.fit(source: source, available: available) else {
            return .insufficientSpace
        }
        for rect in outsideKeyboardFrames where isFiniteRect(rect) && rect.width > 1 && rect.height > 1 {
            let overlap = base.intersection(rect)
            if !overlap.isNull && overlap.width > 1 && overlap.height > 1 {
                return .returnToNative // Do not minify, re-focus, crop, or synthesize input.
            }
        }
        return .present(base)
    }
}
