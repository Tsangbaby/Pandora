#!/usr/bin/env python3
"""Compile the exact production lookup with Foundation-only environment doubles."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = '0eaa2e2cd998fa97253dcb169645d4af49bff048'
NOTES_CHECKS = 33
FILES_CHECKS = 6
BASELINE_DEFINE = 'PD_SCENE_BASELINE'


def fixture_counts(fixture):
    files = re.findall(r'^#ifndef ' + BASELINE_DEFINE + r'\n(.*?)^#endif\b', fixture, re.M | re.S)
    if len(files) != 1:
        raise ValueError('Expected one candidate-only Files block')
    count = lambda text: len(re.findall(r'^\s*expect\(', text, re.M))
    files_count = count(files[0])
    notes_count = count(fixture) - files_count
    if (notes_count, files_count) != (NOTES_CHECKS, FILES_CHECKS):
        raise ValueError(f'Expected {NOTES_CHECKS} Notes and {FILES_CHECKS} Files assertion sites; '
                         f'found {notes_count} Notes and {files_count} Files')
    return notes_count, files_count


def functions(source):
    names = ['PDObject', 'PDObjectArgument', 'PDTrue', 'PDSceneIdentifier', 'PDScene']
    bodies = []
    for name in names:
        matches = re.findall(r'^static [^\n]*\b' + re.escape(name) +
                             r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
        if len(matches) != 1:
            raise ValueError(f'Expected one production function {name}')
        bodies.append(matches[0])
    return '\n\n'.join(bodies) + '\n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check-source', action='store_true')
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    relative = 'Sources/Native/PDNative.m'
    source = (subprocess.check_output(['git', 'show', BASELINE + ':' + relative], cwd=ROOT).decode()
              if args.baseline else (ROOT / relative).read_text())
    extracted = functions(source)
    fixture = (ROOT / 'Tests/scene_lookup.m').read_bytes()
    notes_count, files_count = fixture_counts(fixture.decode())
    expected = notes_count if args.baseline else notes_count + files_count
    tag = 'baseline' if args.baseline else 'candidate'
    record = {'production_sha256': hashlib.sha256(source.encode()).hexdigest(),
              'extracted_sha256': hashlib.sha256(extracted.encode()).hexdigest(),
              'fixture_sha256': hashlib.sha256(fixture).hexdigest(),
              'expected_checks': expected, 'baseline': args.baseline, 'runtime_executed': False}
    if args.check_source:
        print(json.dumps({'source_extraction': 'ok', **record}))
        return
    if sys.platform != 'darwin':
        raise SystemExit('Native Foundation runtime tests require macOS; no execution claimed')
    evidence = ROOT / 'ci-artifacts'
    evidence.mkdir(exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='pandora-scene-') as temp:
        folder = Path(temp)
        (folder / 'scene-under-test.inc').write_text(extracted)
        binary = folder / 'scene-lookup-tests'
        command = ['xcrun', '--sdk', 'macosx', 'clang', '-isysroot', sdk, '-fobjc-arc', '-fblocks',
                   '-Wall', '-Wextra', '-framework', 'Foundation', '-I' + str(ROOT/'Sources/Native'),
                   '-I' + str(folder), str(ROOT/'Tests/scene_lookup.m'), '-o', str(binary)]
        if args.baseline:
            command.insert(4, '-D' + BASELINE_DEFINE)
        compiled = subprocess.run(command, capture_output=True, text=True)
        (evidence / f'scene-{tag}-build.log').write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr, end='')
            raise SystemExit('Native scene fixture did not compile; not baseline-red evidence')
        run = subprocess.run([str(binary)], capture_output=True, text=True)
        output = run.stdout + run.stderr
        (evidence / f'scene-{tag}-test.log').write_text(output)
        print(output, end='')
        summary = re.findall(r'^PANDORA_SCENE_TESTS checks=(\d+) failures=(\d+)$', output, re.M)
        if len(summary) != 1:
            raise SystemExit('Missing or ambiguous native test summary')
        checks, failures = map(int, summary[0])
        record.update(runtime_executed=True, checks=checks, failures=failures,
                      exit_code=run.returncode, baseline_ref=BASELINE if args.baseline else None)
        (evidence / f'scene-{tag}-report.json').write_text(json.dumps(record, indent=2)+'\n')
        if checks != expected:
            raise SystemExit(f'Incomplete {tag} scene lookup fixture: expected {expected}, got {checks}')
        if args.baseline:
            if run.returncode == 0 or failures == 0:
                raise SystemExit('Old lookup did not independently fail runtime assertions')
            print('PANDORA_SCENE_BASELINE_RED_VERIFIED')
        elif run.returncode != 0 or failures != 0:
            raise SystemExit('Candidate lookup failed native tests')


if __name__ == '__main__':
    main()
