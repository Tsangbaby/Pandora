import Foundation
import CoreGraphics

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    guard value() else { fatalError("FAIL: \(label)") }
}

var state = ProbeState()
check(state.phase == .idle, "starts idle")
check(!state.focusRequested, "starts without focus")
check(!state.attach(0), "cannot attach without begin")
check(!state.markFocus(0), "cannot focus without attachment")
let first = state.begin()!
check(state.phase == .mounting, "begin mounts")
check(state.begin() == nil, "duplicate begin refused")
check(!state.attach(first &+ 1), "wrong token refused")
check(!state.markFocus(first), "mounting cannot focus")
check(state.attach(first), "correct attachment")
check(!state.attach(first), "duplicate attachment refused")
check(state.markFocus(first), "attached may request focus")
check(state.focusRequested, "focus is recorded")
check(!state.markFocus(first), "duplicate focus request refused")
state.stop()
check(state.phase == .idle && !state.focusRequested, "stop resets focus")
check(!state.attach(first) && !state.markFocus(first), "late work cannot revive stopped session")
state.stop()
let second = state.begin()!
check(first != second, "new session has fresh identity")
state.stop()
check(!state.attach(second), "cancelled mounting stays cancelled")
for _ in 0..<1000 {
    let token = state.begin()!
    check(state.attach(token), "repeat attaches")
    check(state.markFocus(token), "repeat focuses")
    state.stop()
    check(!state.markFocus(token), "repeat stale focus rejected")
}

let source = CGSize(width: 390, height: 844)
let area = CGRect(x: 12, y: 160, width: 366, height: 600)
let fitted = ProbeGeometry.fit(source: source, available: area)!
check(area.contains(fitted), "fitted card stays inside safe area")
check(abs(fitted.width / fitted.height - source.width / source.height) < 0.000001,
      "source aspect is preserved")
check(fitted.width <= source.width && fitted.height <= source.height, "never upscales")
check(ProbeGeometry.fit(source: .zero, available: area) == nil, "zero source rejected")
check(ProbeGeometry.fit(source: CGSize(width: CGFloat.nan, height: 844), available: area) == nil,
      "NaN source rejected")
check(ProbeGeometry.fit(source: CGSize(width: 390, height: CGFloat.infinity), available: area) == nil,
      "infinite source rejected")
check(ProbeGeometry.fit(source: source, available: CGRect(x: 0, y: 0, width: 80, height: 500)) == nil,
      "tiny viewport rejected")
check(ProbeGeometry.fit(source: CGSize(width: 9000, height: 9000), available: area) == nil,
      "unreadable scale rejected")
for width in stride(from: 240, through: 1000, by: 20) {
    for height in stride(from: 240, through: 1000, by: 20) {
        let region = CGRect(x: 14, y: 110, width: width, height: height)
        if let frame = ProbeGeometry.fit(source: source, available: region) {
            check(frame.minX >= region.minX - 0.001 && frame.minY >= region.minY - 0.001 &&
                  frame.maxX <= region.maxX + 0.001 && frame.maxY <= region.maxY + 0.001,
                  "geometry remains bounded")
        }
    }
}
// Native cleanup is a barrier, not an immediate return to idle.
var barrier = ProbeState()
let pending = barrier.begin()!
let retiring = barrier.beginCancellation()!
check(barrier.phase == .cancelling, "cancellation closes mount gate")
check(barrier.begin() == nil, "cannot mount during cleanup")
check(!barrier.attach(pending), "late mount rejected during cleanup")
check(barrier.beginCancellation() == nil, "recursive cleanup rejected")
check(!barrier.finishCancellation(pending, succeeded: true), "stale cleanup cannot commit")
check(barrier.finishCancellation(retiring, succeeded: false), "failed cleanup is recorded")
check(barrier.phase == .blocked && barrier.begin() == nil, "failed cleanup blocks remount")
check(!barrier.markFocus(retiring), "failed cleanup cannot request input")
let retry = barrier.beginCancellation()!
check(barrier.finishCancellation(retry, succeeded: true), "successful retry resolves barrier")
check(barrier.phase == .idle, "resolved cleanup returns idle")
let newest = barrier.begin()!
check(!barrier.finishCancellation(retry, succeeded: true), "retired cleanup cannot cancel new session")
check(barrier.attach(newest), "new lease remains eligible")
barrier.stop()
for published in [false, true] {
    for closing in [false, true] {
        for valid in [false, true] {
            check(ProbeAdmission.permits(published: published, closing: closing, overlayValid: valid) ==
                  (published && !closing && valid), "mount admission requires published valid non-retiring overlay")
            check(ProbeAdmission.resumesClose(published: published, closing: closing, cleanupEligible: valid) ==
                  (published && closing && valid), "automatic close only resumes genuine in-flight close")
        }
    }
}
for _ in 0..<100 {
    check(!ProbeAdmission.resumesClose(published: true, closing: true, cleanupEligible: false),
          "persistent overlay failure cannot enqueue another automatic cleanup")
    check(!ProbeAdmission.permits(published: false, closing: false, overlayValid: true),
          "partially attached unpublished root cannot enter presenter factory")
}
print("PANDORA_STATE_TESTS checks=\(checks) failures=0")
