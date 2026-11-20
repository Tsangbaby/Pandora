#!/usr/bin/env python3
"""Exact Swift scanner, with macOS Foundation/CoreGraphics environment doubles.

--check-source only validates bytes/extraction/assertion count (not a typecheck).
Linux never claims native execution or writes artifacts unless --artifacts-dir is
explicit. macOS defaults to ci-artifacts/keyboard-monitor-*; no UIKit is linked.
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

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    "monitor": ROOT / "Sources/UI/ProbeKeyboardMonitor.swift",
    "core": ROOT / "Sources/Core/ProbeKeyboard.swift",
    "state": ROOT / "Sources/Core/ProbeState.swift",
    "fixture": ROOT / "Tests/keyboard_monitor.swift",
    "driver": Path(__file__).resolve(),
}
HEADER = b"import Foundation\nimport CoreGraphics\n"
UIKIT_IMPORT = b"import UIKit\n"
EXPECTED_CHECKS = 50
SUMMARY = re.compile(r"^PANDORA_KEYBOARD_MONITOR_TESTS checks=(\d+) failures=(\d+)$", re.M)


def hashes(inputs):
    return {name: hashlib.sha256(data).hexdigest() for name, data in inputs.items()}


def read_inputs():
    return {name: path.read_bytes() for name, path in FILES.items()}


def validate(inputs):
    monitor, fixture = inputs["monitor"], inputs["fixture"]
    lines = monitor.splitlines(keepends=True)
    if lines.count(UIKIT_IMPORT) != 1:
        raise ValueError("Expected exactly ONE unmodified import UIKit LF line")
    import_index = lines.index(UIKIT_IMPORT)
    prefix = b"".join(lines[:import_index])
    suffix = b"".join(lines[import_index + 1:])
    stripped = prefix + suffix
    staged = HEADER + stripped
    static_checks = len(re.findall(rb"^\s*check\(", fixture, re.M))
    assertion_ids = [int(n) for n in re.findall(rb'"(\d{2}) [^"\n]+"\)[ \t]*$', fixture, re.M)]
    combined = b"\n".join(inputs[name] for name in ("core", "state", "fixture"))
    compact_monitor = b" ".join(monitor.split())
    checks = {
        "one_uikit_import_only": len(re.findall(rb"^import UIKit\b", monitor, re.M)) == 1,
        "only_import_removed": len(monitor) - len(stripped) == len(UIKIT_IMPORT),
        "staged_body_byte_identical": staged[len(HEADER):][:len(prefix)] + UIKIT_IMPORT +
            staged[len(HEADER) + len(prefix):] == monitor,
        "scanner_declarations_exact": all(monitor.count(token) == 1 for token in (
            b"struct ProbeOutsideKeyboardObservation", b"enum ProbeKeyboardMonitor",
            b"static func outsideKeyboard(")),
        "real_objc_lookup_and_kind": monitor.count(b"NSClassFromString(") == 1 and
            monitor.count(b"item.isKind(of: $0)") == 1 and
            fixture.count(b"@objc(UIInputSetHostView)") == 1,
        "no_fixture_scanner_reimplementation": not re.search(
            rb"\b(?:func outsideKeyboard|enum ProbeKeyboardMonitor|struct ProbeOutsideKeyboardObservation)\b", combined),
        "no_uikit_in_host_module": not re.search(rb"^\s*import UIKit\b", staged + combined, re.M),
        "local_main_exact": len(re.findall(rb"^@main\b", fixture, re.M)) == 1,
        "static_assertion_count_exact": static_checks == EXPECTED_CHECKS,
        "assertion_ids_exact_and_ordered": assertion_ids == list(range(1, EXPECTED_CHECKS + 1)),
        "separate_strictly_higher_same_screen_only": all(token in compact_monitor for token in (
            b"$0 !== carrierWindow", b"$0.screen === carrierWindow.screen",
            b"$0.windowLevel > carrierWindow.windowLevel")),
        "scene_identity_and_transform_rejection":
            b"$0.windowScene === carrierWindow.windowScene" in compact_monitor and
            b"!item.transform.isIdentity" in compact_monitor and
            b"windowScene: UIWindowScene? = nil" in fixture and
            b"transform: CGAffineTransform = .identity" in fixture,
        "legal_crosswindow_bridge_exact": all(token in compact_monitor for token in (
            b"guard item.window === window else { return nil }",
            b"let inSource = item.convert(item.bounds, to: window)",
            b"let inCarrier = carrierWindow.convert(inSource, from: window)",
            b"let result = root.convert(inCarrier, from: carrierWindow)")) and
            b"root.convert(item.bounds, from: item)" not in compact_monitor,
        "filled_descendant_not_host_wrapper": all(token in compact_monitor for token in (
            b"let (item, ancestorClip, insideHost)",
            b"let visible = bounds.intersection(ancestorClip).intersection(root.bounds)",
            b"let fillAlpha = item.backgroundColor?.cgColor.alpha ?? 0",
            b"if insideHost && !isHost && fillAlpha > 0.01",
            b"frames.append(visible)", b"insideHost || isHost")),
        "all_descendants_use_bounded_queue_not_terminal_scan":
            b"guard visited < 256 else" in compact_monitor and
            b"guard children.count <= 512 - queue.count else" in compact_monitor and
            compact_monitor.index(b"guard children.count <= 512 - queue.count else") <
            compact_monitor.index(b"for child in children") and
            not re.search(rb"subviews\s*\.\s*(?:contains|first|filter)", monitor),
        "view_fakes_reject_crosswindow_conversions": all(token in fixture for token in (
            b"from view: UIView?", b"to view: UIView?", b"from window: UIWindow?",
            b"UIWindow bridge must stay on one screen")) and
            fixture.count(b"precondition(view.window === current,") == 2,
        "background_default_nil_with_real_cgcolor_alpha": all(token in fixture for token in (
            b"backgroundColor: FakeUIColor? = nil", b"fill: FakeUIColor? = nil",
            b"CGColor(gray: 1, alpha: whiteAlpha)", b"public let cgColor: CGColor")),
    }
    return staged, static_checks, checks, {
        "removed_import_count": 1, "removed_bytes": len(UIKIT_IMPORT),
        "removed_import_line": import_index + 1,
        "header_sha256": hashes({"header": HEADER})["header"],
        "monitor_body_sha256": hashes({"body": stripped})["body"],
        "staged_monitor_sha256": hashes({"staged": staged})["staged"],
    }


def run_native(artifacts, record, inputs, monitor):
    if sys.platform != "darwin":
        return "unsupported-platform", "Native execution requires macOS; source validation is NOT a native pass", 2
    xcrun = shutil.which("xcrun")
    if not xcrun:
        return "toolchain-unavailable", "xcrun and macOS Swift SDK are required", 2
    artifacts.mkdir(parents=True, exist_ok=True)
    build_log, test_log, binary = (artifacts / ("keyboard-monitor-" + name) for name in
                                   ("build.log", "test.log", "tests"))
    record.update(build_log=str(build_log), test_log=str(test_log), binary=str(binary))
    build_log.write_text("Build not started.\n", encoding="utf-8")
    test_log.write_text("Runtime not started.\n", encoding="utf-8")
    binary.unlink(missing_ok=True)  # A stale previous binary must not look like this build.
    sdk = subprocess.run([xcrun, "--sdk", "macosx", "--show-sdk-path"],
                         capture_output=True, text=True, timeout=30)
    if sdk.returncode or not Path(sdk.stdout.strip()).is_dir() or not sdk.stdout.strip():
        build_log.write_text(sdk.stdout + sdk.stderr, encoding="utf-8")
        return "toolchain-unavailable", "No usable macOS SDK", 2
    record["sdk_path"] = sdk.stdout.strip()
    with tempfile.TemporaryDirectory(prefix="pandora-keyboard-monitor-") as temp:
        folder = Path(temp)
        # Separate, exact compilation units; never concatenate/rewrite Core/State,
        # include Tests/main.swift, or substitute the production scanner function.
        units = {"monitor": monitor, **{key: inputs[key] for key in ("core", "state", "fixture")}}
        paths = {key: folder / FILES[key].name for key in units}
        for key, data in units.items():
            paths[key].write_bytes(data)
        record["staged_sha256"] = hashes({key: path.read_bytes() for key, path in paths.items()})
        record["staging_byte_identical"] = record["staged_sha256"] == hashes(units)
        if not record["staging_byte_identical"]:
            return "staging-mismatch", "Staged bytes differ from captured source inputs", 1
        command = [xcrun, "--sdk", "macosx", "swiftc", "-sdk", record["sdk_path"],
                   "-swift-version", "5", "-parse-as-library", "-module-name", "KeyboardMonitorRegression",
                   *map(str, paths.values()), "-o", str(binary)]
        record["compile_command"] = command
        with build_log.open("w", encoding="utf-8") as log:
            built = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        record["compile_exit_code"] = built.returncode
        if built.returncode:
            return "compile-failed", "Exact production/fixture typecheck failed; no runtime pass or production patch", 1
        record["binary_sha256"] = hashes({"binary": binary.read_bytes()})["binary"]
        try:
            with test_log.open("w", encoding="utf-8") as log:
                run = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=30)
        except subprocess.TimeoutExpired:
            record["runtime_executed"] = True
            return "runtime-timeout", "Native process exceeded 30 seconds", 1
        record.update(runtime_executed=True, exit_code=run.returncode)
        output = test_log.read_text(encoding="utf-8", errors="replace")
        summary = SUMMARY.findall(output)
        if len(summary) != 1:
            return "invalid-summary", "Missing/ambiguous native assertion summary", 1
        checks, failures = map(int, summary[0])
        record.update(checks=checks, failures=failures)
        if checks != EXPECTED_CHECKS:
            return "incomplete-runtime", f"Runtime check count is not exactly {EXPECTED_CHECKS}", 1
        if failures or run.returncode or re.search(r"^FAIL:", output, re.M):
            return "runtime-failed", "Native regression failed; inspect test log", 1
        return "native-passed", None, 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-source", action="store_true")
    parser.add_argument("--artifacts-dir", type=Path)
    args = parser.parse_args()
    artifacts = args.artifacts_dir
    if artifacts is None and not args.check_source and sys.platform == "darwin":
        artifacts = ROOT / "ci-artifacts"
    if artifacts is not None:
        artifacts = artifacts.resolve()
    record = {
        "mode": "source-only" if args.check_source else "native",
        "platform": sys.platform, "runtime_executed": False, "compile_exit_code": None,
        "checks": None, "failures": None, "expected_checks": EXPECTED_CHECKS,
        "scope": "Exact production scanner + Core/State, Foundation/CoreGraphics doubles; NOT UIKit, WindowServer or remote keyboard proof",
        "input_paths": {key: str(path) for key, path in FILES.items()},
    }
    original = {}
    try:
        inputs = read_inputs()
        original = hashes(inputs)
        record["input_sha256_before"] = original
        staged, record["static_checks"], validation, extraction = validate(inputs)
        record.update(source_checks=validation, extraction=extraction)
        if not all(validation.values()):
            status, error, code = "source-invalid", "Source shape/assertion counts failed", 1
        elif args.check_source:
            status, error, code = "source-only-validated", None, 0
        else:
            status, error, code = run_native(artifacts, record, inputs, staged)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        status, error, code = "driver-error", str(exc), 1
    if original:
        try:
            after = hashes(read_inputs())
        except OSError:
            after = {}
        record.update(input_sha256_after=after, inputs_unchanged=after == original)
        if after != original:
            status, error, code = "inputs-changed", "Production/fixture/driver changed during validation", 1
    record.update(status=status, error=error)
    if artifacts is not None:
        artifacts.mkdir(parents=True, exist_ok=True)
        report = artifacts / "keyboard-monitor-report.json"
        record["report_path"] = str(report)
        report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(record, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
