#!/usr/bin/env python3
"""Check handoff effects and cleanup ordering, not device UI behavior."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
UI = (ROOT / 'Sources/UI/ProbeController.swift').read_text()
BRIDGE = (ROOT / 'Sources/Native/PDNative.m').read_text()


def between(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class HandoffWiring(unittest.TestCase):
    def ordered(self, source, *parts):
        offsets = [source.index(part) for part in parts]
        self.assertEqual(offsets, sorted(set(offsets)))

    def test_choose_only_from_live_panel(self):
        click = between(UI, '@objc private func rotate()', 'fileprivate var canRotate:')
        self.ordered(click, 'guard canRotate', 'if !confirmingRotation', 'status.text', 'PDProbeRuntime.rotate(from: self)')
        self.assertIn('state.phase == .attached && !updatingSessionLayout', UI)
        self.assertIn('session?.remainsForeground == true', UI)

    def test_all_cleanup_precedes_handoff(self):
        rotate = between(UI, 'static func rotate(from', 'private func retireControls(')
        self.ordered(rotate, 'permitsInteraction(root)', 'beginReturn(from:', 'verifyNativeReturn: true',
                     'retired && PDProbeCanPresent(root.target)', 'rotation.finishReturn(')
        retire = between(UI, 'private func retireControls(', 'static func permitsInteraction(')
        self.ordered(retire, 'guard !retiringControls, preparingRoot == nil', 'root?.end(message)',
                     'lease?.nativeReturnConfirmed != true', 'root?.blockOverlayCleanup("未能确认原生归还',
                     'try lease?.finish()',
                     'try PDOverlayLease.finishPending()', 'self.root = nil', 'self.lease = nil', 'return true')

    def test_native_return_uses_exact_old_binding(self):
        verify = between(BRIDGE, '- (BOOL)nativeReturnConfirmed', '- (BOOL)finishWithError:')
        self.ordered(verify, 'guard' if 'guard' in verify else 'if (!self.valid)',
                     'PDNativeSnapshot(self.target, NULL)', '[self matchesSnapshot:snapshot]')
        self.assertNotIn('cancelOutstandingWithError', verify)
        binding = between(BRIDGE, '- (BOOL)matchesSnapshot:(NSDictionary *)snapshot {', '- (BOOL)nativeReturnConfirmed')
        for name in ('boundScene', 'boundIdentifier', 'nativeWindow', 'nativeRoot', 'boundManager',
                     'boundOwner', 'boundNativePresenter', 'boundContainer'):
            self.assertIn(name, binding)

    def test_foreground_only_offers_controls(self):
        arrive = between(UI, 'else if let destination = runtime.rotation.waitingFor', 'else if let armed = runtime.armed')
        self.ordered(arrive, 'PDProbeCanPresent(destination.probeTarget)', 'rotation.offer(', 'runtime.presentControls(')
        prepare = between(UI, 'private func presentControls(', '@objc static func stopControls()')
        self.ordered(prepare, 'try PDOverlayLease.finishPending()', 'PDOverlayLease.attach(', 'self.root = candidate')
        for action in ('capture(in:', 'candidate.activate(', 'requestFocus(', 'openURL(', 'UIApplication.shared.open('):
            self.assertNotIn(action, arrive + prepare)

    def test_manual_mount_commits_after_native_readback(self):
        start = between(UI, '@objc private func start()', '@objc private func focus()')
        self.ordered(start, 'interactiveOverlay(for: self)', 'PDSceneSession.capture(', 'state.generation == token',
                     'try candidate.activate()', 'guard state.attach(token)', 'recordMount(for: self, generation: token)',
                     'rotationOffer = nil')
        self.assertIn('try layoutSession(candidate)', start.split('guard state.attach(token)', 1)[1])
        self.assertIn('permitsInteraction(root) && canMount(root)', UI)
        self.assertNotIn('requestFocus()', start)

    def test_stop_and_mount_failures_discard_only_live_intents(self):
        stop = between(UI, '@objc static func stopControls()', 'static func rotate(from')
        self.ordered(stop, 'runtime.armed = nil', 'runtime.rotation.cancel()', 'runtime.retireControls(')
        end = between(UI, 'func end(_ message:', 'func foregroundChanged()')
        self.assertIn('PDProbeRuntime.discardMountOffer(for: self)', end)
        self.assertIn('shared.root === root, let offer = root.rotationOffer', UI)
        detach = between(UI, 'static func rootDetached(', '@objc static func foregroundChanged()')
        self.assertIn('shared.root === root, !shared.retiringControls', detach)
        self.assertIn('com.apple.springboard.lockstate', (ROOT / 'Sources/Native/PDEntry.m').read_text())


result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(HandoffWiring))
print(json.dumps({'rotation_source_contracts': result.testsRun, 'failures': len(result.failures),
                  'errors': len(result.errors), 'handset_rotation_executed': False}))
raise SystemExit(not result.wasSuccessful())
