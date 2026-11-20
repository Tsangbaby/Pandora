import Foundation

private typealias RotationTicket = WorkspaceRotation.Ticket
private var rotationChecks = 0
private var rotationFailures = 0

private func rotationCheck(_ condition: @autoclosure () -> Bool, _ label: String) {
    rotationChecks += 1
    if !condition() {
        rotationFailures += 1
        fputs("ROTATION FAIL: \(label)\n", stderr)
    }
}

private func rotationIsWaiting(_ phase: WorkspaceRotation.Phase,
                               ticket: RotationTicket,
                               issuedAt: TimeInterval) -> Bool {
    guard case .waiting(let actual, let issued, let deadline) = phase else { return false }
    return actual == ticket && issued == issuedAt && deadline == issuedAt + 30
}

private func discardRotationOffer(_ ticket: RotationTicket?, from rotation: inout WorkspaceRotation) {
    guard let ticket else { return }
    rotation.discardOffer(ticket)
}

func runRotationTests() {
    rotationChecks = 0
    rotationFailures = 0

    var rotation = WorkspaceRotation()
    rotationCheck(rotation.lastMounted == nil && rotation.beginReturn(from: .notes) == nil,
                  "unmounted workgroup cannot begin a return")
    rotationCheck(rotation.phase == .idle, "empty workgroup remains idle")
    rotationCheck(rotation.permitsMount(.notes, offer: nil), "idle mode permits explicit standalone preparation")
    rotationCheck(rotation.recordMount(.notes, offer: nil), "standalone notes mount records successfully")
    rotationCheck(rotation.lastMounted == .notes, "successful standalone mount commits notes")

    let staleTicket = rotation.beginReturn(from: .notes)
    rotationCheck(staleTicket.map {
        $0.source == .notes && $0.destination == .files && rotation.phase == .returning($0)
    } ?? false, "first direction issues a notes-to-files ticket")
    rotation.cancel()
    rotationCheck(rotation.phase == .idle && rotation.lastMounted == .notes &&
                  rotation.offer(whenForeground: .files, now: 1) == nil &&
                  !rotation.permitsMount(.files, offer: staleTicket),
                  "cancel while returning clears the route without revival")

    let currentTicket = rotation.beginReturn(from: .notes)
    rotationCheck(currentTicket.map { current in
        staleTicket.map { current != $0 } ?? false
    } ?? false, "new return receives a distinct fresh ticket")
    let earlyReturningMount = rotation.recordMount(.files, offer: nil)
    rotationCheck(!rotation.permitsMount(.files, offer: nil) && !earlyReturningMount &&
                  rotation.lastMounted == .notes,
                  "destination cannot mount while source is returning")

    let staleCompletionRejected = staleTicket.map {
        !rotation.finishReturn($0, verified: true, now: 100)
    } ?? false
    rotationCheck(staleCompletionRejected && (currentTicket.map {
        rotation.phase == .returning($0)
    } ?? false), "stale completion cannot finish a newer return")

    let freshCompletionAccepted = currentTicket.map {
        rotation.finishReturn($0, verified: true, now: 100)
    } ?? false
    rotationCheck(freshCompletionAccepted && (currentTicket.map {
        rotationIsWaiting(rotation.phase, ticket: $0, issuedAt: 100)
    } ?? false), "fresh verified completion arms a 30-second wait")

    let earlyWaitingMount = rotation.recordMount(.files, offer: nil)
    rotationCheck(!rotation.permitsMount(.files, offer: nil) && !earlyWaitingMount &&
                  rotation.lastMounted == .notes,
                  "destination cannot mount before foreground offer")

    let wrongForeground = rotation.offer(whenForeground: .notes, now: 101)
    rotationCheck(wrongForeground == nil && (currentTicket.map {
        rotationIsWaiting(rotation.phase, ticket: $0, issuedAt: 100)
    } ?? false), "wrong foreground leaves the wait unconsumed")
    let missingForeground = rotation.offer(whenForeground: nil, now: 102)
    rotationCheck(missingForeground == nil && (currentTicket.map {
        rotationIsWaiting(rotation.phase, ticket: $0, issuedAt: 100)
    } ?? false), "missing foreground is not treated as success")

    let freshOffer = rotation.offer(whenForeground: .files, now: 129.999)
    rotationCheck(freshOffer != nil && (currentTicket.map {
        freshOffer == $0 && rotation.phase == .offered($0)
    } ?? false), "correct foreground produces the fresh destination offer")
    rotationCheck(rotation.lastMounted == .notes && (currentTicket.map {
        rotation.phase == .offered($0)
    } ?? false), "offer alone does not commit the destination")
    rotationCheck(!rotation.permitsMount(.files, offer: nil), "offered route requires its ticket")

    discardRotationOffer(staleTicket, from: &rotation)
    rotationCheck(!rotation.permitsMount(.files, offer: staleTicket) && (currentTicket.map {
        rotation.phase == .offered($0)
    } ?? false), "wrong ticket cannot consume or authorize the offer")
    let wrongTicketMount = rotation.recordMount(.files, offer: staleTicket)
    rotationCheck(!wrongTicketMount && rotation.lastMounted == .notes,
                  "wrong ticket cannot commit the destination")

    let firstDirectionCommitted = currentTicket.map {
        rotation.recordMount(.files, offer: $0)
    } ?? false
    rotationCheck(firstDirectionCommitted, "matching offer successfully records files mount")
    rotationCheck(rotation.lastMounted == .files && rotation.phase == .idle,
                  "files becomes current only after successful recordMount")
    let staleOfferAfterCommit = rotation.offer(whenForeground: .files, now: 130)
    rotationCheck(staleOfferAfterCommit == nil &&
                  !rotation.permitsMount(.files, offer: currentTicket),
                  "consumed route cannot be revived by a stale offer")

    let reverseTicket = rotation.beginReturn(from: .files)
    rotationCheck(reverseTicket.map {
        $0.source == .files && $0.destination == .notes && rotation.phase == .returning($0)
    } ?? false, "reverse direction issues a files-to-notes ticket")
    let earlyReverseMount = rotation.recordMount(.notes, offer: nil)
    rotationCheck(!rotation.permitsMount(.notes, offer: nil) && !earlyReverseMount &&
                  rotation.lastMounted == .files,
                  "reverse destination cannot mount while files is returning")
    let reverseCompletionAccepted = reverseTicket.map {
        rotation.finishReturn($0, verified: true, now: 200)
    } ?? false
    rotationCheck(reverseCompletionAccepted && (reverseTicket.map {
        rotationIsWaiting(rotation.phase, ticket: $0, issuedAt: 200)
    } ?? false), "reverse verified completion arms its wait")
    let reverseOffer = rotation.offer(whenForeground: .notes, now: 200)
    rotationCheck(reverseOffer != nil && (reverseTicket.map {
        reverseOffer == $0 && rotation.phase == .offered($0)
    } ?? false), "reverse destination receives a fresh foreground offer")
    let reverseCommitted = reverseTicket.map {
        rotation.recordMount(.notes, offer: $0)
    } ?? false
    rotationCheck(reverseCommitted && rotation.lastMounted == .notes && rotation.phase == .idle,
                  "successful reverse recordMount commits notes")

    let waitingCancelTicket = rotation.beginReturn(from: .notes)
    let waitingCancelArmed = waitingCancelTicket.map {
        rotation.finishReturn($0, verified: true, now: 300)
    } ?? false
    let wasWaitingForCancel = waitingCancelTicket.map {
        rotationIsWaiting(rotation.phase, ticket: $0, issuedAt: 300)
    } ?? false
    rotation.cancel()
    let offerAfterWaitingCancel = rotation.offer(whenForeground: .files, now: 301)
    rotationCheck(waitingCancelArmed && wasWaitingForCancel && rotation.phase == .idle &&
                  offerAfterWaitingCancel == nil &&
                  !rotation.permitsMount(.files, offer: waitingCancelTicket),
                  "cancel while waiting discards the route permanently")

    let offeredCancelTicket = rotation.beginReturn(from: .notes)
    let offeredCancelValue = offeredCancelTicket.flatMap { ticket -> RotationTicket? in
        guard rotation.finishReturn(ticket, verified: true, now: 400) else { return nil }
        return rotation.offer(whenForeground: .files, now: 401)
    }
    let hadFreshOfferToCancel = offeredCancelTicket.map {
        offeredCancelValue == $0 && rotation.phase == .offered($0)
    } ?? false
    rotation.cancel()
    let mountAfterOfferedCancel = rotation.recordMount(.files, offer: offeredCancelTicket)
    let offerAfterOfferedCancel = rotation.offer(whenForeground: .files, now: 402)
    rotationCheck(hadFreshOfferToCancel && rotation.phase == .idle &&
                  !mountAfterOfferedCancel && rotation.lastMounted == .notes &&
                  offerAfterOfferedCancel == nil,
                  "cancel while offered rejects mount and prevents route revival")

    let failedCleanupTicket = rotation.beginReturn(from: .notes)
    let cleanupFailed = failedCleanupTicket.map {
        !rotation.finishReturn($0, verified: false, now: 500)
    } ?? false
    let offerAfterCleanupFailure = rotation.offer(whenForeground: .files, now: 501)
    rotationCheck(cleanupFailed && rotation.phase == .idle && rotation.lastMounted == .notes &&
                  offerAfterCleanupFailure == nil &&
                  !rotation.permitsMount(.files, offer: failedCleanupTicket),
                  "cleanup failure clears the route without changing selection")

    let deadlineTicket = rotation.beginReturn(from: .notes)
    let deadlineArmed = deadlineTicket.map {
        rotation.finishReturn($0, verified: true, now: 600)
    } ?? false
    let atExactDeadline = rotation.offer(whenForeground: .files, now: 630)
    rotationCheck(deadlineArmed && atExactDeadline == nil && rotation.phase == .idle &&
                  rotation.lastMounted == .notes &&
                  !rotation.permitsMount(.files, offer: deadlineTicket),
                  "offer expires exactly at the 30-second deadline")

    let nonfiniteCompletionTicket = rotation.beginReturn(from: .notes)
    let nonfiniteCompletionRejected = nonfiniteCompletionTicket.map {
        !rotation.finishReturn($0, verified: true, now: .nan)
    } ?? false
    rotationCheck(nonfiniteCompletionRejected && rotation.phase == .idle &&
                  rotation.lastMounted == .notes,
                  "non-finite completion clock cannot arm a route")

    let nonfiniteOfferTicket = rotation.beginReturn(from: .notes)
    let nonfiniteOfferArmed = nonfiniteOfferTicket.map {
        rotation.finishReturn($0, verified: true, now: 700)
    } ?? false
    let nonfiniteOffer = rotation.offer(whenForeground: .files, now: .infinity)
    rotationCheck(nonfiniteOfferArmed && nonfiniteOffer == nil && rotation.phase == .idle &&
                  rotation.lastMounted == .notes,
                  "non-finite foreground clock discards the waiting route")

    let backwardsTicket = rotation.beginReturn(from: .notes)
    let backwardsArmed = backwardsTicket.map {
        rotation.finishReturn($0, verified: true, now: 800)
    } ?? false
    let backwardsOffer = rotation.offer(whenForeground: .files, now: 799.999)
    rotationCheck(backwardsArmed && backwardsOffer == nil && rotation.phase == .idle &&
                  rotation.lastMounted == .notes,
                  "backwards clock discontinuity discards the waiting route")

    let summary = "PANDORA_ROTATION_TESTS checks=\(rotationChecks) failures=\(rotationFailures)"
    print(summary)
    if rotationFailures != 0 {
        fatalError("workspace rotation regression checks failed")
    }
}
