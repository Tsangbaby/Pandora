#!/usr/bin/env python3
"""Require exact summaries from the separately compiled Swift debug/release tests."""
import pathlib, sys
patterns={
 'PANDORA_ROTATION_TESTS':(34,0),
 'PANDORA_WORKSPACE_TESTS':(96,0),
 'PANDORA_KEYBOARD_TESTS':(96,0),
 'PANDORA_STATE_TESTS':(4774,0),
}
if len(sys.argv)!=3:
    raise SystemExit('expected Debug and Release log paths')
for raw in sys.argv[1:]:
    path=pathlib.Path(raw); lines=path.read_text().splitlines()
    for name,(expected,failures) in patterns.items():
        matches=[line for line in lines if line.startswith(name+' ')]
        wanted=f'{name} checks={expected} failures={failures}'
        if matches != [wanted]:
            print(f'{path}: expected exactly {wanted!r}; found {matches!r}',file=sys.stderr)
            raise SystemExit(1)
print('WORKSPACE_KEYBOARD_STATE_DEBUG_RELEASE_SUMMARIES_OK')
