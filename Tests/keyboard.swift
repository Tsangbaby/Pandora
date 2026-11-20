import Foundation
import CoreGraphics

// Production-core regressions only: no UIKit monitor, keyboard window discovery,
// responder/input injection, device session, or copied replacement layout policy.
// Called once by Tests/main.swift when compiling both production core files.
func runKeyboardTests() {
    var keyboardChecks = 0
    func CHECK(_ value: @autoclosure () -> Bool, _ label: String) {
        keyboardChecks += 1
        guard value() else { fatalError("PANDORA_KEYBOARD_TESTS FAIL: \(label)") }
    }
    func near(_ a: CGFloat, _ b: CGFloat) -> Bool {
        return a.isFinite && b.isFinite && abs(a - b) < 0.000001
    }
    func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        return near(a.origin.x, b.origin.x) && near(a.origin.y, b.origin.y) &&
            near(a.size.width, b.size.width) && near(a.size.height, b.size.height)
    }

    // An environmental observation is not inferred from session lifetime or
    // from a frame's apparent visibility. Only a didHide adapter calls this API.
    var environment = ProbeKeyboardEnvironment()
    CHECK(environment.observation == .unknown, "new environment is unknown, not hidden")
    let unknownSummary = environment.accessibilitySummary
    environment.recordHidden()
    CHECK(environment.observation == .hidden, "explicit didHide records hidden")
    let hiddenSummary = environment.accessibilitySummary
    CHECK(hiddenSummary != unknownSummary, "accessibility distinguishes unknown from didHide")

    let docked = CGRect(x: 0, y: 474, width: 390, height: 370)
    environment.recordFrame(docked)
    CHECK(environment.observation == .frame(docked), "finite frame replaces hidden")
    CHECK(environment.accessibilitySummary != hiddenSummary,
          "frame observation is not announced as an explicit hide")
    let negativeOrigin = CGRect(x: -100, y: -200, width: 80, height: 40)
    environment.recordFrame(negativeOrigin)
    CHECK(environment.observation == .frame(negativeOrigin), "negative origins are valid coordinates")
    let offscreen = CGRect(x: 10000, y: 10000, width: 390, height: 370)
    environment.recordFrame(offscreen)
    CHECK(environment.observation == .frame(offscreen), "offscreen frame is not fabricated hidden")
    environment.recordFrame(.zero)
    CHECK(environment.observation == .frame(.zero), "zero rectangle remains an observed frame")
    let zeroWidth = CGRect(x: 0, y: 844, width: 0, height: 370)
    environment.recordFrame(zeroWidth)
    CHECK(environment.observation == .frame(zeroWidth), "zero width is not fabricated hidden")
    let zeroHeight = CGRect(x: 0, y: 844, width: 390, height: 0)
    environment.recordFrame(zeroHeight)
    CHECK(environment.observation == .frame(zeroHeight), "zero height is not fabricated hidden")

    // Seed a known frame for EVERY invalid case: ignoring invalid input and
    // retaining a stale frame must not pass merely because we were unknown.
    func invalidFrameClearsObservation(_ frame: CGRect?) -> Bool {
        environment.recordFrame(docked)
        environment.recordFrame(frame)
        return environment.observation == .unknown
    }
    CHECK(invalidFrameClearsObservation(nil), "nil observation becomes unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: CGFloat.nan, y: 0, width: 390, height: 370)),
          "NaN x is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: CGFloat.nan, width: 390, height: 370)),
          "NaN y is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: 0, width: CGFloat.nan, height: 370)),
          "NaN width is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: 0, width: 390, height: CGFloat.nan)),
          "NaN height is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: CGFloat.infinity, y: 0, width: 390, height: 370)),
          "infinite x is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: -CGFloat.infinity, width: 390, height: 370)),
          "negative infinite y is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 370)),
          "infinite width is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: 0, width: 390, height: CGFloat.infinity)),
          "infinite height is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: 0, width: -390, height: 370)),
          "negative raw width is unknown")
    CHECK(invalidFrameClearsObservation(CGRect(x: 0, y: 0, width: 390, height: -370)),
          "negative raw height is unknown")
    CHECK(invalidFrameClearsObservation(.null), "null rectangle is unknown")
    CHECK(invalidFrameClearsObservation(.infinite), "infinite rectangle is unknown")
    environment.recordFrame(docked)
    CHECK(environment.observation == .frame(docked), "valid frame recovers from unknown")
    environment.recordHidden()
    CHECK(environment.observation == .hidden, "explicit didHide replaces frame")
    environment.recordFrame(nil)
    CHECK(environment.observation == .unknown, "invalid observation does not latch hidden")

    // Concrete original-coordinate-space regression. The old subtraction is
    // just a numeric counterexample, NOT an implementation of the new policy.
    let source = CGSize(width: 390, height: 844)
    let available = CGRect(x: 12, y: 202, width: 366, height: 608)
    func layout(_ outside: [CGRect] = []) -> ProbeKeyboardDecision {
        return ProbeKeyboardLayout.hostedScene(source: source, available: available,
                                               outsideKeyboardFrames: outside)
    }
    let noKeyboardFit = ProbeGeometry.fit(source: source, available: available)
    CHECK(noKeyboardFit != nil, "no-keyboard geometry fixture is admissible")
    let base = noKeyboardFit!
    let originalBase = CGRect(x: 54.5260663507109, y: 202,
                              width: 280.9478672985782, height: 608)
    CHECK(sameFrame(base, originalBase), "base has independent numeric expected position and dimensions")
    let current = layout()
    CHECK(current == .present(base), "production hostedScene returns the no-keyboard base")
    if case .present(let frame) = current {
        CHECK(near(frame.width, base.width) && near(frame.height, base.height),
              "current dimensions match old NO-keyboard fit, not keyboard subtraction")
        CHECK(near(frame.width / frame.height, source.width / source.height),
              "whole Scene retains its original aspect ratio")
        CHECK(available.contains(frame) && frame.width <= source.width && frame.height <= source.height,
              "base stays bounded without upscaling")
    } else {
        fatalError("PANDORA_KEYBOARD_TESTS FAIL: expected present fixture")
    }
    let subtractionK: CGFloat = 370
    let oldAvailable = CGRect(x: available.origin.x, y: available.origin.y,
                              width: available.width, height: available.height - subtractionK)
    let oldSubtractedFit = ProbeGeometry.fit(source: source, available: oldAvailable)
    CHECK(oldSubtractedFit != nil, "old subtraction counterexample is still admissible")
    let oldMinified = oldSubtractedFit!
    CHECK(oldMinified.width < base.width && oldMinified.height < base.height,
          "old 370-point subtraction demonstrably minifies both dimensions")
    CHECK(near(oldMinified.width, 109.9763033175355) && near(oldMinified.height, 238),
          "old subtraction counterexample has concrete dimensions")
    CHECK(current != .present(oldMinified) && near(base.height, 608),
          "production rejects the old minified result")

    // BEFORE and AFTER are real ProbeState transitions with the same cached
    // notification payload delivered on opposite sides of begin/attach. The
    // production policy deliberately takes outside evidence, not these hints.
    var beforeEnvironment = ProbeKeyboardEnvironment()
    beforeEnvironment.recordFrame(docked)
    var beforeState = ProbeState()
    let beforeToken = beforeState.begin()
    CHECK(beforeToken != nil && beforeState.phase == .mounting &&
          beforeEnvironment.observation == .frame(docked), "BEFORE: begin preserves cached keyboard frame")
    CHECK(beforeState.attach(beforeToken!), "BEFORE: real state attaches")
    let beforeDecision = layout()
    CHECK(beforeDecision == .present(base) && beforeEnvironment.observation == .frame(docked),
          "BEFORE: attach keeps cache and presents original base")

    var afterEnvironment = ProbeKeyboardEnvironment()
    var afterState = ProbeState()
    let afterToken = afterState.begin()
    CHECK(afterToken != nil && afterState.phase == .mounting && afterEnvironment.observation == .unknown,
          "AFTER: mounting without a notification stays unknown, not hidden")
    CHECK(afterState.attach(afterToken!), "AFTER: real state attaches before notification")
    CHECK(layout() == .present(base), "AFTER: unknown hint already presents original base")
    afterEnvironment.recordFrame(docked)
    CHECK(afterEnvironment.observation == .frame(docked), "AFTER: mounted notification is recorded")
    CHECK(layout() == beforeDecision && layout() == .present(base),
          "BEFORE/AFTER histories converge to the identical production present frame")

    CHECK(beforeState.markFocus(beforeToken!), "live generation may request focus once")
    let retiring = beforeState.beginCancellation()
    CHECK(retiring != nil && beforeState.phase == .cancelling && !beforeState.focusRequested &&
          beforeEnvironment.observation == .frame(docked), "cancellation preserves environment and closes focus gate")
    CHECK(!beforeState.attach(beforeToken!), "old mount callback rejected during cancellation")
    CHECK(!beforeState.markFocus(beforeToken!), "old focus callback rejected during cancellation")
    CHECK(!beforeState.finishCancellation(beforeToken!, succeeded: true),
          "old generation cannot complete native-restore barrier")
    CHECK(beforeState.phase == .cancelling && beforeState.generation == retiring! && beforeState.begin() == nil,
          "stale callbacks cannot open the remount gate during cleanup")
    CHECK(beforeState.finishCancellation(retiring!, succeeded: true), "current cleanup token completes end")
    CHECK(beforeState.phase == .idle && beforeEnvironment.observation == .frame(docked),
          "end returns idle without pretending keyboard hidden")
    CHECK(!beforeState.attach(beforeToken!), "no old mount callback after end")
    CHECK(!beforeState.markFocus(beforeToken!), "no old focus callback after end")
    CHECK(!beforeState.finishCancellation(retiring!, succeeded: false) && beforeState.phase == .idle,
          "no old restore callback after end can re-block the session")

    let remount = beforeState.begin()
    CHECK(remount != nil && remount != beforeToken && beforeEnvironment.observation == .frame(docked),
          "remount has a fresh generation without clearing environment")
    CHECK(!beforeState.attach(beforeToken!), "old mount callback cannot attach remount")
    CHECK(!beforeState.markFocus(beforeToken!), "old focus callback cannot focus remount")
    CHECK(!beforeState.finishCancellation(retiring!, succeeded: true),
          "old restore completion cannot finish or cancel remount")
    CHECK(beforeState.phase == .mounting && beforeState.generation == remount! && !beforeState.focusRequested,
          "remount generation and phase survive all retired callbacks")
    CHECK(beforeState.attach(remount!), "fresh remount token still attaches")
    CHECK(beforeState.markFocus(remount!), "fresh remount token still requests focus")
    beforeState.stop()
    afterState.stop()
    CHECK(beforeState.phase == .idle && afterState.phase == .idle &&
          beforeEnvironment.observation == .frame(docked) && afterEnvironment.observation == .frame(docked),
          "resolved stop convenience also preserves both notification caches")
    let genuinelyNewEnvironment = ProbeKeyboardEnvironment()
    CHECK(genuinelyNewEnvironment.observation == .unknown && beforeEnvironment.observation == .frame(docked),
          "only a genuinely new environment starts unknown; existing cache is not reset")

    // Hide/reopen/candidate-bar histories alter observations, never base fit.
    beforeEnvironment.recordHidden()
    CHECK(beforeEnvironment.observation == .hidden && layout() == .present(base),
          "BEFORE history: didHide does not change base dimensions")
    afterEnvironment.recordHidden()
    CHECK(afterEnvironment.observation == .hidden && layout() == .present(base),
          "AFTER history: didHide yields the same base dimensions")
    beforeEnvironment.recordFrame(docked)
    CHECK(beforeEnvironment.observation == .frame(docked) && layout() == .present(base),
          "BEFORE history: reopening keyboard does not shrink Scene")
    afterEnvironment.recordFrame(docked)
    CHECK(afterEnvironment.observation == beforeEnvironment.observation && layout() == beforeDecision,
          "AFTER history: reopening converges with BEFORE history")
    let candidateBar = CGRect(x: 0, y: 430, width: 390, height: 414)
    beforeEnvironment.recordFrame(candidateBar)
    afterEnvironment.recordFrame(candidateBar)
    CHECK(beforeEnvironment.observation == .frame(candidateBar) &&
          afterEnvironment.observation == .frame(candidateBar) && layout() == .present(base),
          "candidate bar height does not trigger a second full-Scene shrink")
    let expandedCandidates = CGRect(x: 0, y: 394, width: 390, height: 450)
    beforeEnvironment.recordFrame(expandedCandidates)
    afterEnvironment.recordFrame(expandedCandidates)
    CHECK(beforeEnvironment.observation == .frame(expandedCandidates) &&
          afterEnvironment.observation == .frame(expandedCandidates) && layout() == .present(base),
          "expanded candidate panel still retains original base, in either history")

    // Independent, actually visible outside-keyboard geometry is different
    // from notification hints. A narrow floating keyboard is sufficient;
    // neither a guessed full-width threshold nor a new minified fit is valid.
    let floating = CGRect(x: base.minX + 20, y: base.minY + 100, width: 60, height: 100)
    CHECK(layout([floating]) == .returnToNative, "narrow floating keyboard with real overlap returns native")
    let letterbox = CGRect(x: available.minX, y: base.minY + 60, width: 20, height: 100)
    CHECK(available.intersects(letterbox) && !base.intersects(letterbox) && layout([letterbox]) == .present(base),
          "external rectangle in available region but outside base does not alter base")
    CHECK(layout([offscreen]) == .present(base), "offscreen external rectangle provides no overlap evidence")
    CHECK(layout([base]) == .returnToNative, "full actual overlap returns native, never a minified present")
    environment.recordHidden()
    CHECK(environment.observation == .hidden && layout([base]) == .returnToNative,
          "stale notification hidden cannot override full visible external overlap")
    CHECK(layout([CGRect(x: base.midX, y: base.midY, width: 1, height: 100)]) == .present(base),
          "external width exactly one is not positive evidence per implementation")
    CHECK(layout([CGRect(x: base.midX, y: base.midY, width: 100, height: 1)]) == .present(base),
          "external height exactly one is not positive evidence per implementation")
    // Use the exact fitted minX (not its rounded display value) and integer
    // y coordinates to exercise the implementation's strict >1 thresholds.
    let leftEdge = CGRect(x: 0, y: 300, width: base.minX + 1, height: 80)
    CHECK(layout([leftEdge]) == .present(base), "wide external rect overlapping base by one point does not fallback")
    let topEdge = CGRect(x: 100, y: 162, width: 80, height: 41)
    CHECK(layout([topEdge]) == .present(base), "tall external rect overlapping base by one point does not fallback")
    let widerEdge = CGRect(x: 0, y: 300, width: base.minX + 1.01, height: 80)
    CHECK(layout([widerEdge]) == .returnToNative, "horizontal overlap just above one point is positive evidence")
    let tallerEdge = CGRect(x: 100, y: 162, width: 80, height: 41.01)
    CHECK(layout([tallerEdge]) == .returnToNative, "vertical overlap just above one point is positive evidence")
    let touchingEdge = CGRect(x: 0, y: 300, width: base.minX, height: 80)
    CHECK(layout([touchingEdge]) == .present(base), "edge contact without positive area does not fallback")
    CHECK(layout([.null]) == .present(base), "null external rectangle is ignored, not treated as globally hidden")
    CHECK(layout([.infinite]) == .present(base), "infinite external rectangle is ignored")
    let nanOutside = CGRect(x: CGFloat.nan, y: base.minY, width: 100, height: 100)
    CHECK(layout([nanOutside]) == .present(base), "NaN external origin is ignored")
    let nanOutsideWidth = CGRect(x: base.midX, y: base.midY, width: CGFloat.nan, height: 100)
    CHECK(layout([nanOutsideWidth]) == .present(base), "NaN external size is ignored")
    let negativeOutsideWidth = CGRect(x: base.midX, y: base.midY, width: -30, height: 60)
    CHECK(layout([negativeOutsideWidth]) == .present(base), "negative raw external width is invalid evidence")
    let negativeOutsideHeight = CGRect(x: base.midX, y: base.midY, width: 60, height: -30)
    CHECK(layout([negativeOutsideHeight]) == .present(base), "negative raw external height is invalid evidence")
    environment.recordFrame(docked)
    let invalidOutside = [CGRect.null, CGRect.infinite, nanOutside, nanOutsideWidth, CGRect.zero,
                          CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100)]
    CHECK(layout(invalidOutside) == .present(base) && environment.observation == .frame(docked),
          "absence of valid external evidence preserves base and does not fabricate global hidden")
    CHECK(layout(invalidOutside + [floating]) == .returnToNative &&
          layout([floating] + invalidOutside) == .returnToNative,
          "invalid external rectangles cannot mask real overlap in either array order")

    // Failure to obtain a usable base takes precedence over external overlap.
    CHECK(ProbeKeyboardLayout.hostedScene(source: source,
          available: CGRect(x: 12, y: 202, width: 119, height: 608), outsideKeyboardFrames: []) == .insufficientSpace,
          "insufficient available width rejects hosting")
    CHECK(ProbeKeyboardLayout.hostedScene(source: source,
          available: CGRect(x: 12, y: 202, width: 366, height: 119), outsideKeyboardFrames: []) == .insufficientSpace,
          "insufficient available height rejects hosting")
    CHECK(ProbeKeyboardLayout.hostedScene(source: CGSize(width: 9000, height: 9000),
          available: available, outsideKeyboardFrames: []) == .insufficientSpace,
          "unreadable scale rejects hosting")
    CHECK(ProbeKeyboardLayout.hostedScene(source: .zero, available: available,
          outsideKeyboardFrames: []) == .insufficientSpace, "invalid zero source rejects hosting")
    CHECK(ProbeKeyboardLayout.hostedScene(source: CGSize(width: CGFloat.nan, height: 844),
          available: available, outsideKeyboardFrames: []) == .insufficientSpace &&
          ProbeKeyboardLayout.hostedScene(source: source,
          available: CGRect(x: CGFloat.nan, y: 202, width: 366, height: 608),
          outsideKeyboardFrames: []) == .insufficientSpace, "nonfinite source or available rejects hosting")
    CHECK(ProbeKeyboardLayout.hostedScene(source: source,
          available: CGRect(x: 12, y: 202, width: 366, height: 119),
          outsideKeyboardFrames: [base]) == .insufficientSpace,
          "insufficientSpace wins even when external keyboard would otherwise overlap")

    print("PANDORA_KEYBOARD_TESTS checks=\(keyboardChecks) failures=0")
}
