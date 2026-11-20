import Foundation

// One fixed pair. Scene objects, ownership, and actual focus stay in the adapter.
// `lastMounted` is a logical selection, not evidence a Scene is still hosted.
struct WorkspaceRotation {
    enum Member: Equatable {
        case notes, files

        var partner: Member { self == .notes ? .files : .notes }
        fileprivate var identity: WorkspaceMemberID {
            // These fixed identifiers satisfy WorkspaceMemberID's validation.
            WorkspaceMemberID(self == .notes ? "notes" : "files")!
        }
    }

    struct Ticket: Equatable {
        fileprivate let serial: UInt64
        let source: Member
        var destination: Member { source.partner }
    }

    enum Phase: Equatable {
        case idle
        case returning(Ticket)
        case waiting(Ticket, issuedAt: TimeInterval, deadline: TimeInterval)
        case offered(Ticket)
    }

    private var group = WorkspaceState()
    private var serial: UInt64 = 0
    private(set) var phase: Phase = .idle

    var lastMounted: Member? {
        guard let main = group.mainTask else { return nil }
        return main == Member.notes.identity ? .notes : .files
    }

    var waitingFor: Member? {
        guard case .waiting(let ticket, _, _) = phase else { return nil }
        return ticket.destination
    }

    func permitsMount(_ member: Member, offer: Ticket?) -> Bool {
        switch (phase, offer) {
        case (.idle, nil): return true // Explicit standalone preparation.
        case (.offered(let current), .some(let ticket)):
            return ticket == current && member == current.destination
        default: return false
        }
    }

    // The adapter calls this only after activation AND post-activation layout readback.
    mutating func recordMount(_ member: Member, offer: Ticket?) -> Bool {
        guard permitsMount(member, offer: offer) else { return false }
        var candidate = group
        do {
            if !candidate.isConfigured {
                try candidate.configure(primary: Member.notes.identity, partner: Member.files.identity)
            }
            try candidate.selectMainTask(member.identity)
        } catch { return false }
        group = candidate
        phase = .idle
        return true
    }

    mutating func beginReturn(from member: Member) -> Ticket? {
        guard phase == .idle, lastMounted == member, serial < UInt64.max else { return nil }
        serial += 1
        let ticket = Ticket(serial: serial, source: member)
        phase = .returning(ticket)
        return ticket
    }

    // Release the old host, verify its original native structure, and remove its
    // panel before returning verified=true. Failure does not retry or arm a route.
    mutating func finishReturn(_ ticket: Ticket, verified: Bool, now: TimeInterval) -> Bool {
        guard phase == .returning(ticket) else { return false }
        let deadline = now + 30
        guard verified, now >= 0, deadline.isFinite, deadline > now else {
            phase = .idle
            return false
        }
        phase = .waiting(ticket, issuedAt: now, deadline: deadline)
        return true
    }

    // The clock is monotonic uptime. A missed/wrong foreground is never evidence
    // of success; at the deadline or a clock discontinuity discard the route.
    mutating func offer(whenForeground member: Member?, now: TimeInterval) -> Ticket? {
        guard case .waiting(let ticket, let issuedAt, let deadline) = phase else { return nil }
        guard now >= issuedAt, now < deadline else { phase = .idle; return nil }
        guard member == ticket.destination else { return nil }
        phase = .offered(ticket)
        return ticket
    }

    mutating func discardOffer(_ ticket: Ticket) {
        if phase == .offered(ticket) { phase = .idle }
    }

    mutating func cancel() { phase = .idle }
}
