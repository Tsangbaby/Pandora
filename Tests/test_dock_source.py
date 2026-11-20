#!/usr/bin/env python3
"""Assert production wiring; not UIKit or handset execution."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
UI = (ROOT / 'Sources/UI/ProbeController.swift').read_text()
MOTION = (ROOT / 'Sources/UI/ProbeCardMotion.swift').read_text()
EDGE = (ROOT / 'Sources/UI/ProbeGestureEdge.swift').read_text()


def body(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class DockMotionWiring(unittest.TestCase):
    def ordered(self, source, *tokens):
        indexes = [source.index(x) for x in tokens]
        self.assertEqual(indexes, sorted(set(indexes)))

    def test_gestures_only_owned_edges(self):
        setup = body(UI, 'private func configureEdges()', '@objc private func start()')
        self.assertIn('panel.addSubview(activeEdge)', setup)
        self.assertIn('view.addSubview(dockEdge)', setup)
        self.assertIn('accessibilityCustomActions', setup)
        self.assertIn('addGestureRecognizer(pan)', EDGE)
        self.assertIn('minimumNumberOfTouches = 1', EDGE)
        self.assertNotIn('addGestureRecognizer', UI)
        self.assertNotIn('rotationButton', UI)

    def test_direction_priority_and_keyboard(self):
        swipe = body(UI, 'private func handleSwipe(', '@objc private func stop()')
        self.ordered(swipe, 'guard canSwipeHeader', 'confirmationIsCurrent', 'switch WorkspaceEdgeMotion.decision',
                     'case .finishEditing:', 'case .confirm:', 'case .apply:',
                     'if direction == .down { return PDProbeRuntime.dock', 'return PDProbeRuntime.rotate')
        self.assertIn('guard direction == .up, rotationOffer != nil', swipe)
        self.assertIn('edgeConfirmation = nil', body(UI, 'private func keyboard(', 'private func layoutControls()'))
        self.assertNotIn('resignFirstResponder', UI + EDGE)
        self.assertNotIn('endEditing(', UI + EDGE)

    def test_native_release_precedes_tab(self):
        dock = body(UI, 'static func dock(from', 'static func hasParkedDock(')
        self.ordered(dock, 'guard root.dockCandidateFrame != nil', 'workspaceDock.beginReturn',
                     'root.end(', 'released && lease.nativeReturnConfirmed',
                     'workspaceDock.phase == .returning(ticket)', 'workspaceDock.completeReturn',
                     'runtime.root === root, runtime.lease === lease', 'root.showDock(ticket)')
        home = body(UI, 'fileprivate func showDock(', 'fileprivate func restoreFromDock()')
        self.assertIn('panel.isHidden = true', home)
        self.assertNotIn('session', home)

    def test_parked_hit_only_visible_own_tab(self):
        root = body(UI, 'override func hitTest(', 'override func didMoveToSuperview()')
        self.assertIn('identityLost ? nil : root.dockedSubview', root)
        hit = body(UI, 'fileprivate func dockedSubview(', 'fileprivate func showDock(')
        self.ordered(hit, 'isReleasedForDock', 'frame == dockCandidateFrame', 'frame.contains(point)',
                     'hasParkedDock', 'return dockEdge.hitTest')
        self.assertNotIn('nativeReturnConfirmed', hit)

    def test_restore_uses_ticket_and_both_admission_gates(self):
        restore = body(UI, 'static func restoreDock(', 'private func retireControls(')
        self.ordered(restore, 'canRestoreDock(root', 'lease.nativeReturnConfirmed',
                     'runtime.root === root, runtime.lease === lease', 'workspaceDock.beginRestore',
                     'root.restoreFromDock()', 'workspaceDock.discardRestore')
        mount = body(UI, 'static func canMount(', 'static func discardMountOffer(')
        self.ordered(mount, 'shared.rotation.permitsMount', 'shared.workspaceDock.permitsMount',
                     'rotation.recordMount', 'dock.completeMount', 'runtime.rotation = rotation')
        self.assertNotIn('requestFocus', restore)

    def test_only_committed_activation_reveals(self):
        start = body(UI, '@objc private func start()', '@objc private func focus()')
        self.ordered(start, 'card.isUserInteractionEnabled = false', 'cardMotion.prepare',
                     'guard cardMotion.blocksContent', 'try candidate.activate()', 'state.attach(token)',
                     'PDProbeRuntime.recordMount', 'cardMotion.reveal', 'self.state.generation == token',
                     'self.card.isUserInteractionEnabled = true')
        self.assertIn('UIAccessibility.isReduceMotionEnabled', start)
        for forbidden in ('PDSceneSession', 'activate()', 'requestFocus', 'snapshotView', 'drawHierarchy'):
            self.assertNotIn(forbidden, MOTION + EDGE)
        self.assertIn('UIViewPropertyAnimator(duration: 0.28', MOTION)
        self.assertIn('currentAnimator === animator', MOTION)

    def test_stop_revokes_before_retirement(self):
        stop = body(UI, '@objc static func stopControls()', 'static func rotate(')
        self.ordered(stop, 'runtime.rotation.cancel()', 'runtime.workspaceDock.cancel()',
                     'runtime.root?.clearDock()', 'runtime.retireControls(')
        end = body(UI, 'func end(_ message:', 'fileprivate var dockCandidateFrame')
        self.ordered(end, 'state.beginCancellation()', 'clearDock()', 'cardMotion?.clear()',
                     'try session?.finish()', 'state.finishCancellation')
        self.assertIn('else { stopControls() }', body(UI, '@objc static func foregroundChanged()', '\n}'))


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DockMotionWiring))
print(json.dumps({'dock_motion_source_contracts': result.testsRun, 'failures': len(result.failures),
                  'errors': len(result.errors), 'handset_executed': False}))
raise SystemExit(not result.wasSuccessful())
