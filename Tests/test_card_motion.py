#!/usr/bin/env python3
"""Run exact production card motion against macOS host doubles; stdout is JSON.

--check-source validates extraction/counts without compiling or running Swift.
Host build products and module cache are temporary; no repository artifacts.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

DRIVER = Path(__file__).resolve()
ROOT = DRIVER.parents[1]
FILES = {
    "motion": ROOT / "Sources/UI/ProbeCardMotion.swift",
    "fixture": ROOT / "Tests/card_motion.swift",
    "driver": DRIVER,
}
UIKIT_IMPORT = b"import UIKit\n"
HOST_IMPORTS = b"import Foundation\nimport CoreGraphics\n"
EXPECTED_TRIALS = 6
EXPECTED_CHECKS = 27
SUMMARY = re.compile(r"PANDORA_CARD_MOTION_TESTS trials=([0-9]{1,2}) checks=([0-9]{1,2}) failures=([0-9]{1,2})")


class SourceInvalid(ValueError):
    pass


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def hashes(inputs):
    return {key: sha256(data) for key, data in inputs.items()}


def read_inputs():
    return {key: path.read_bytes() for key, path in FILES.items()}


def validate(record, inputs):
    motion, fixture = inputs["motion"], inputs["fixture"]
    lines = motion.splitlines(keepends=True)
    if lines.count(UIKIT_IMPORT) != 1:
        raise SourceInvalid("Expected exactly one unmodified import UIKit LF line")
    line = lines.index(UIKIT_IMPORT)
    prefix, suffix = b"".join(lines[:line]), b"".join(lines[line + 1:])
    staged = prefix + HOST_IMPORTS + suffix
    restored = staged[:len(prefix)] + UIKIT_IMPORT + staged[len(prefix) + len(HOST_IMPORTS):]
    static_trials = len(re.findall(rb"^[ \t]*trial \{", fixture, re.M))
    static_checks = len(re.findall(rb"^[ \t]*check\(", fixture, re.M))
    ids = [int(n) for n in re.findall(rb'"([0-9]{2}) [^"\n]+"\)[ \t]*$', fixture, re.M)]
    validation = {
        "staged_body_byte_identical": restored == motion,
        "no_uikit_in_host_module": not re.search(rb"^[ \t]*(?:@\w+[ \t]+)*import\b[^\n]*\bUIKit\b",
                                                 staged + b"\n" + fixture, re.M),
        "only_production_motion": (motion.count(b"final class ProbeCardMotion {") == 1 and
                                   not re.search(rb"\b(?:class|struct|enum|typealias)\s+ProbeCardMotion\b", fixture)),
        "one_fixture_main": len(re.findall(rb"^@main\b", fixture, re.M)) == 1,
        "static_trial_count_exact": static_trials == EXPECTED_TRIALS,
        "static_check_count_exact": static_checks == EXPECTED_CHECKS,
        "assertion_ids_exact_and_ordered": ids == list(range(1, EXPECTED_CHECKS + 1)),
    }
    record.update(static_trials=static_trials, static_checks=static_checks, source_checks=validation,
                  extraction={"removed_import_count": 1, "removed_import_line": line + 1,
                              "removed_bytes": len(UIKIT_IMPORT), "header_sha256": sha256(HOST_IMPORTS),
                              "motion_body_sha256": sha256(prefix + suffix), "staged_motion_sha256": sha256(staged)})
    if not all(validation.values()):
        raise SourceInvalid("Extraction or fixture count validation failed")
    return staged


def invoke(record, step, command, folder, timeout):
    record[f"{step}_command"] = command
    record[f"{step}_timeout_seconds"] = timeout
    result = subprocess.run(command, cwd=folder, capture_output=True, text=True, errors="replace", timeout=timeout)
    record.update({f"{step}_exit_code": result.returncode, f"{step}_stdout": result.stdout,
                   f"{step}_stderr": result.stderr})
    return result


def run_native(record, motion, fixture):
    if sys.platform != "darwin":
        return "unsupported-platform", "Execution requires macOS; --check-source is not a runtime pass", 2
    xcrun = shutil.which("xcrun")
    if not xcrun:
        return "toolchain-unavailable", "xcrun and the macOS Swift SDK are required", 2
    with tempfile.TemporaryDirectory(prefix="pandora-card-motion-") as temp:
        folder = Path(temp)
        tool = [xcrun, "--no-cache", "--sdk", "macosx"]
        sdk = invoke(record, "sdk", tool + ["--show-sdk-path"], folder, 10)
        sdk_path = sdk.stdout.strip()
        if sdk.returncode or not sdk_path or not Path(sdk_path).is_dir():
            return "toolchain-unavailable", "No usable macOS SDK", 2
        record["sdk_path"] = sdk_path
        units = {"motion": motion, "fixture": fixture}
        paths = {key: folder / FILES[key].name for key in units}
        for key, path in paths.items():
            path.write_bytes(units[key])
        recorded_units = {key: path.read_bytes() for key, path in paths.items()}
        record.update(staged_sha256=hashes(recorded_units), staging_byte_identical=recorded_units == units)
        if not record["staging_byte_identical"]:
            return "staging-mismatch", "Staged units differ from captured bytes", 1
        binary = folder / "card-motion-tests"
        command = tool + ["swiftc", "-sdk", sdk_path, "-swift-version", "5", "-parse-as-library",
                          "-module-name", "CardMotionRegression", "-module-cache-path", str(folder / "module-cache"),
                          *map(str, paths.values()), "-o", str(binary)]
        built = invoke(record, "compile", command, folder, 60)
        if built.returncode:
            return "compile-failed", "Exact production and fixture did not compile", 1
        record["binary_sha256"] = sha256(binary.read_bytes())
        try:
            run = invoke(record, "runtime", [str(binary)], folder, 5)
        except subprocess.TimeoutExpired:
            record["runtime_executed"] = True
            return "runtime-timeout", "Host executable exceeded 5 seconds", 1
        record.update(runtime_executed=True, exit_code=run.returncode)
    return validate_run(record, run)


def validate_run(record, run):
    lines = run.stdout.splitlines()
    summary = SUMMARY.fullmatch(lines[-1]) if lines else None
    if not summary or any(not line.startswith("FAIL: ") for line in lines[:-1]):
        return "invalid-summary", "Expected one final summary, preceded only by assertion failures", 1
    trials, checks, failures = map(int, summary.groups())
    record.update(trials=trials, checks=checks, failures=failures)
    if failures != len(lines) - 1 or failures > checks:
        return "invalid-summary", "Assertion failure count does not match the runtime output", 1
    if (trials, checks) != (EXPECTED_TRIALS, EXPECTED_CHECKS):
        return "incomplete-runtime", "Runtime trial or assertion count differs from the fixture contract", 1
    if failures or run.returncode or run.stderr:
        return "runtime-failed", "Host executable reported failures, nonzero exit, or stderr", 1
    return "native-passed", None, 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-source", action="store_true")
    args = parser.parse_args()
    record = {
        "mode": "source-only" if args.check_source else "native",
        "platform": sys.platform,
        "scope": "Exact production motion and host doubles; not UIKit runtime or device rendering",
        "input_paths": {key: str(path) for key, path in FILES.items()},
        "expected_trials": EXPECTED_TRIALS, "expected_checks": EXPECTED_CHECKS,
        "trials": None, "checks": None, "failures": None,
        "compile_exit_code": None, "runtime_executed": False, "exit_code": None,
    }
    try:
        inputs = read_inputs()
        record["input_sha256_before"] = hashes(inputs)
        staged = validate(record, inputs)
        if args.check_source:
            status, error, code = "source-only-validated", None, 0
        else:
            status, error, code = run_native(record, staged, inputs["fixture"])
    except SourceInvalid as exc:
        status, error, code = "source-invalid", str(exc), 1
    except subprocess.TimeoutExpired as exc:
        status, error, code = "build-timeout", str(exc), 1
    except (OSError, subprocess.SubprocessError) as exc:
        status, error, code = "driver-error", str(exc), 1
    if "input_sha256_before" in record:
        try:
            after = hashes(read_inputs())
        except OSError:
            after = None
        record.update(input_sha256_after=after, inputs_unchanged=after == record["input_sha256_before"])
        if not record["inputs_unchanged"]:
            status, error, code = "inputs-changed", "Production, fixture, or driver changed during verification", 1
    record.update(status=status, error=error)
    print(json.dumps(record, indent=2, allow_nan=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
