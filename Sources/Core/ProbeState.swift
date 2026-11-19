import Foundation
import CoreGraphics

// Only the manual, foreground-Notes experiment. No persisted or background sessions.
struct ProbeState {
    enum Phase: Equatable { case idle, mounting, attached, cancelling, blocked }
    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0
    private(set) var focusRequested = false

    mutating func begin() -> UInt64? {
        guard phase == .idle else { return nil }
        generation &+= 1
        phase = .mounting
        focusRequested = false
        return generation
    }

    mutating func attach(_ token: UInt64) -> Bool {
        guard phase == .mounting, token == generation else { return false }
        phase = .attached
        return true
    }

    mutating func markFocus(_ token: UInt64) -> Bool {
        guard phase == .attached, token == generation, !focusRequested else { return false }
        focusRequested = true
        return true
    }

    mutating func beginCancellation() -> UInt64? {
        guard phase != .cancelling else { return nil }
        generation &+= 1
        phase = .cancelling
        focusRequested = false
        return generation
    }

    mutating func finishCancellation(_ token: UInt64, succeeded: Bool) -> Bool {
        guard phase == .cancelling, generation == token else { return false }
        phase = succeeded ? .idle : .blocked
        return true
    }

    // Model-only convenience for already-resolved cleanup. UI must use the
    // explicit cancellation barrier around native cleanup, not this shortcut.
    mutating func stop() {
        if let token = beginCancellation() { _ = finishCancellation(token, succeeded: true) }
    }
}

enum ProbeAdmission {
    static func permits(published: Bool, closing: Bool, overlayValid: Bool) -> Bool {
        return published && !closing && overlayValid
    }
    static func resumesClose(published: Bool, closing: Bool, overlayValid: Bool) -> Bool {
        return published && closing && overlayValid
    }
}

enum ProbeGeometry {
    // Preserve the source coordinate space; never resize the native Scene.
    static func fit(source: CGSize, available: CGRect) -> CGRect? {
        let numbers = [source.width, source.height, available.minX, available.minY,
                       available.width, available.height]
        guard numbers.allSatisfy({ $0.isFinite }), source.width > 0,
              source.height > 0, available.width >= 120, available.height >= 120 else { return nil }
        let scale = min(1, available.width / source.width, available.height / source.height)
        guard scale >= 0.2 else { return nil }
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
