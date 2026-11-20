#!/usr/bin/env python3
"""Build the full production host transformer on arm64 macOS, with doubles.

--check-source validates source shape/count only, never compiles or runs, and
writes nothing unless --artifacts-dir is explicit. Native logs and the JSON
report default to ci-artifacts (overridable with --artifacts-dir or CI_ARTIFACTS_DIR).
"""
import argparse
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
NATIVE = ROOT / "Sources/Native"
FILES = {
    "production": NATIVE / "PDHostTransformer.m",
    "header": NATIVE / "PDHostTransformer.h",
    "abi": NATIVE / "PDABI.h",
    "fixture": ROOT / "Tests/host_transformer.m",
}
EXPECTED_CHECKS = 44
SUMMARY = re.compile(r"^PANDORA_HOST_TRANSFORMER_TESTS checks=(\d+) failures=(\d+)$", re.M)


def hashes(inputs):
    return {key + "_sha256": hashlib.sha256(data).hexdigest() for key, data in inputs.items()}


def read_inputs():
    return {key: path.read_bytes() for key, path in FILES.items()}


def validate(inputs):
    source, header, abi, fixture = (data.decode("utf-8") for data in inputs.values())
    api = ("PDCreateNativeHostTransformer", "PDNativeHostTransformerMatches")
    static_checks = len(re.findall(r"^\s*CHECK\(", fixture, re.M))
    return static_checks, {
        "api_in_production_header_and_fixture": all(
            name + "(" in text for name in api for text in (source, header, fixture)),
        "real_header_and_abi_imports": (
            '#import "PDHostTransformer.h"' in source and '#import "PDABI.h"' in source
            and '#import "PDHostTransformer.h"' in fixture and "PDMethodMatches(" in abi),
        "fixture_does_not_include_implementation_or_uikit": not re.search(
            r'^\s*#\s*(?:include|import)\s*["<](?:[^"<>]*\.m[">]|UIKit/)', fixture, re.M),
        "fixture_does_not_define_production_api": not re.search(
            r'^\s*(?:id|BOOL)\s+(?:' + "|".join(api) + r')\s*\(', fixture, re.M),
        "static_assertion_count_is_exact": static_checks == EXPECTED_CHECKS,
    }


def run_native(artifacts, record):
    if sys.platform != "darwin":
        return "unsupported-platform", "A real macOS SDK and runtime are required", 2
    if os.uname().machine != "arm64":
        # Production uses objc_msgSend for a large struct return. On x86_64
        # that dispatch would need objc_msgSend_stret; do not patch it in tests.
        return "unsupported-architecture", "Use native arm64 macOS Python (struct-return ABI)", 2
    xcrun = shutil.which("xcrun")
    if not xcrun:
        return "toolchain-unavailable", "xcrun is required", 2

    artifacts.mkdir(parents=True, exist_ok=True)
    build_log = artifacts / "host-transformer-build.log"
    test_log = artifacts / "host-transformer-test.log"
    record.update(build_log=str(build_log), test_log=str(test_log))
    build_log.write_text("Native build not started.\n", encoding="utf-8")
    test_log.write_text("Native runtime not started.\n", encoding="utf-8")
    sdk = subprocess.run([xcrun, "--sdk", "macosx", "--show-sdk-path"],
                         capture_output=True, text=True, timeout=30)
    sdk_path = sdk.stdout.strip()
    if sdk.returncode or not sdk_path or not Path(sdk_path).is_dir():
        build_log.write_text(sdk.stdout + sdk.stderr, encoding="utf-8")
        return "toolchain-unavailable", "xcrun did not resolve a macOS SDK", 2

    with tempfile.TemporaryDirectory(prefix="pandora-host-transformer-") as temp:
        binary = Path(temp) / "host-transformer-tests"
        # Two separate translation units, without production substitutions/defines.
        command = [xcrun, "--sdk", "macosx", "clang", "-isysroot", sdk_path,
                   "-arch", "arm64", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
                   "-I" + str(NATIVE), str(FILES["fixture"]), str(FILES["production"]),
                   "-framework", "Foundation", "-framework", "CoreGraphics", "-o", str(binary)]
        record["compile_command"] = command
        with build_log.open("w", encoding="utf-8") as log:
            built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        record["compile_exit_code"] = built.returncode
        if built.returncode:
            return "compile-failed", "Actual production/fixture did not compile; see build log", 1
        try:
            with test_log.open("w", encoding="utf-8") as log:
                run = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=30)
        except subprocess.TimeoutExpired:
            record["runtime_executed"] = True
            return "runtime-timeout", "Native process exceeded 30 seconds", 1

        record.update(runtime_executed=True, exit_code=run.returncode)
        summary = SUMMARY.findall(test_log.read_text(encoding="utf-8", errors="replace"))
        if len(summary) != 1:
            return "invalid-summary", "Missing or ambiguous native summary; see test log", 1
        checks, failures = map(int, summary[0])
        record.update(checks=checks, failures=failures)
        if checks != EXPECTED_CHECKS:
            return "incomplete-runtime", "Native assertion count did not match static count", 1
        if failures or run.returncode:
            return "runtime-failed", "Native regression assertions failed; see test log", 1
        return "native-passed", None, 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-source", action="store_true")
    parser.add_argument("--artifacts-dir", type=Path)
    args = parser.parse_args()
    artifacts = args.artifacts_dir
    if artifacts is None and not args.check_source and sys.platform == "darwin":
        artifacts = Path(os.environ.get("CI_ARTIFACTS_DIR") or ROOT / "ci-artifacts")

    record = {
        "mode": "source-only" if args.check_source else "native",
        "runtime_executed": False, "compile_exit_code": None,
        "checks": None, "failures": None, "expected_checks": EXPECTED_CHECKS,
        "scope": "Full production factory with environment doubles; NOT UIKit, WindowServer, or an Apple context test",
        "source_paths": {key: str(path) for key, path in FILES.items()},
    }
    original = {}
    try:
        inputs = read_inputs()
        original = hashes(inputs)
        record.update(original)
        record["static_checks"], validation = validate(inputs)
        record["source_checks"] = validation
        record["source_failures"] = [key for key, passed in validation.items() if not passed]
        if record["source_failures"]:
            status, error, code = "source-invalid", "Source expectations failed; no native execution", 1
        elif args.check_source:
            status, error, code = "source-only-validated", None, 0
        else:
            status, error, code = run_native(artifacts, record)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        status, error, code = "driver-error", str(exc), 1

    if original:
        try:
            record["inputs_unchanged"] = hashes(read_inputs()) == original
        except OSError:
            record["inputs_unchanged"] = False
        if not record["inputs_unchanged"]:
            status, error, code = "inputs-changed", "Production/header/ABI/fixture changed during validation", 1
    record.update(status=status, error=error)
    if artifacts is not None:
        artifacts.mkdir(parents=True, exist_ok=True)
        report = artifacts / "host-transformer-report.json"
        record["report_path"] = str(report)
        report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
