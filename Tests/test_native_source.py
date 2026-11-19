#!/usr/bin/env python3
"""Narrow source contracts, not UIKit/remote interaction evidence."""
import argparse,json,subprocess,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--baseline',action='store_true');args=parser.parse_args()
def read(name):
    if args.baseline:
        p=subprocess.run(['git','show','a2056e719ad2fbb89163dfca68f4bcfb8172c915:'+name],cwd=ROOT,capture_output=True,text=True)
        return p.stdout if p.returncode==0 else ''
    return (ROOT/name).read_text()
class Contracts(unittest.TestCase):
    def test_no_raw_host_or_new_native_window(self):
        n=read('Sources/Native/PDNative.m');s=read('Sources/UI/ProbeController.swift')
        self.assertIn('attachController:',n)
        for token in ('initWithSceneLayer:','[contextClass new]','registerWindowWithContextID:','PDSystemWindow'):
            self.assertNotIn(token,n)
        self.assertNotIn('ProbeWindow(',s)
    def test_same_owner_factory_and_only_own_cleanup(self):
        n=read('Sources/Native/PDPresenterLease.m')
        self.assertIn('Durable cleanup ticket exists before the factory.',n)
        self.assertIn('PDLeaseCall(p,@"deactivate")',n)
        self.assertIn('PDLeaseCall(p,@"invalidate")',n)
        for target in ('self.owner','self.manager','self.nativePresenter'):
            self.assertNotIn('PDLeaseCall('+target+',@"invalidate")',n)
    def test_no_lazy_cache_getter(self):
        n=read('Sources/Native/PDNativeProfile.h')
        self.assertIn('PDDecodeAssociationKey(address,words,&decodedKey)',n)
        self.assertIn('objc_getAssociatedObject(scene',n)
        self.assertNotIn('objc_msgSend',n)
    def test_no_borrowed_window_mutation(self):
        n=read('Sources/Native/PDNative.m')
        self.assertIn('[lease.parent addChildViewController:controller]',n)
        for token in ('window.hidden =','window.windowLevel =','window.rootViewController =','makeKeyWindow','setHostContainerView:'):
            self.assertNotIn(token,n)
    def test_ui_cleanup_barrier_and_native_transform(self):
        s=read('Sources/UI/ProbeController.swift');n=read('Sources/Native/PDNative.m')
        self.assertIn('state.beginCancellation()',s);self.assertIn('finishCancellation(token, succeeded:',s)
        self.assertNotIn('state.stop()',s);self.assertNotIn('host.transform',s)
        self.assertIn('setHostTransformer:',n);self.assertIn('PDMakeHostMapping(',n)
        self.assertIn('NSClassFromString(@"UITransformer")',n)
        self.assertIn('[value isKindOfClass:transformClass]',n)
        self.assertIn('Class baseTransformClass = NSClassFromString(@"UITransform")',n)
        self.assertIn('isSubclassOfClass:baseTransformClass',n)
        self.assertIn('[value isKindOfClass:transformClass]',n)
        self.assertIn('PDProbeRuntime.permitsInteraction(self)',s)
        self.assertIn('ProbeAdmission.resumesClose(',s)
        self.assertIn('root?.blockOverlayCleanup(',s)
        self.assertNotIn('cleanupResolved',s)
    def test_narrow_hook_originals_once(self):
        n=read('Sources/Native/PDPresenterLease.m')
        for suffix in ('Activate','Deactivate','Invalidate'):
            self.assertEqual(n.count('PDOriginal'+suffix+'(self, command, presenter);'),1)
        self.assertIn('lease.owner == owner && lease.presenter != presenter',n)
        self.assertIn('dispatch_async(dispatch_get_main_queue()',n)
result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Contracts))
print(json.dumps({'source_contracts':result.testsRun,'failures':len(result.failures),'errors':len(result.errors),'baseline':args.baseline,'runtime_private_host_executed':False}))
if args.baseline:
    raise SystemExit(0 if result.testsRun==6 and len(result.failures)==6 and not result.errors else 1)
raise SystemExit(not result.wasSuccessful())
