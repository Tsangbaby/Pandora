// A+B product state and geometry only. This model does NOT host or create an App Scene.
// A UI adapter may set .dualSceneVerified only after separately proving two real live Scenes.
import Foundation
import CoreGraphics

struct WorkspaceMemberID: Hashable, CustomStringConvertible {
    let rawValue: String
    init?(_ rawValue: String) {
        let scalars = rawValue.unicodeScalars
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128,
              scalars.allSatisfy({ $0.value >= 0x20 && !((0x7f...0x9f).contains($0.value)) }) else { return nil }
        self.rawValue = rawValue
    }
    var description: String { rawValue }
}

enum WorkspaceAxis: Equatable { case vertical, horizontal }
enum WorkspaceArrangement: Equatable { case rotation, sideBySide(axis: WorkspaceAxis, ratio: CGFloat) }
enum WorkspaceHostingCapability: Equatable { case singleSceneOnly, dualSceneVerified }
enum WorkspaceVisibility: Equatable { case visible, docked }
enum WorkspaceNotice: Equatable {
    case incompatibleDualHosting, insufficientReadableSpace, replacementPreparationFailed
}
enum WorkspaceLayoutFailure: Error, Equatable {
    case invalidGeometry, insufficientSpace, invalidRatio, incompatibleDualHosting
    case staleTransaction, memberAlreadyPresent, transactionBusy, noWorkspace
    case dockedInputRefused, inputMemberUnavailable, focusMustBeReleasedBeforeDock
    case focusTransferRequiresRelease
    case swapRequiresSideBySide
}
enum WorkspaceArrangementResult: Equatable {
    case applied(WorkspaceArrangement)
    case fellBackToRotation(WorkspaceNotice)
}

struct WorkspaceGeometry: Equatable {
    let canvas: CGRect
    let safeInsets: WorkspaceInsets
    let panelBottom: CGFloat // Bottom edge in canvas coordinates.
    let keyboardBottomObstruction: CGFloat // Confirmed outside obstruction, not a notification height.
    let minimumCardSize: CGSize
    let minimumReadableScale: CGFloat
}
struct WorkspaceInsets: Equatable { let top, left, bottom, right: CGFloat }

// Measurements for the two current physical slots, not screen previews.
struct WorkspaceSplitSpace {
    let geometry: WorkspaceGeometry
    let firstSource: CGSize
    let secondSource: CGSize
}

struct WorkspaceCardRects: Equatable {
    let primary: CGRect
    let secondary: CGRect?
    let primaryRegion: CGRect
    let secondaryRegion: CGRect?
}

struct WorkspacePairGeometry {
    static func rotation(_ g: WorkspaceGeometry, source: CGSize) -> Result<WorkspaceCardRects, WorkspaceLayoutFailure> {
        guard valid(g), finitePositive(source) else { return .failure(.invalidGeometry) }
        guard let region = available(g),
              let primary = fit(source, in: region, minimum: g.minimumCardSize, floor: g.minimumReadableScale) else {
            return .failure(.insufficientSpace)
        }
        return .success(WorkspaceCardRects(primary: primary, secondary: nil, primaryRegion: region, secondaryRegion: nil))
    }

    static func sideBySide(_ g: WorkspaceGeometry, primary: CGSize, secondary: CGSize,
                           axis: WorkspaceAxis, ratio: CGFloat) -> Result<WorkspaceCardRects, WorkspaceLayoutFailure> {
        guard valid(g), finitePositive(primary), finitePositive(secondary) else { return .failure(.invalidGeometry) }
        guard ratio.isFinite, ratio > 0, ratio < 1 else { return .failure(.invalidRatio) }
        guard let r = available(g) else { return .failure(.insufficientSpace) }
        let gap: CGFloat = 12
        let p: CGRect, s: CGRect
        switch axis {
        case .vertical:
            let usable = r.height-gap
            guard usable > 0 else { return .failure(.insufficientSpace) }
            let h1=floor(usable*ratio), h2=usable-h1
            p=CGRect(x:r.minX,y:r.minY,width:r.width,height:h1)
            s=CGRect(x:r.minX,y:r.minY+h1+gap,width:r.width,height:h2)
        case .horizontal:
            let usable=r.width-gap
            guard usable > 0 else { return .failure(.insufficientSpace) }
            let w1=floor(usable*ratio), w2=usable-w1
            p=CGRect(x:r.minX,y:r.minY,width:w1,height:r.height)
            s=CGRect(x:r.minX+w1+gap,y:r.minY,width:w2,height:r.height)
        }
        guard let pf=fit(primary,in:p,minimum:g.minimumCardSize,floor:g.minimumReadableScale),
              let sf=fit(secondary,in:s,minimum:g.minimumCardSize,floor:g.minimumReadableScale) else {
            return .failure(.insufficientSpace)
        }
        return .success(WorkspaceCardRects(primary:pf,secondary:sf,primaryRegion:p,secondaryRegion:s))
    }

