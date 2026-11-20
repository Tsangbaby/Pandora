import Foundation
import CoreGraphics

private var workspaceChecks = 0
private var workspaceFailures = 0
private func workspaceCheck(_ condition: @autoclosure () -> Bool, _ label: String) {
    workspaceChecks += 1
    if !condition() { workspaceFailures += 1; fputs("WORKSPACE FAIL: \(label)\n", stderr) }
}
private func member(_ value: String) -> WorkspaceMemberID { WorkspaceMemberID(value)! }
private func expectWorkspaceError(_ expected: WorkspaceLayoutFailure, _ body: () throws -> Void) {
    do { try body(); workspaceCheck(false, "expected \(expected)") }
    catch let error as WorkspaceLayoutFailure { workspaceCheck(error == expected, "error \(expected)") }
    catch { workspaceCheck(false, "wrong error type") }
}

func runWorkspaceTests() {
    let a=member("notes-a"), b=member("browser-b"), c=member("reader-c"), d=member("calendar-d")
    let g = WorkspaceGeometry(canvas: CGRect(x: 0, y: 0, width: 390, height: 844),
                              safeInsets: WorkspaceInsets(top: 59, left: 0, bottom: 34, right: 0), panelBottom: 132,
                              keyboardBottomObstruction: 0, minimumCardSize: CGSize(width: 120, height: 120),
                              minimumReadableScale: 0.4)
    let compactSource = CGSize(width: 220, height: 390)
    let splitSpace = WorkspaceSplitSpace(geometry: g, firstSource: compactSource, secondSource: compactSource)
    let tooWide = WorkspaceSplitSpace(geometry: g, firstSource: CGSize(width: 1000, height: 2200), secondSource: compactSource)
    workspaceCheck(WorkspaceMemberID("")==nil, "empty identity refused")
    workspaceCheck(WorkspaceMemberID(String(repeating:"x",count:129))==nil, "oversized identity refused")
    workspaceCheck(WorkspaceMemberID("a\u{7f}b")==nil, "control-containing identity refused")
    var s=WorkspaceState()
    workspaceCheck(!s.isConfigured, "starts without persisted process claims")
    expectWorkspaceError(.memberAlreadyPresent){try s.configure(primary:a,partner:a)}
    workspaceCheck(!s.isConfigured, "invalid initial group does not partially publish")
    try! s.configure(primary:a,partner:b)
    workspaceCheck(s.isConfigured && s.mode == .ready, "valid descriptor configures")
    workspaceCheck(s.primary==a && s.partner==b, "stable A/B identity retained")
    workspaceCheck(s.arrangement == .rotation && s.secondaryIsPreviewOnly, "large-card rotation is default")
    workspaceCheck(s.capability == .singleSceneOnly, "second live Scene is never assumed")
    workspaceCheck(s.visibility == .visible && s.inputOwner==nil, "preview starts nonfocused")
    expectWorkspaceError(.transactionBusy){try s.configure(primary:c,partner:d)}
    workspaceCheck(s.primary==a && s.partner==b, "reconfigure cannot silently replace group")

    let fallback=try! s.setArrangement(.sideBySide(axis:.vertical,ratio:0.5))
    workspaceCheck(fallback == .fellBackToRotation(.incompatibleDualHosting), "split refuses without verified dual adapter")
    workspaceCheck(s.arrangement == .rotation && s.lastNotice == .incompatibleDualHosting, "fallback reason is explicit")
    try! s.selectMainTask(b)
    workspaceCheck(s.primary==a && s.partner==b && s.mainTask==b, "explicit main-task selection is distinct from slot order")
    workspaceCheck(s.inputOwner==nil, "main selection never auto-grants keyboard focus")
    expectWorkspaceError(.swapRequiresSideBySide){try s.swapPositions()}
    workspaceCheck(s.primary==a && s.partner==b, "rotation main selection is not mislabeled as physical position swap")
    try! s.requestInput(for:b)
    workspaceCheck(s.inputOwner==b, "one explicit rotation input owner")
    expectWorkspaceError(.inputMemberUnavailable){try s.requestInput(for:a)}
    workspaceCheck(s.inputOwner==b, "rotation preview cannot become a second input owner")
    expectWorkspaceError(.inputMemberUnavailable){try s.requestInput(for:c)}
    workspaceCheck(s.inputOwner==b, "foreign member cannot receive focus")
    expectWorkspaceError(.focusTransferRequiresRelease){try s.selectMainTask(a)}
    workspaceCheck(s.mainTask==b && s.inputOwner==b, "rotation with active input refuses to change the live member")
    s.endInput()
    workspaceCheck(s.inputOwner==nil, "ending input clears owner")

    try! s.setCapability(.dualSceneVerified) // Test adapter flag only; no device capability claimed.
    let noMeasurement = try! s.setArrangement(.sideBySide(axis: .vertical, ratio: 0.37))
    workspaceCheck(noMeasurement == .fellBackToRotation(.insufficientReadableSpace), "dual capability cannot replace a layout measurement")
    let noRoom = try! s.setArrangement(.sideBySide(axis: .horizontal, ratio: 0.5), in: tooWide)
    workspaceCheck(noRoom == .fellBackToRotation(.insufficientReadableSpace) && s.arrangement == .rotation,
                   "unreadable measured space keeps the old large-card mode")
    let beforeInvalid = s
    expectWorkspaceError(.invalidRatio){_ = try s.setArrangement(.sideBySide(axis: .vertical, ratio: .nan), in: splitSpace)}
    workspaceCheck(s == beforeInvalid, "invalid ratio cannot partially update the workgroup")
    let split=try! s.setArrangement(.sideBySide(axis:.vertical,ratio:0.37), in: splitSpace)
    workspaceCheck(split == .applied(.sideBySide(axis:.vertical,ratio:0.37)), "explicit verified-compatible split accepted")
    try! s.requestInput(for:a)
    try! s.selectMainTask(a)
    workspaceCheck(s.primary==a && s.partner==b && s.mainTask==a && s.inputOwner==a,
                   "main selection in split does not change position or input ownership")
    try! s.selectMainTask(b)
    let beforeUnusableSwap = s
    expectWorkspaceError(.insufficientSpace){try s.swapPositions(in: tooWide)}
    workspaceCheck(s == beforeUnusableSwap, "unreadable exchange preserves slots and focus exactly")
    try! s.swapPositions(in: splitSpace)
    workspaceCheck(s.primary==b && s.partner==a && s.mainTask==b && s.inputOwner==a,
                   "physical slot swap preserves main task and exact focused member")
    expectWorkspaceError(.focusTransferRequiresRelease){_ = try s.setArrangement(.rotation)}
    expectWorkspaceError(.focusTransferRequiresRelease){try s.requestInput(for:b)}
    workspaceCheck(s.inputOwner==a, "second App cannot receive focus before explicit release")
    s.endInput()
    try! s.requestInput(for:b)
    workspaceCheck(s.inputOwner==b, "explicit release then request transfers the sole input owner")
    try! s.selectMainTask(a)
    workspaceCheck(s.mainTask==a && s.inputOwner==b, "side-by main selection leaves the other member's active input untouched")
    expectWorkspaceError(.focusTransferRequiresRelease){_ = try s.beginPartnerReplacement(c,transactionID:1)}
    workspaceCheck(s.primary==b && s.partner==a && s.inputOwner==b, "focused member cannot be replaced while it owns input")
    s.endInput()
    try! s.requestInput(for:a)
    try! s.setCapability(.singleSceneOnly)
    workspaceCheck(s.arrangement == .rotation && s.inputOwner==a, "capability loss retains only the current main owner's focus")
    workspaceCheck(s.lastNotice == .incompatibleDualHosting, "capability fallback remains observable")

    // Atomic replacement: old identity survives every failure/cancel/stale callback.
    try! s.selectMainTask(a)
    try! s.requestInput(for:a)
    let failed=try! s.beginPartnerReplacement(c,transactionID:1)
    workspaceCheck(s.mode == .pending(failed), "partner prepare has explicit transaction identity")
    expectWorkspaceError(.transactionBusy){try s.selectMainTask(b)}
    try! s.commitPartnerReplacement(failed,prepared:false)
    workspaceCheck(s.primary==b && s.partner==a, "failed replacement retains the existing physical slot order")
    workspaceCheck(s.inputOwner==a, "failed replacement preserves unrelated owner")
    workspaceCheck(s.lastNotice == .replacementPreparationFailed, "replacement failure is observable")
    workspaceCheck(s.mode == .ready, "failed replacement exits pending state")
    expectWorkspaceError(.staleTransaction){try s.commitPartnerReplacement(failed,prepared:true)}
    workspaceCheck(s.primary==b && s.partner==a, "late completion cannot revive failed candidate")
    expectWorkspaceError(.memberAlreadyPresent){_ = try s.beginPartnerReplacement(a,transactionID:2)}
    expectWorkspaceError(.memberAlreadyPresent){_ = try s.beginPartnerReplacement(b,transactionID:2)}
    let cancelCandidate=try! s.beginPartnerReplacement(d,transactionID:2)
    try! s.cancel(cancelCandidate)
    workspaceCheck(s.primary==b && s.partner==a && s.mode == .ready, "cancel preserves old partner and slot order")
    expectWorkspaceError(.staleTransaction){try s.commitPartnerReplacement(cancelCandidate,prepared:true)}
    let success=try! s.beginPartnerReplacement(c,transactionID:3)
    try! s.commitPartnerReplacement(success,prepared:true)
    workspaceCheck(s.primary==c && s.partner==a && s.mainTask==a, "successful transaction replaces the non-main task in place")
    workspaceCheck(s.inputOwner==a, "successful partner replacement preserves unrelated focus")
    expectWorkspaceError(.staleTransaction){try s.commitPartnerReplacement(success,prepared:true)}
    expectWorkspaceError(.transactionBusy){_ = try s.beginPartnerReplacement(d,transactionID:3)}
    let next=try! s.beginPartnerReplacement(d,transactionID:4)
    try! s.commitPartnerReplacement(next,prepared:true)
    workspaceCheck(s.primary==d && s.partner==a && s.mainTask==a, "fresh transaction replaces the current non-main identity")
    workspaceCheck(s.mode == .ready, "replacement transaction commits exactly once")

    try! s.setCapability(.dualSceneVerified)
    _ = try! s.setArrangement(.sideBySide(axis:.horizontal,ratio:0.63), in: splitSpace)
    s.endInput()
    try! s.requestInput(for:d)
    workspaceCheck(s.inputOwner==d, "single focus owner may target explicitly selected partner")
    expectWorkspaceError(.focusMustBeReleasedBeforeDock){try s.dock()}
    workspaceCheck(s.visibility == .visible && s.inputOwner==d, "dock refusal leaves visible group and focus unchanged")
    s.endInput()
    try! s.dock()
    workspaceCheck(s.isDocked && s.visibility == .docked, "whole group visibility docks")
    workspaceCheck(s.arrangement == .sideBySide(axis:.horizontal,ratio:0.63), "dock preserves underlying arrangement")
    workspaceCheck(s.inputOwner==nil, "dock does not leave hidden effective focus owner")
    expectWorkspaceError(.dockedInputRefused){try s.requestInput(for:a)}
    _ = try! s.setArrangement(.rotation)
    workspaceCheck(s.isDocked && s.arrangement == .rotation, "explicit layout preference can change while docked")
    try! s.restoreFromDock()
    workspaceCheck(!s.isDocked && s.arrangement == .rotation, "restore preserves later user arrangement")
    workspaceCheck(s.inputOwner==nil, "restore never steals focus")
    try! s.dock()
    try! s.restoreFromDock()
    workspaceCheck(s.mode == .ready && s.isConfigured, "repeated dock/restore is deterministic")

    let one=WorkspacePairGeometry.rotation(g,source:CGSize(width:390,height:520))
    workspaceCheck({if case .success(let x)=one{return x.primary.width>0 && x.secondary==nil};return false}(),
                   "rotation yields a single primary region")
    let v=WorkspacePairGeometry.sideBySide(g,primary:CGSize(width:390,height:520),secondary:CGSize(width:390,height:520),axis:.vertical,ratio:0.61)
    workspaceCheck({if case .success(let x)=v{return x.secondary != nil && x.primaryRegion.intersection(x.secondaryRegion!).isEmpty};return false}(),
                   "vertical split produces disjoint distinct layout regions")
    workspaceCheck((try? v.get()).map { $0.primaryRegion.height == floor(0.61 * (g.canvas.height - g.safeInsets.bottom - g.panelBottom - 36)) } ?? false,
                   "vertical ratio is applied to usable height, excluding the gap")
    let h=WorkspacePairGeometry.sideBySide(g,primary:CGSize(width:220,height:390),secondary:CGSize(width:220,height:390),axis:.horizontal,ratio:0.39)
    workspaceCheck({if case .success(let x)=h{return x.secondary != nil && x.primaryRegion.intersection(x.secondaryRegion!).isEmpty};return false}(),
                   "horizontal split produces disjoint regions")
    workspaceCheck((try? h.get()).map { $0.primaryRegion.width == floor(0.39 * (g.canvas.width - 36)) } ?? false,
                   "horizontal ratio is applied to usable width, excluding the gap")
    let unreadable=WorkspacePairGeometry.sideBySide(g,primary:CGSize(width:1000,height:2200),secondary:CGSize(width:1000,height:2200),axis:.horizontal,ratio:0.5)
    workspaceCheck({if case .failure(.insufficientSpace)=unreadable{return true};return false}(),"unreadable split refuses shrink-to-tiny")
    let constrained=WorkspaceGeometry(canvas:g.canvas,safeInsets:g.safeInsets,panelBottom:132,
        keyboardBottomObstruction:390,minimumCardSize:g.minimumCardSize,minimumReadableScale:g.minimumReadableScale)
    let keyboard=WorkspacePairGeometry.sideBySide(constrained,primary:CGSize(width:390,height:520),secondary:CGSize(width:390,height:520),axis:.vertical,ratio:0.5)
    workspaceCheck({if case .failure(.insufficientSpace)=keyboard{return true};return false}(),"keyboard-constrained space returns safe refusal")
    let badRatio=WorkspacePairGeometry.sideBySide(g,primary:CGSize(width:390,height:520),secondary:CGSize(width:390,height:520),axis:.vertical,ratio:.nan)
    workspaceCheck({if case .failure(.invalidRatio)=badRatio{return true};return false}(),"NaN ratio rejected")
    let badG=WorkspaceGeometry(canvas:g.canvas,safeInsets:WorkspaceInsets(top:.infinity,left:0,bottom:0,right:0),
        panelBottom:0,keyboardBottomObstruction:0,minimumCardSize:g.minimumCardSize,minimumReadableScale:0.4)
    let invalid=WorkspacePairGeometry.rotation(badG,source:CGSize(width:390,height:520))
    workspaceCheck({if case .failure(.invalidGeometry)=invalid{return true};return false}(),"non-finite safe geometry rejected")

    s.setCleanupBlocked()
    workspaceCheck(s.mode == .blocked && s.inputOwner==nil, "uncertain cleanup blocks operations and closes focus")
    expectWorkspaceError(.transactionBusy){try s.selectMainTask(a)}
    s.resolveCleanup()
    workspaceCheck(s.mode == .ready && s.primary==d && s.partner==a && s.mainTask==a, "confirmed cleanup preserves A/B descriptor and role")
    workspaceCheck(s.inputOwner==nil, "cleanup never resurrects focus")
    // Failed preparation in side-by-side returns to the old group in rotation.
    var splitFailure=WorkspaceState()
    try! splitFailure.configure(primary:a,partner:b)
    try! splitFailure.setCapability(.dualSceneVerified)
    _ = try! splitFailure.setArrangement(.sideBySide(axis:.vertical,ratio:0.43), in: splitSpace)
    try! splitFailure.requestInput(for:a)
    let splitTx=try! splitFailure.beginPartnerReplacement(c,transactionID:1)
    try! splitFailure.commitPartnerReplacement(splitTx,prepared:false)
    workspaceCheck(splitFailure.primary==a && splitFailure.partner==b && splitFailure.mainTask==a,
                   "failed split partner preparation preserves exact old group")
    workspaceCheck(splitFailure.arrangement == .sideBySide(axis:.vertical,ratio:0.43) && splitFailure.capability == .dualSceneVerified,
                   "failed replacement retains prior compatible split and session pair")
    workspaceCheck(splitFailure.inputOwner==a && splitFailure.lastNotice == .replacementPreparationFailed,
                   "failed split replacement retains old focus without focusing candidate")
    splitFailure.endInput()
    try! splitFailure.requestInput(for:b)
    let editing = splitFailure
    expectWorkspaceError(.focusTransferRequiresRelease){_ = try splitFailure.beginPartnerReplacement(c,transactionID:2)}
    expectWorkspaceError(.focusTransferRequiresRelease){try splitFailure.setCapability(.singleSceneOnly)}
    workspaceCheck(splitFailure == editing, "refused replacement and downgrade preserve the editing group exactly")
    splitFailure.endInput()
    try! splitFailure.setCapability(.singleSceneOnly)
    workspaceCheck(splitFailure.primary==a && splitFailure.partner==b && splitFailure.arrangement == .rotation,
                   "released capability loss falls back without replacing members")
    try! splitFailure.requestInput(for:a)
    let replacement = try! splitFailure.beginPartnerReplacement(d,transactionID:2)
    splitFailure.resolveCleanup()
    workspaceCheck(splitFailure.mode == .pending(replacement), "out-of-phase cleanup cannot reopen a pending transaction")
    try! splitFailure.commitPartnerReplacement(replacement,prepared:true)
    workspaceCheck(splitFailure.primary==a && splitFailure.partner==d && splitFailure.inputOwner==a,
                   "replacing an unfocused participant preserves the active input owner")
    if workspaceChecks != 96 {
        workspaceFailures += 1
        fputs("WORKSPACE FAIL: expected exactly 96 executed checks, got \(workspaceChecks)\n", stderr)
    }
    print("PANDORA_WORKSPACE_TESTS checks=\(workspaceChecks) failures=\(workspaceFailures)")
    if workspaceFailures != 0 {fatalError("workgroup model regression failed")}
}
