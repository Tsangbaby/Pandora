import Foundation
import CoreGraphics

func runDockTests() {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard condition() else { fatalError("DOCK FAIL: \(label)") }
    }

    var dock = WorkspaceDock()
    var rotation = WorkspaceRotation()
    func issue(_ member: WorkspaceDock.Member) -> WorkspaceDock.Ticket {
        guard let ticket = dock.beginReturn(member) else { fatalError("DOCK FAIL: return setup") }
        return ticket
    }
    func park(_ member: WorkspaceDock.Member) -> WorkspaceDock.Ticket {
        let ticket = issue(member)
        guard dock.completeReturn(ticket, nativeVerified: true) else { fatalError("DOCK FAIL: park setup") }
        return ticket
    }
    func restore(_ member: WorkspaceDock.Member) -> WorkspaceDock.Ticket {
        let ticket = park(member)
        guard dock.beginRestore(ticket, member: member, nativeVerified: true) else {
            fatalError("DOCK FAIL: restore setup")
        }
        return ticket
    }

    expect(dock.phase == .idle && rotation.lastMounted == nil, "idle does not imply a mounted member")
    dock.cancel()
    expect(dock.permitsMount(.notes, restore: nil) && dock.completeMount(.notes, restore: nil) &&
           dock.phase == .idle, "idle cancel leaves standalone admission available")

    let old = issue(.notes)
    expect(old.member == .notes && dock.phase == .returning(old) && !dock.isParked(old) &&
           dock.beginReturn(.files) == nil, "only one return can be in flight")
    expect(!dock.beginRestore(old, member: .notes, nativeVerified: true) &&
           !dock.permitsMount(.notes, restore: nil) && !dock.completeMount(.notes, restore: old) &&
           dock.phase == .returning(old), "returning grants neither restore nor mount")
    dock.cancel()
    expect(!dock.completeReturn(old, nativeVerified: true) && !dock.completeMount(.notes, restore: old) &&
           dock.phase == .idle, "cancel during return rejects late completion and mount")

    let refused = issue(.notes)
    expect(old != refused && !dock.completeReturn(old, nativeVerified: true) &&
           dock.phase == .returning(refused), "stale same-member ticket cannot complete a newer return")
    expect(!dock.completeReturn(refused, nativeVerified: false) && !dock.isParked(refused) &&
           dock.phase == .idle, "unverified native return cannot park")

    let parked = issue(.notes)
    expect(dock.completeReturn(parked, nativeVerified: true) && dock.phase == .parked(parked) &&
           dock.isParked(parked) && !dock.isParked(refused), "verified native return parks only its ticket")
    expect(dock.beginReturn(.files) == nil && !dock.permitsMount(.notes, restore: nil) &&
           !dock.permitsMount(.notes, restore: parked) && !dock.completeMount(.notes, restore: parked) &&
           dock.isParked(parked), "a parked ticket is not mount admission")
    expect(!dock.beginRestore(refused, member: .notes, nativeVerified: true) &&
           !dock.beginRestore(parked, member: .files, nativeVerified: true) &&
           !dock.beginRestore(parked, member: .files, nativeVerified: false) && dock.isParked(parked),
           "wrong ticket or member cannot restore or consume the parked ticket")
    dock.discardRestore(parked)
    expect(!dock.completeReturn(parked, nativeVerified: true) &&
           !dock.completeReturn(parked, nativeVerified: false) && dock.isParked(parked),
           "restore discard and duplicate return completions cannot alter a parked ticket")
    dock.cancel()
    expect(!dock.isParked(parked) && !dock.beginRestore(parked, member: .notes, nativeVerified: true) &&
           !dock.completeMount(.notes, restore: parked) && dock.phase == .idle,
           "cancel while parked invalidates restore and mount")

    let refusedRestore = park(.files)
    expect(!dock.beginRestore(refusedRestore, member: .files, nativeVerified: false) &&
           !dock.isParked(refusedRestore) && !dock.completeMount(.files, restore: refusedRestore) &&
           dock.phase == .idle, "failed native re-verification revokes the parked ticket")

    let current = park(.files)
    expect(dock.beginRestore(current, member: .files, nativeVerified: true) && !dock.isParked(current) &&
           dock.phase == .restoring(current) && dock.permitsMount(.files, restore: current),
           "matching verified restore authorizes its member to mount")
    expect(!dock.permitsMount(.notes, restore: current) && !dock.completeMount(.notes, restore: current) &&
           dock.phase == .restoring(current), "wrong member cannot complete a restore mount")
    dock.discardRestore(refusedRestore)
    expect(!dock.permitsMount(.files, restore: refusedRestore) &&
           !dock.completeMount(.files, restore: refusedRestore) && dock.phase == .restoring(current),
           "stale same-member ticket cannot mount or discard a newer restore")
    expect(dock.beginReturn(.notes) == nil && !dock.completeReturn(current, nativeVerified: true) &&
           !dock.beginRestore(current, member: .files, nativeVerified: false) &&
           !dock.permitsMount(.files, restore: nil) && !dock.completeMount(.files, restore: nil) &&
           dock.phase == .restoring(current), "only the in-flight restore may mount")
    expect(dock.completeMount(.files, restore: current) && dock.phase == .idle,
           "matching mount consumes the restore")
    expect(!dock.beginRestore(current, member: .files, nativeVerified: true) &&
           !dock.permitsMount(.files, restore: current) && !dock.completeMount(.files, restore: current) &&
           dock.phase == .idle, "consumed ticket cannot be replayed from idle")

    let discarded = restore(.notes)
    dock.discardRestore(discarded)
    expect(dock.phase == .idle && !dock.completeMount(.notes, restore: discarded),
           "discarding a matching restore revokes mount")
    let canceled = restore(.files)
    dock.cancel()
    expect(!dock.completeMount(.files, restore: canceled) &&
           !dock.beginRestore(canceled, member: .files, nativeVerified: true) && dock.phase == .idle,
           "cancel during restore revokes mount and rejects retries")

    // A rotation offer and a dock restore are separate admission gates.
    guard rotation.recordMount(.notes, offer: nil), let route = rotation.beginReturn(from: .notes),
          rotation.finishReturn(route, verified: true, now: 10),
          let offer = rotation.offer(whenForeground: .files, now: 11) else {
        fatalError("DOCK FAIL: rotation offer setup")
    }
    expect(rotation.phase == .offered(offer) && rotation.lastMounted == .notes &&
           !rotation.permitsMount(.files, offer: nil), "a rotation offer does not record a destination mount")
    let alongsideOffer = park(.files)
    expect(rotation.permitsMount(.files, offer: offer) && !dock.permitsMount(.files, restore: nil) &&
           !dock.completeMount(.files, restore: alongsideOffer) && dock.isParked(alongsideOffer),
           "rotation admission does not bypass a parked dock")

    let pans: [(String, CGFloat, CGFloat, CGFloat, CGFloat, WorkspaceEdgeMotion.Direction?)] = [
        ("negative drag at 38 is up", 0, -38, 0, 0, .up),
        ("positive, vertically dominant drag wins over opposing velocity", 28, 38, 0, -800, .down),
        ("slow drag just below 38 is ignored", 0, 37, 0, 0, nil),
        ("horizontal displacement vetoes even a fast vertical flick", -29, -38, 0, -900, nil),
        ("up flick at both thresholds", 0, -16, 0, -480, .up),
        ("down flick at both thresholds with dominant vertical velocity", 0, 16, 355, 480, .down),
        ("speed cannot bypass the 16-point minimum", 0, 15, 0, 1200, nil),
        ("short drag with speed just under 480 is ignored", 0, -16, 0, -479, nil),
        ("flick must agree with drag direction", 0, 16, 0, -480, nil),
        ("horizontal velocity vetoes a short flick", 0, 16, -356, 480, nil),
        ("nonfinite offset x", .nan, 60, 0, 0, nil),
        ("nonfinite offset y", 0, .infinity, 0, 0, nil),
        ("nonfinite velocity x", 0, 60, -.infinity, 0, nil),
        ("nonfinite velocity y", 0, 60, 0, .nan, nil),
    ]
    for (label, x, y, vx, vy, expected) in pans {
        expect(WorkspaceEdgeMotion.direction(for: CGPoint(x: x, y: y),
                                             velocity: CGPoint(x: vx, y: vy)) == expected, label)
    }

    expect(WorkspaceEdgeMotion.decision(keyboard: .hidden, repeated: false) == .apply &&
           WorkspaceEdgeMotion.decision(keyboard: .hidden, repeated: true) == .apply,
           "hidden keyboard needs no confirmation")
    expect(WorkspaceEdgeMotion.decision(keyboard: .visible, repeated: false) == .finishEditing &&
           WorkspaceEdgeMotion.decision(keyboard: .visible, repeated: true) == .finishEditing,
           "visible keyboard blocks even a repeat")
    expect(WorkspaceEdgeMotion.decision(keyboard: .unknown, repeated: false) == .confirm,
           "unknown keyboard needs confirmation on first swipe")
    expect(WorkspaceEdgeMotion.decision(keyboard: .unknown, repeated: true) == .apply,
           "unknown keyboard allows a confirmed swipe")

    let bounds = CGRect(x: 12, y: 20, width: 230, height: 121)
    expect(WorkspaceEdgeMotion.dockFrame(in: bounds, bottomInset: 30) ==
           CGRect(x: 120, y: 111, width: 96, height: 16), "minimum inset leaves the bottom 14 points free")
    expect(WorkspaceEdgeMotion.dockFrame(in: bounds, bottomInset: 60) ==
           CGRect(x: 120, y: 107, width: 96, height: 20), "maximum inset caps height and keeps right margin")
    let badInsets: [CGFloat] = [-1, 29, 61, .nan, .infinity]
    expect(badInsets.allSatisfy { WorkspaceEdgeMotion.dockFrame(in: bounds, bottomInset: $0) == nil },
           "reject negative, out-of-range, and nonfinite insets")
    let badBounds: [CGRect] = [
        .zero, .null, .infinite,
        CGRect(x: 0, y: 0, width: 229, height: 121),
        CGRect(x: 0, y: 0, width: 230, height: 120),
        CGRect(x: 0, y: 0, width: -230, height: 121),
        CGRect(x: 0, y: 0, width: 230, height: -121),
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 121),
        CGRect(x: 0, y: 0, width: 230, height: CGFloat.nan),
        CGRect(x: CGFloat.nan, y: 0, width: 230, height: 121),
    ]
    expect(badBounds.allSatisfy { WorkspaceEdgeMotion.dockFrame(in: $0, bottomInset: 34) == nil },
           "reject degenerate, undersized, negative, and nonfinite bounds")

    expect(WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: 100, now: 100) &&
           WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: 100, now: 105.999), "repeat is current before expiry")
    expect(!WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: 100, now: 106), "repeat expires exactly at six seconds")
    expect(!WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: 100, now: 99.999) &&
           !WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: -1, now: 0), "backwards or negative monotonic time fails closed")
    expect(!WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: .nan, now: 100) &&
           !WorkspaceEdgeMotion.confirmationIsCurrent(issuedAt: 100, now: .infinity), "nonfinite repeat time is refused")
    expect(WorkspaceEdgeMotion.dockFrame(in: CGRect(x: 0, y: 0, width: 390, height: 844), bottomInset: 34) ==
           CGRect(x: 268, y: 810, width: 96, height: 20), "portrait tab stays in the bottom-right strip")

    let expectedChecks = 50
    guard checks == expectedChecks else {
        fatalError("DOCK FAIL: expected \(expectedChecks) checks, ran \(checks)")
    }
    print("PANDORA_DOCK_TESTS checks=\(checks) failures=0")
}
