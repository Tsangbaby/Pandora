#!/usr/bin/env python3
"""Compile the FULL production lease + Foundation doubles, only on macOS.

Linux: --check-source checks Python AST, source/fixture shape and delimiters,
NOT Objective-C compilation or native execution. It writes no files by default.
Native mode writes ci-artifacts/presenter-lease-{build,test}.log and -report.json.
--artifacts-dir (or CI_ARTIFACTS_DIR) overrides that directory and also enables
report output in --check-source mode. No extracted/copied substitute is compiled.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    'production': ROOT / 'Sources/Native/PDPresenterLease.m',
    'header': ROOT / 'Sources/Native/PDPresenterLease.h',
    'abi': ROOT / 'Sources/Native/PDABI.h',
    'fixture': ROOT / 'Tests/presenter_lease.m',
}
EXPECTED_CHECKS = 219
SUMMARY = r'^PANDORA_PRESENTER_LEASE_TESTS checks=(\d+) failures=(\d+)$'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def code_only(text):
    # Lexical sanity check, intentionally NOT a replacement for clang.
    return re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                  ' ', text, flags=re.S)


def balanced(text):
    stack = []
    pairs = {')': '(', ']': '[', '}': '{'}
    for char in code_only(text):
        if char in '([{':
            stack.append(char)
        elif char in pairs:
            if not stack or stack.pop() != pairs[char]:
                return False
    return not stack


def validate(text):
    results = {}
    source, header, abi, fixture = (text[key] for key in FILES)
    ast.parse(Path(__file__).read_text(), filename=__file__)
    results['driver_python_ast'] = True
    for key, value in text.items():
        results[key + '_balanced_delimiters'] = balanced(value)
    results['full_production_implementation_present'] = (
        source.count('@implementation PDPresenterLease') == 1)
    results['production_imports_real_headers'] = all(
        line in source for line in ('#import "PDPresenterLease.h"', '#import "PDABI.h"'))
    results['stage_selector_no_external_priority'] = bool(re.search(
        r'stageWithManager:\s*\(id\)manager\s+owner:\s*\(id\)owner\s+'
        r'nativePresenter:\s*\(id\)nativePresenter\s+onChange:', header))
    results['durable_cleanup_public_api'] = '+ (BOOL)cancelOutstandingWithError:' in header
    results['production_abi_guards_present'] = all(
        token in abi for token in ('PDTypeEqual', 'PDMethodMatches', 'PDMatches'))
    # Exhaustive whitelist: testing can only bypass hook installation and bridge
    # into the REAL production signal/wrappers. It cannot replace stage, cancel,
    # native-depth handling, notification scheduling, or any transaction logic.
    # Preserve selector literals too: code_only() would erase those arguments.
    testing = re.findall(r'#if defined\(PD_LEASE_TESTING\)\s*\n(.*?)\n#(?:elif|endif)',
                         source, re.S)
    expected_testing = [
        'return YES;',
        '''void PDLeaseTestNativeChange(id owner, id presenter) { PDNativeChange(owner,presenter); }
void PDLeaseTestInvokeOwnerMutation(NSUInteger kind, id owner, id presenter, void (*original)(id,SEL,id)) {
    void (**slot)(id,SEL,id) = kind==0 ? &PDOriginalActivate : (kind==1 ? &PDOriginalDeactivate : &PDOriginalInvalidate);
    void (*saved)(id,SEL,id) = *slot;
    *slot = original;
    @try {
        SEL selector = NSSelectorFromString(kind==0 ? @"_activatePresenter:" : (kind==1 ? @"_deactivatePresenter:" : @"_invalidatePresenter:"));
        if (kind==0) PDOwnerActivate(owner,selector,presenter);
        else if (kind==1) PDOwnerDeactivate(owner,selector,presenter);
        else PDOwnerInvalidate(owner,selector,presenter);
    } @finally { *slot = saved; }
}''',
    ]

    def compact_surface(part):
        return re.sub(r'\s+', '', re.sub(r'//[^\n]*|/\*.*?\*/', '', part, flags=re.S))

    testing_directives = re.findall(
        r'^\s*#\s*(?:if|elif|ifdef|ifndef)\b[^\n]*\bPD_LEASE_TESTING\b[^\n]*',
        source, re.M)
    results['testing_only_bypasses_install_and_bridges_real_wrappers'] = (
        [line.strip() for line in testing_directives] == ['#if defined(PD_LEASE_TESTING)'] * 2 and
        [compact_surface(part) for part in testing] ==
        [compact_surface(part) for part in expected_testing])
    results['signal_declared_and_exercised'] = all(
        'PDLeaseTestNativeChange' in value for value in (source, header, fixture))
    results['owner_wrapper_bridge_declared_and_exercised'] = all(
        'PDLeaseTestInvokeOwnerMutation' in value for value in (source, header, fixture))
    results['no_substitute_lease_or_runtime_metadata_patching'] = not re.search(
        r'@implementation\s+PDPresenterLease\b|class_addIvar|class_addMethod|'
        r'object_setClass|method_setImplementation|#\s*(?:include|import)[^\n]*\.m["<>]',
        fixture)
    results['native_class_names_are_real_declarations'] = all(
        '@interface ' + name + ' : NSObject' in fixture for name in
        ('_UIScenePresenterOwner', 'UIScenePresentationManager', '_UIScenePresenter'))
    results['strongly_typed_native_ivars'] = all(token in fixture for token in (
        'UIScenePresentationManager *_scenePresentationManager;',
        '_UIScenePresenterOwner *_scenePresenterOwner;',
        '_UIScenePresenterOwner *_owner;',
        '_UIScenePresenter *_prioritizedPresenter;',
        'NSMutableOrderedSet *_activePresentersByPriority;',
        'NSMutableSet *_inactivePresentersByPriority;',
        'id<NSCopying, _UIComparable> _sortContext;',
    ))
    results['runtime_assertion_count_is_exact'] = (
        len(re.findall(r'^\s*CHECK\(', fixture, re.M)) == EXPECTED_CHECKS)
    results['all_test_groups_invoked_once'] = all(
        len(re.findall(r'^\s*' + name + r'\(\);', fixture, re.M)) == 1
        for name in re.findall(r'^static void (test\w+)\(void\)', fixture, re.M))
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-source', action='store_true')
    parser.add_argument('--artifacts-dir', type=Path)
    args = parser.parse_args()
    explicit = args.artifacts_dir or os.environ.get('CI_ARTIFACTS_DIR')
    evidence = Path(explicit) if explicit else ROOT / 'ci-artifacts'
    record = {
        'mode': 'source-only' if args.check_source else 'native',
        'runtime_executed': False, 'checks': None, 'failures': None,
        'expected_checks': EXPECTED_CHECKS, 'status': 'not-run',
        'scope': 'Full production lease + Foundation environment doubles; NOT private hooks/WindowServer',
    }

    def finish(status, error=None, exit_code=0):
        record.update(status=status, error=error)
        if explicit or not args.check_source:
            evidence.mkdir(parents=True, exist_ok=True)
            report = evidence / 'presenter-lease-report.json'
            record['report_path'] = str(report)
            report.write_text(json.dumps(record, indent=2) + '\n')
        print(json.dumps(record, indent=2))
        return exit_code

    try:
        payload = {key: path.read_bytes() for key, path in FILES.items()}
        record.update({key + '_sha256': hashlib.sha256(value).hexdigest()
                       for key, value in payload.items()})
        record['source_paths'] = {key: str(path) for key, path in FILES.items()}
        text = {key: value.decode('utf-8') for key, value in payload.items()}
        validation = validate(text)
        record['source_checks'] = validation
        record['source_failures'] = [name for name, passed in validation.items() if not passed]
        if record['source_failures']:
            return finish('source-invalid', 'Source expectations failed; no native execution', 1)
        if args.check_source:
            return finish('source-only-validated')
        if sys.platform != 'darwin':
            return finish('unsupported-platform', 'Native Foundation tests require macOS; no execution claimed', 2)
        xcrun = shutil.which('xcrun')
        if not xcrun:
            return finish('toolchain-unavailable', 'xcrun and macOS SDK clang are required', 2)
        sdk = subprocess.check_output(
            [xcrun, '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=30).strip()
        clang = subprocess.check_output(
            [xcrun, '--sdk', 'macosx', '--find', 'clang'], text=True, timeout=30).strip()
        if not Path(clang).is_file() or not Path(sdk).is_dir():
            return finish('toolchain-unavailable', 'Missing macOS SDK or clang', 2)
        evidence.mkdir(parents=True, exist_ok=True)
        build_log = evidence / 'presenter-lease-build.log'
        test_log = evidence / 'presenter-lease-test.log'
        # Prevent an old success log from masquerading as this run's output.
        test_log.write_text('Native runtime not started.\n')
        record['build_log'] = str(build_log)
        record['test_log'] = str(test_log)
        with tempfile.TemporaryDirectory(prefix='pandora-presenter-lease-') as temp:
            binary = Path(temp) / 'presenter-lease-tests'
            # Both original files are separate translation units. No extraction,
            # generated lease, .m include, swizzling, or production source edits.
            command = [clang, '-isysroot', sdk, '-fobjc-arc', '-fblocks',
                       '-DPD_LEASE_TESTING=1', '-Wall', '-Wextra',
                       '-framework', 'Foundation', '-I' + str(ROOT / 'Sources/Native'),
                       str(FILES['fixture']), str(FILES['production']), '-o', str(binary)]
            record['compile_command'] = command
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            build_log.write_text(compiled.stdout + compiled.stderr)
            record['compile_exit_code'] = compiled.returncode
            if compiled.returncode:
                return finish('compile-failed', 'Actual production lease/fixture did not compile', 1)
            record['binary_sha256'] = digest(binary)
            try:
                run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            except subprocess.TimeoutExpired as exc:
                record['runtime_executed'] = True
                def as_text(value):
                    return value.decode(errors='replace') if isinstance(value, bytes) else value or ''
                test_log.write_text(as_text(exc.stdout) + as_text(exc.stderr))
                return finish('runtime-timeout', 'Native process exceeded 30 seconds', 1)
            record['runtime_executed'] = True
            output = run.stdout + run.stderr
            test_log.write_text(output)
            if output:
                print(output, end='' if output.endswith('\n') else '\n', file=sys.stderr)
            record['exit_code'] = run.returncode
            record['inputs_unchanged'] = all(
                digest(path) == record[key + '_sha256'] for key, path in FILES.items())
            if not record['inputs_unchanged']:
                return finish('inputs-changed', 'Production/header/ABI/fixture changed during execution', 1)
            summary = re.findall(SUMMARY, output, re.M)
            if len(summary) != 1:
                return finish('invalid-summary', 'Missing or ambiguous native summary', 1)
            checks, failures = map(int, summary[0])
            record.update(checks=checks, failures=failures)
            if checks != EXPECTED_CHECKS:
                return finish('incomplete-runtime', 'Native assertion count was not exactly expected', 1)
            if failures or run.returncode:
                return finish('runtime-failed', 'Native regression assertions failed', 1)
            return finish('native-passed')
    except (OSError, ValueError, SyntaxError, subprocess.SubprocessError) as exc:
        return finish('driver-error', str(exc), 1)


if __name__ == '__main__':
    sys.exit(main())
