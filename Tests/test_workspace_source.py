#!/usr/bin/env python3
"""Source-contract gate: workgroup state is not evidence of two live Apps."""
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parents[1]
core=(root/'Sources/Core/WorkspaceState.swift').read_text()
readme=(root/'README.md').read_text()
checks={
'core_is_ui_free':not re.search(r'^import UIKit|UIWindow|UIViewController',core,re.M),
'no_native_adapter_claim': 'does NOT host or create an App Scene' in core,
'default_is_single_scene': 'capability = .singleSceneOnly' in core,
'side_by_side_requires_explicit_capability':'capability == .dualSceneVerified' in core,
'main_vs_slot_operations_separate':'func selectMainTask' in core and 'func swapPositions' in core,
'exact_single_input_member':'private(set) var inputOwner:' in core and 'focusTransferRequiresRelease' in core,
'atomic_partner_transaction':'beginPartnerReplacement' in core and 'commitPartnerReplacement' in core,
'nonmain_replacement_identity':'let old = (main == a ? b : a)' in core,
'dock_not_session_teardown':'mutating func dock()' in core and 'Never claims to stop/kill a member App or native session' in core,
'failure_does_not_publish_candidate':bool(re.search(r'guard prepared else \{[^}]*lastNotice = \.replacementPreparationFailed[^}]*return\s*\}', core)),
'minimum_readability_gate':'minimumReadableScale' in core,
'product_boundary_reported':'不是有双 App 实时托管界面的产品版本' in readme and '不创建第二个 Scene' in readme,
}
for k,v in checks.items():
 if not v: print('FAIL',k,file=sys.stderr)
print({'workspace_source_checks':len(checks),'failures':sum(not x for x in checks.values()),'live_dual_scene_execution':False})
sys.exit(any(not x for x in checks.values()))
