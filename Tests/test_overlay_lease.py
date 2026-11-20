#!/usr/bin/env python3
"""Compile the exact FINAL PDOverlayLease section + Foundation doubles on macOS.

--check-source checks extraction bytes/hashes, declarations and 46 CHECK sites;
it does NOT compile Objective-C or execute native assertions. Every invocation
writes overlay-lease-{report.json,build.log,test.log} under ci-artifacts (override
with --artifacts-dir / CI_ARTIFACTS_DIR). No UIKit, real window, or device testing.
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
    'production': ROOT / 'Sources/Native/PDNative.m',
    'header': ROOT / 'Sources/Native/PDNative.h',
    'abi': ROOT / 'Sources/Native/PDABI.h',
    'fixture': ROOT / 'Tests/overlay_lease.m',
    'driver': Path(__file__).resolve(),
}
EXPECTED_CHECKS = 46
EXPECTED_GROUPS = 9
INCLUDE = 'overlay-lease-under-test.inc'
SUMMARY = r'^PANDORA_OVERLAY_LEASE_TESTS checks=(\d+) failures=(\d+)$'
SCOPE = ('Exact final production PDOverlayLease section + Foundation environment doubles; '
         'NOT real UIKit containment, private FBS behavior, geometry, or WindowServer evidence. '
         'PDPresenterLease cancellation is an environment mock, not its transaction test.')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def code_only(text):
    # Lexical sanity only, never a replacement for the native clang build.
    return re.sub(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                  ' ', text, flags=re.S)


def balanced(text):
    stack = []
    pairs = {')': '(', ']': '[', '}': '{'}
    for char in code_only(text):
        if char in '([{':
            stack.append(char)
        elif char in pairs and (not stack or stack.pop() != pairs[char]):
            return False
    return not stack


def public_interface(text):
    found = re.findall(r'@interface PDOverlayLease\s*:\s*NSObject\b(.*?)@end', text, re.S)
    if len(found) != 1:
        raise ValueError('Expected exactly one public PDOverlayLease declaration')
    value = re.sub(r'\bNS_SWIFT_NAME\([^\n]*\)', '', found[0])
    value = re.sub(r'\b(?:nullable|nonnull|_Nullable|_Nonnull)\b', '', value)
    return re.sub(r'\s+', '', code_only(value))


def extract(source):
    starts = list(re.finditer(rb'^@interface PDOverlayLease \(\)[ \t]*\r?$', source, re.M))
    if len(starts) != 1:
        raise ValueError('Expected a unique final @interface PDOverlayLease () boundary')
    start = starts[0].start()
    section = source[start:]  # Exact bytes, including every byte through EOF.
    if not section.rstrip().endswith(b'@end'):
        raise ValueError('Final PDOverlayLease section must end at its @end')
    return start, section


def validate(payload, section):
    text = {key: data.decode('utf-8') for key, data in payload.items()}
    source = section.decode('utf-8')
    fixture = text['fixture']
    ast.parse(text['driver'], filename=str(FILES['driver']))
    result = {'driver_python_ast': True}
    for key in ('header', 'abi', 'fixture'):
        result[key + '_balanced_delimiters'] = balanced(text[key])
    result['extracted_section_balanced_delimiters'] = balanced(source)
    result['whole_final_section_not_selected_methods'] = (
        source.count('@interface PDOverlayLease ()') == 1 and
        source.count('@implementation PDOverlayLease') == 1 and
        len(re.findall(r'^@end\s*$', source, re.M)) == 2 and
        not re.search(r'^#\s*(?:if|else|elif|include|import|define)', source, re.M))
    result['public_declarations_match_real_header'] = (
        public_interface(text['header']) == public_interface(fixture))
    result['real_abi_header_included_not_reimplemented'] = (
        '#import "PDABI.h"' in fixture and all(token in text['abi'] for token in
        ('PDTypeEqual', 'PDMethodMatches', 'PDMatches')) and not re.search(
        r'\b(?:BOOL|bool)\s+PD(?:TypeEqual|MethodMatches|Matches)\s*\(', fixture))
    result['one_exact_generated_include'] = fixture.count('#include "' + INCLUDE + '"') == 1
    result['no_overlay_substitute_private_ticket_access_or_runtime_patching'] = not re.search(
        r'@implementation\s+PDOverlayLease\b|\bPDPendingOverlay\b|class_addIvar|class_addMethod|'
        r'object_setClass|method_setImplementation|method_exchangeImplementations|'
        r'#\s*(?:include|import)[^\n]*\.m["<>]', fixture)
    result['foundation_doubles_no_uikit_or_appkit_import'] = (
        '#import <Foundation/Foundation.h>' in fixture and not re.search(
        r'#\s*(?:import|include)[^\n]*(?:UIKit|AppKit)', fixture) and all(
        '@interface ' + name + ' : ' in fixture for name in
        ('UIView', 'UIViewController', 'UIWindow', 'FBSOrientationObserver')))
    result['durable_ticket_precedes_first_effect'] = (
        'PDPendingOverlay = lease;' in source and 'lease.attachDepth++;' in source and
        source.index('PDPendingOverlay = lease;') < source.index('lease.attachDepth++;') <
        source.index('[NSClassFromString(@"FBSOrientationObserver") new]'))
    result['pending_retry_and_attach_unwind_paths_present'] = all(token in source for token in (
        '+ (BOOL)finishPendingWithError:', 'self.attachDepth || self.retiring',
        'lease.attachDepth--;', 'lease.retirementRequested', 'self.orientationObserver = nil;',
        'self.controller.viewIfLoaded.superview', 'PDPendingOverlay = nil;'))
    result[f'runtime_assertion_sites_exactly_{EXPECTED_CHECKS}'] = (
        len(re.findall(r'^\s*CHECK\(', fixture, re.M)) == EXPECTED_CHECKS)
    tests = re.findall(r'^static void (test\w+)\(void\)', fixture, re.M)
    result['nine_groups_invoked_exactly_once_without_assertion_loops'] = (
        len(tests) == EXPECTED_GROUPS and all(len(re.findall(r'\b' + name + r'\(\);', fixture)) == 1
                                              for name in tests) and
        not re.search(r'\b(?:for|while)\s*\(', code_only(fixture)))
    return result


def as_text(value):
    return value.decode(errors='replace') if isinstance(value, bytes) else value or ''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-source', action='store_true')
    parser.add_argument('--artifacts-dir', type=Path)
    args = parser.parse_args()
    evidence = (args.artifacts_dir or Path(os.environ.get('CI_ARTIFACTS_DIR', ROOT / 'ci-artifacts'))).resolve()
    build_log = evidence / 'overlay-lease-build.log'
    test_log = evidence / 'overlay-lease-test.log'
    report_path = evidence / 'overlay-lease-report.json'
    record = {
        'mode': 'source-only' if args.check_source else 'native', 'status': 'not-run',
        'scope': SCOPE, 'runtime_executed': False, 'checks': None, 'failures': None,
        'expected_checks': EXPECTED_CHECKS, 'report_path': str(report_path),
        'build_log': str(build_log), 'test_log': str(test_log),
    }

    def finish(status, error=None, exit_code=0):
        record.update(status=status, error=error)
        if error:
            print('overlay-lease: ' + error, file=sys.stderr)
        try:
            evidence.mkdir(parents=True, exist_ok=True)
            report_path.write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
        except OSError as exc:
            print('overlay-lease: cannot write report: ' + str(exc), file=sys.stderr)
            return 1
        print('overlay-lease: {}; assertions={}/{}; native_executed={}'.format(
            status, record['checks'], EXPECTED_CHECKS, record['runtime_executed']))
        return exit_code

    try:
        evidence.mkdir(parents=True, exist_ok=True)
        # Clear old successes even if this run stops before compiler/runtime start.
        build_log.write_text('Compiler not invoked for this run.\n', encoding='utf-8')
        test_log.write_text('Native runtime not executed for this run.\n', encoding='utf-8')
        payload = {key: path.read_bytes() for key, path in FILES.items()}
        record['source_paths'] = {key: str(path) for key, path in FILES.items()}
        record['sha256'] = {key: sha(value) for key, value in payload.items()}
        start, section = extract(payload['production'])
        record['extraction'] = {
            'boundary': '@interface PDOverlayLease ()', 'start_offset_bytes': start,
            'start_line': payload['production'][:start].count(b'\n') + 1,
            'length_bytes': len(section), 'sha256': sha(section), 'through_eof': True,
        }
        record['assertion_sites'] = len(re.findall(rb'^\s*CHECK\(', payload['fixture'], re.M))
        validation = validate(payload, section)
        record['source_checks'] = validation
        record['source_check_count'] = len(validation)
        record['source_failures'] = [name for name, passed in validation.items() if not passed]
        if record['source_failures']:
            return finish('source-invalid', 'Source expectations failed: ' +
                          ', '.join(record['source_failures']), 1)

        def inputs_unchanged():
            record['inputs_unchanged'] = all(path.read_bytes() == payload[key]
                                             for key, path in FILES.items())
            return record['inputs_unchanged']

        with tempfile.TemporaryDirectory(prefix='pandora-overlay-lease-') as temp:
            work = Path(temp)
            extracted = work / INCLUDE
            staged_fixture = work / 'overlay_lease.m'
            extracted.write_bytes(section)
            staged_fixture.write_bytes(payload['fixture'])
            record['extracted_bytes_verified'] = (
                extracted.read_bytes() == payload['production'][start:] and
                sha(extracted.read_bytes()) == record['extraction']['sha256'] and
                staged_fixture.read_bytes() == payload['fixture'])
            if not record['extracted_bytes_verified']:
                return finish('extraction-mismatch', 'Generated source is not byte-identical', 1)
            if not inputs_unchanged():
                return finish('inputs-changed', 'Inputs changed while staging; rerun for a consistent hash', 1)
            if args.check_source:
                return finish('source-only-validated')
            if sys.platform != 'darwin':
                return finish('unsupported-platform',
                              'Native Foundation tests require Darwin/macOS clang; no native execution claimed', 2)
            xcrun = shutil.which('xcrun')
            if not xcrun:
                return finish('toolchain-unavailable', 'xcrun and macOS SDK clang are required', 2)
            sdk = subprocess.check_output(
                [xcrun, '--sdk', 'macosx', '--show-sdk-path'], text=True,
                stderr=subprocess.PIPE, timeout=30).strip()
            clang = subprocess.check_output(
                [xcrun, '--sdk', 'macosx', '--find', 'clang'], text=True,
                stderr=subprocess.PIPE, timeout=30).strip()
            if not Path(sdk).is_dir() or not Path(clang).is_file():
                return finish('toolchain-unavailable', 'Missing macOS SDK or clang', 2)
            binary = work / 'overlay-lease-tests'
            command = [clang, '-isysroot', sdk, '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
                       '-framework', 'Foundation', '-I' + str(ROOT / 'Sources/Native'),
                       '-I' + str(work), str(staged_fixture), '-o', str(binary)]
            record['compile_command'] = command
            record['linked_frameworks'] = ['Foundation']
            try:
                compiled = subprocess.run(command, capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired as exc:
                build_log.write_text(as_text(exc.stdout) + as_text(exc.stderr), encoding='utf-8')
                return finish('compile-timeout', 'Darwin clang exceeded 120 seconds', 1)
            build_log.write_text('SECTION_SHA256=' + sha(section) + '\n' +
                                 compiled.stdout + compiled.stderr, encoding='utf-8')
            record['compile_exit_code'] = compiled.returncode
            if compiled.returncode:
                if compiled.stdout or compiled.stderr:
                    print(compiled.stdout + compiled.stderr, file=sys.stderr, end='')
                return finish('compile-failed', 'Exact production section + fixture did not compile', 1)
            record['binary_sha256'] = sha(binary.read_bytes())
            try:
                run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            except subprocess.TimeoutExpired as exc:
                record['runtime_executed'] = True
                output = as_text(exc.stdout) + as_text(exc.stderr)
                test_log.write_text(output, encoding='utf-8')
                if output:
                    print(output, file=sys.stderr, end='')
                return finish('runtime-timeout', 'Native process exceeded 30 seconds', 1)
            record['runtime_executed'] = True
            record['exit_code'] = run.returncode
            output = run.stdout + run.stderr
            test_log.write_text(output, encoding='utf-8')
            if output:
                print(output, file=sys.stderr, end='' if output.endswith('\n') else '\n')
            if not inputs_unchanged():
                return finish('inputs-changed', 'Inputs changed during native execution; rerun', 1)
            summary = re.findall(SUMMARY, output, re.M)
            if len(summary) != 1:
                return finish('invalid-summary', 'Missing or ambiguous native assertion summary', 1)
            count, failed = map(int, summary[0])
            record.update(checks=count, failures=failed)
            if count != EXPECTED_CHECKS:
                return finish('incomplete-runtime', f'Expected exactly {EXPECTED_CHECKS} native assertions', 1)
            if failed or run.returncode:
                return finish('runtime-failed', 'Native containment/cleanup assertions failed', 1)
            return finish('native-passed')
    except (OSError, ValueError, SyntaxError, subprocess.SubprocessError) as exc:
        detail = as_text(getattr(exc, 'stderr', None))
        if detail:
            print(detail, file=sys.stderr, end='' if detail.endswith('\n') else '\n')
        return finish('driver-error', str(exc), 1)


if __name__ == '__main__':
    sys.exit(main())
