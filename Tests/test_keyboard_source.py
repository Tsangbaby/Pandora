#!/usr/bin/env python3
"""Keyboard wiring/source contracts, NOT UIKit or remote-input execution."""
import argparse,json,subprocess,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--baseline',action='store_true');args=p.parse_args()
BASE='d2318f1b830263b8423427c7ae7879692c73bc3b'
def read(name):
    if args.baseline:
        r=subprocess.run(['git','show',BASE+':'+name],cwd=ROOT,capture_output=True,text=True)
        return r.stdout if r.returncode==0 else ''
    return (ROOT/name).read_text()
def segment(text,start,end):
    return text.split(start,1)[1].split(end,1)[0] if start in text and end in text else ''
class KeyboardWiring(unittest.TestCase):
    def test_notification_height_cannot_change_base_fit(self):
        ui=read('Sources/UI/ProbeController.swift')
        layout=segment(ui,'private func layoutSession(', 'override func viewDidLayoutSubviews')
        self.assertIn('ProbeKeyboardLayout.hostedScene(',layout)
        self.assertIn('max(12, view.safeAreaInsets.bottom)\n',layout)
        self.assertNotIn('keyboardHeight',ui)
        self.assertNotIn('keyboardFrameEndUserInfoKey',layout)
    def test_observe_before_attached_and_only_main_queue(self):
        ui=read('Sources/UI/ProbeController.swift')
        callback=segment(ui,'private func keyboard(', 'private func layoutControls')
        self.assertIn('queue: .main',ui)
        self.assertIn('[weak self] note',ui)
        self.assertIn('keyboardDidChangeFrameNotification',ui)
        self.assertIn('keyboardDidHideNotification',ui)
        self.assertNotIn('guard state.phase == .attached',callback)
        self.assertLess(callback.index('keyboardEnvironment.recordFrame'),callback.index('state.phase == .attached'))
        self.assertNotIn('session.update',callback)
        self.assertNotIn('requestFocus',callback)
    def test_end_is_not_keyboard_hide(self):
        ui=read('Sources/UI/ProbeController.swift')
        end=segment(ui,'func end(_ message:', 'func foregroundChanged')
        self.assertIn('ProbeKeyboardEnvironment()',ui)
        self.assertNotIn('keyboardEnvironment =',end)
        self.assertNotIn('recordHidden',end)
        self.assertIn('appliedContentFrame = nil',end)
        self.assertIn('removeObserver(token)',ui)
    def test_positive_external_geometry_not_notification_guess(self):
        monitor=read('Sources/UI/ProbeKeyboardMonitor.swift')
        self.assertIn('NSClassFromString',monitor)
        self.assertIn('item === hostedView',monitor)
        self.assertIn('$0.windowLevel > carrierWindow.windowLevel',monitor)
        self.assertIn('$0 !== carrierWindow',monitor)
        self.assertIn('$0.screen === carrierWindow.screen',monitor)
        self.assertIn('$0.windowScene === carrierWindow.windowScene',monitor)
        self.assertIn('carrierWindow.convert(inSource, from: window)',monitor)
        self.assertIn('insideHost && !isHost && fillAlpha > 0.01',monitor)
        self.assertNotIn('root.convert(item.bounds, from: item)',monitor)
        self.assertNotIn('frames.append(bounds)',monitor)
        self.assertIn('visited < 256',monitor)
        self.assertIn('scanCompleted: false',monitor)
        self.assertNotIn('keyboardFrameEndUserInfoKey',monitor)
        self.assertNotIn('keyboardLayoutGuide',monitor)
    def test_no_stale_native_apply_or_identical_republication(self):
        ui=read('Sources/UI/ProbeController.swift')
        layout=segment(ui,'private func layoutSession(', 'override func viewDidLayoutSubviews')
        self.assertIn('self.session === session',layout)
        self.assertIn('state.phase == .mounting || state.phase == .attached',layout)
        self.assertIn('laidOutSession === session && appliedContentFrame == frame',layout)
        self.assertLess(layout.index('outsideKeyboard(in:'),layout.index('appliedContentFrame == frame'))
        self.assertIn('case .returnToNative:',layout)
    def test_never_force_text_or_steal_keyboard(self):
        ui=read('Sources/UI/ProbeController.swift');core=read('Sources/Core/ProbeKeyboard.swift')
        self.assertIn('keyboardEnvironment.accessibilitySummary',ui)
        self.assertIn('case unknown',core)
        self.assertIn('recordHidden()',core)
        for text in (ui,core,read('Sources/UI/ProbeKeyboardMonitor.swift')):
            for forbidden in ('resignFirstResponder(', 'becomeFirstResponder(', 'endEditing(', 'unmarkText(', 'makeKeyWindow('):
                self.assertNotIn(forbidden,text)
result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(KeyboardWiring))
print(json.dumps({'keyboard_source_contracts':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'baseline':args.baseline,'UIKit_remote_input_executed':False}))
if args.baseline:
    raise SystemExit(0 if result.testsRun==6 and len(result.failures)==6 and not result.errors else 1)
raise SystemExit(not result.wasSuccessful())
