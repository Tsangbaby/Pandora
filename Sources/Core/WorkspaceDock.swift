import Foundation
import CoreGraphics

// A dock ticket describes an explicit user action, not a retained presenter.
// The native adapter must verify release before publishing a dock tab and verify
// that the same lease still matches the native scene before a fresh mount.
struct WorkspaceDock {
    typealias Member = WorkspaceRotation.Member
    struct Ticket: Equatable {
        fileprivate let serial: UInt64
        let member: Member
    }
    enum Phase: Equatable { case idle, returning(Ticket), parked(Ticket), restoring(Ticket) }

    private(set) var phase: Phase = .idle
    private var serial: UInt64 = 0

    mutating func beginReturn(_ member: Member) -> Ticket? {
        guard phase == .idle, serial < UInt64.max else { return nil }
        serial += 1
        let ticket = Ticket(serial: serial, member: member)
        phase = .returning(ticket)
        return ticket
    }

    mutating func completeReturn(_ ticket: Ticket, nativeVerified: Bool) -> Bool {
        guard phase == .returning(ticket) else { return false }
        phase = nativeVerified ? .parked(ticket) : .idle
        return nativeVerified
    }

    func isParked(_ ticket: Ticket) -> Bool { phase == .parked(ticket) }

    mutating func beginRestore(_ ticket: Ticket, member: Member, nativeVerified: Bool) -> Bool {
        guard phase == .parked(ticket), member == ticket.member else { return false }
        phase = nativeVerified ? .restoring(ticket) : .idle
        return nativeVerified
    }

    func permitsMount(_ member: Member, restore: Ticket?) -> Bool {
        switch (phase, restore) {
        case (.idle, nil): return true
        case (.restoring(let current), .some(let supplied)):
            return current == supplied && member == current.member
        default: return false
        }
    }

    mutating func completeMount(_ member: Member, restore: Ticket?) -> Bool {
        guard permitsMount(member, restore: restore) else { return false }
        phase = .idle
        return true
    }

    mutating func discardRestore(_ ticket: Ticket) {
        if phase == .restoring(ticket) { phase = .idle }
    }

    mutating func cancel() { phase = .idle }
}

enum WorkspaceEdgeMotion {
    enum Direction: Equatable { case up, down }
    enum Keyboard: Equatable { case hidden, visible, unknown }
    enum Decision: Equatable { case apply, confirm, finishEditing }

    static func direction(for offset: CGPoint, velocity: CGPoint) -> Direction? {
        guard offset.x.isFinite, offset.y.isFinite, velocity.x.isFinite, velocity.y.isFinite else { return nil }
        let distance = abs(offset.y)
        guard distance >= 16, distance >= 1.35 * abs(offset.x) else { return nil }
        let flick = abs(velocity.y) >= 480 && abs(velocity.y) >= 1.35 * abs(velocity.x) &&
                   (offset.y < 0) == (velocity.y < 0)
        guard distance >= 38 || flick else { return nil }
        return offset.y < 0 ? .up : .down
    }

    static func confirmationIsCurrent(issuedAt: TimeInterval, now: TimeInterval) -> Bool {
        issuedAt.isFinite && now.isFinite && issuedAt >= 0 && now >= issuedAt && now - issuedAt < 6
    }

    static func decision(keyboard: Keyboard, repeated: Bool) -> Decision {
        switch keyboard {
        case .hidden: return .apply
        case .visible: return .finishEditing
        case .unknown: return repeated ? .apply : .confirm
        }
    }

    // Remain entirely below the app's safe layout rect and leave the bottom
    // 14 points and the horizontal screen edges to system gestures.
    static func dockFrame(in bounds: CGRect, bottomInset: CGFloat) -> CGRect? {
        guard ProbeKeyboardLayout.isFiniteRect(bounds), bounds.maxY.isFinite, bounds.maxX.isFinite,
              bounds.width >= 230, bounds.height > 120, bottomInset.isFinite,
              bottomInset >= 30, bottomInset <= 60 else { return nil }
        let height = min(20, bottomInset - 14)
        return CGRect(x: bounds.maxX - 122, y: bounds.maxY - 14 - height, width: 96, height: height)
    }
}