    private static func available(_ g: WorkspaceGeometry) -> CGRect? {
        let left = g.canvas.minX + g.safeInsets.left + 12
        let top = max(g.canvas.minY + g.safeInsets.top, g.panelBottom) + 12
        let right = g.canvas.maxX - g.safeInsets.right - 12
        let bottom = g.canvas.maxY - max(g.safeInsets.bottom, g.keyboardBottomObstruction) - 12
        let width = right - left, height = bottom - top
        guard [left, top, right, bottom, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return CGRect(x: left, y: top, width: width, height: height)
    }
    private static func valid(_ g: WorkspaceGeometry) -> Bool {
        let v = [g.canvas.origin.x, g.canvas.origin.y, g.canvas.size.width, g.canvas.size.height,
                 g.safeInsets.top, g.safeInsets.left, g.safeInsets.bottom, g.safeInsets.right,
                 g.panelBottom, g.keyboardBottomObstruction, g.minimumCardSize.width,
                 g.minimumCardSize.height, g.minimumReadableScale]
        return !g.canvas.isNull && !g.canvas.isInfinite && v.allSatisfy(\.isFinite) && finitePositive(g.canvas.size) &&
            g.safeInsets.top >= 0 && g.safeInsets.left >= 0 && g.safeInsets.bottom >= 0 && g.safeInsets.right >= 0 &&
            g.keyboardBottomObstruction >= 0 && finitePositive(g.minimumCardSize) &&
            g.minimumReadableScale > 0 && g.minimumReadableScale <= 1
    }
    private static func finitePositive(_ s: CGSize) -> Bool {
        s.width.isFinite && s.height.isFinite && s.width > 0 && s.height > 0
    }
    private static func fit(_ source: CGSize, in target: CGRect, minimum: CGSize, floor scaleFloor: CGFloat) -> CGRect? {
        guard target.size.width >= minimum.width, target.size.height >= minimum.height else { return nil }
        let scale = min(1, target.size.width / source.width, target.size.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        guard scale >= scaleFloor, size.width >= minimum.width, size.height >= minimum.height else { return nil }
        return CGRect(x: target.minX + (target.width - size.width) / 2,
                      y: target.minY + (target.height - size.height) / 2, width: size.width, height: size.height)
    }
}

struct WorkspaceTransaction: Equatable {
    enum Kind: Equatable { case replacePartner }
    let identifier: UInt64
    let generation: UInt64
    let kind: Kind
    let oldPartner: WorkspaceMemberID
    let candidate: WorkspaceMemberID
}

struct WorkspaceState: Equatable {
    enum Mode: Equatable { case unconfigured, ready, pending(WorkspaceTransaction), blocked }
    private(set) var primary: WorkspaceMemberID?
    private(set) var partner: WorkspaceMemberID?
    private(set) var mainTask: WorkspaceMemberID?
    private(set) var arrangement: WorkspaceArrangement = .rotation
    private(set) var capability: WorkspaceHostingCapability = .singleSceneOnly
    private(set) var visibility: WorkspaceVisibility = .visible
    private(set) var inputOwner: WorkspaceMemberID?
    private(set) var generation: UInt64 = 0
    private(set) var mode: Mode = .unconfigured
    private(set) var lastNotice: WorkspaceNotice?
    private(set) var lastTransactionIdentifier: UInt64 = 0

    var isConfigured: Bool { primary != nil && partner != nil && mode != .unconfigured && mode != .blocked }
    var isDocked: Bool { visibility == .docked }
    var secondaryIsPreviewOnly: Bool { arrangement == .rotation }

    mutating func configure(primary a: WorkspaceMemberID, partner b: WorkspaceMemberID) throws {
        guard case .unconfigured = mode else { throw WorkspaceLayoutFailure.transactionBusy }
        guard a != b else { throw WorkspaceLayoutFailure.memberAlreadyPresent }
        generation &+= 1
        primary=a; partner=b; mainTask=a; arrangement = .rotation; capability = .singleSceneOnly
        visibility = .visible; inputOwner=nil; lastNotice=nil; mode = .ready
    }

    mutating func setCapability(_ value: WorkspaceHostingCapability) throws {
        guard case .ready = mode else { throw WorkspaceLayoutFailure.transactionBusy }
        if case .sideBySide = arrangement, value == .singleSceneOnly,
           let owner=inputOwner, owner != mainTask {
            throw WorkspaceLayoutFailure.focusTransferRequiresRelease
        }
        capability=value
        if case .sideBySide = arrangement, value == .singleSceneOnly {
            arrangement = .rotation; generation &+= 1
            lastNotice = .incompatibleDualHosting
        } else {
            generation &+= 1
        }
    }

    mutating func setArrangement(_ requested: WorkspaceArrangement,
                                 in space: WorkspaceSplitSpace? = nil) throws -> WorkspaceArrangementResult {
        guard case .ready = mode, isConfigured else { throw WorkspaceLayoutFailure.transactionBusy }
        if case .sideBySide(let axis, let ratio) = requested {
            guard ratio.isFinite, ratio > 0, ratio < 1 else { throw WorkspaceLayoutFailure.invalidRatio }
            guard capability == .dualSceneVerified else { return try fallBack(.incompatibleDualHosting) }
            guard let space else { return try fallBack(.insufficientReadableSpace) }
            switch WorkspacePairGeometry.sideBySide(space.geometry, primary: space.firstSource,
                                                     secondary: space.secondSource, axis: axis, ratio: ratio) {
            case .success: break
            case .failure(.insufficientSpace): return try fallBack(.insufficientReadableSpace)
            case .failure(let error): throw error
            }
        } else if let owner = inputOwner, owner != mainTask {
            throw WorkspaceLayoutFailure.focusTransferRequiresRelease
        }
        arrangement = requested
        generation &+= 1; lastNotice = nil
        return .applied(requested)
    }

    private mutating func fallBack(_ reason: WorkspaceNotice) throws -> WorkspaceArrangementResult {
        guard inputOwner == nil || inputOwner == mainTask else {
            throw WorkspaceLayoutFailure.focusTransferRequiresRelease
        }
        arrangement = .rotation
        generation &+= 1
        lastNotice = reason
        return .fellBackToRotation(reason)
    }

    mutating func selectMainTask(_ member: WorkspaceMemberID) throws {
        guard case .ready = mode else { throw WorkspaceLayoutFailure.transactionBusy }
        guard let a=primary, let b=partner else { throw WorkspaceLayoutFailure.noWorkspace }
        guard member == a || member == b else { throw WorkspaceLayoutFailure.inputMemberUnavailable }
        if mainTask != member {
            if case .rotation = arrangement, inputOwner != nil { throw WorkspaceLayoutFailure.focusTransferRequiresRelease }
            mainTask=member
            generation &+= 1
        }
    }

    mutating func swapPositions(in space: WorkspaceSplitSpace? = nil) throws {
        guard case .ready = mode else { throw WorkspaceLayoutFailure.transactionBusy }
        guard let a = primary, let b = partner else { throw WorkspaceLayoutFailure.noWorkspace }
        guard case .sideBySide(let axis, let ratio) = arrangement else {
            throw WorkspaceLayoutFailure.swapRequiresSideBySide
        }
        guard let space else { throw WorkspaceLayoutFailure.insufficientSpace }
        _ = try WorkspacePairGeometry.sideBySide(space.geometry, primary: space.secondSource,
                                                 secondary: space.firstSource, axis: axis, ratio: ratio).get()
        primary = b; partner = a; generation &+= 1
        // Position exchange itself never transfers input ownership.
    }

    mutating func requestInput(for member: WorkspaceMemberID) throws {
        guard case .ready = mode else { throw WorkspaceLayoutFailure.transactionBusy }
        guard let a=primary, let b=partner else { throw WorkspaceLayoutFailure.noWorkspace }
        guard visibility == .visible else { throw WorkspaceLayoutFailure.dockedInputRefused }
        guard member == a || member == b else { throw WorkspaceLayoutFailure.inputMemberUnavailable }
        if case .rotation = arrangement, member != mainTask { throw WorkspaceLayoutFailure.inputMemberUnavailable }
        if case .sideBySide = arrangement, capability != .dualSceneVerified { throw WorkspaceLayoutFailure.incompatibleDualHosting }
        if let current=inputOwner, current != member { throw WorkspaceLayoutFailure.focusTransferRequiresRelease }
        inputOwner=member
    }
    mutating func endInput() { inputOwner=nil }

    mutating func dock() throws {
        guard case .ready = mode, isConfigured else { throw WorkspaceLayoutFailure.transactionBusy }
        guard inputOwner == nil else { throw WorkspaceLayoutFailure.focusMustBeReleasedBeforeDock }
        visibility = .docked; generation &+= 1
        // Hides the group only. Never claims to stop/kill a member App or native session.
    }

    mutating func restoreFromDock() throws {
        guard case .ready = mode, visibility == .docked else { throw WorkspaceLayoutFailure.transactionBusy }
        visibility = .visible; inputOwner=nil; generation &+= 1
        // Restoring a visible group never implicitly requests focus.
    }

    mutating func beginPartnerReplacement(_ candidate: WorkspaceMemberID, transactionID: UInt64) throws -> WorkspaceTransaction {
        guard case .ready = mode, let a=primary, let b=partner, let main=mainTask else {
            throw WorkspaceLayoutFailure.noWorkspace
        }
        guard candidate != a, candidate != b else { throw WorkspaceLayoutFailure.memberAlreadyPresent }
        guard transactionID > lastTransactionIdentifier else { throw WorkspaceLayoutFailure.transactionBusy }
        let old = (main == a ? b : a)
        guard inputOwner != old else { throw WorkspaceLayoutFailure.focusTransferRequiresRelease }
        generation &+= 1; lastTransactionIdentifier=transactionID
        let transaction=WorkspaceTransaction(identifier:transactionID,generation:generation,kind:.replacePartner,
            oldPartner:old,candidate:candidate)
        mode = .pending(transaction); return transaction
    }

    mutating func commitPartnerReplacement(_ t: WorkspaceTransaction, prepared: Bool) throws {
        guard case .pending(let active)=mode, active==t, t.generation==generation,
              primary==t.oldPartner || partner==t.oldPartner else { throw WorkspaceLayoutFailure.staleTransaction }
        guard prepared else {
            // Preparation failure leaves both old sessions and their existing
            // arrangement/compatibility/focus untouched.
            lastNotice = .replacementPreparationFailed
            generation &+= 1; mode = .ready
            return
        }
        if primary == t.oldPartner { primary=t.candidate }
        else if partner == t.oldPartner { partner=t.candidate }
        else { throw WorkspaceLayoutFailure.staleTransaction }
        if mainTask == t.oldPartner { mainTask=t.candidate }
        if inputOwner==t.oldPartner { inputOwner=nil }
        capability = .singleSceneOnly
        if case .sideBySide = arrangement {
            arrangement = .rotation
            if inputOwner != mainTask { inputOwner=nil }
            lastNotice = .incompatibleDualHosting
        } else { lastNotice=nil }
        generation &+= 1; mode = .ready
    }

    mutating func cancel(_ t: WorkspaceTransaction) throws {
        guard case .pending(let active)=mode, active==t, t.generation==generation,
              primary==t.oldPartner || partner==t.oldPartner else { throw WorkspaceLayoutFailure.staleTransaction }
        generation &+= 1; mode = .ready
    }

    mutating func setCleanupBlocked() {
        generation &+= 1
        mode = .blocked
        inputOwner = nil
        capability = .singleSceneOnly
        arrangement = .rotation
    }

    mutating func resolveCleanup() {
        guard case .blocked = mode else { return }
        generation &+= 1
        mode = primary == nil ? .unconfigured : .ready
    }
}
