#!/usr/bin/env python3
"""Strict, dependency-light verifier for Pandora's RootHide probe deb."""
import argparse
import hashlib
import json
import os
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

PACKAGE = "com.tsangbaby.pandora"
VERSION = "0.1.0~probe3"
ARCH = "iphoneos-arm64e"
TWEAK = "Library/MobileSubstrate/DynamicLibraries/Pandora.dylib"
FILTER = "Library/MobileSubstrate/DynamicLibraries/Pandora.plist"
PREFS = "Library/PreferenceBundles/PandoraPrefs.bundle"
PREF_INFO = PREFS + "/Info.plist"
PREF_ENTRY = "Library/PreferenceLoader/Preferences/Pandora.plist"
ROOTHIDE_REL = "@loader_path/.jbroot/"
EXPECTED_ARCHES = {"arm64", "arm64e"}
FAT_MAGICS = {b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
              b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
THIN_MAGICS = {b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
               b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}
DYLIB_COMMANDS = {0x0C, 0x18, 0x1F, 0x20, 0x23}


class VerifyError(Exception):
    pass


def run_capture(args):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, check=False)
    except OSError as exc:
        raise VerifyError("cannot run %s: %s" % (args[0], exc))
    if p.returncode:
        raise VerifyError("%s failed (%d): %s" %
                          (args[0], p.returncode, (p.stderr or p.stdout).strip()))
    return p.stdout


def plist(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except Exception as exc:
        raise VerifyError("invalid plist %s: %s" % (path, exc))


def version_tuple(value):
    return ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF)


def arch_name(cpu, subtype):
    if cpu == 0x0100000C:
        sub = subtype & 0x00FFFFFF
        if sub == 2:
            return "arm64e"
        if sub == 0:
            return "arm64"
    return "cpu-%#x-sub-%#x" % (cpu, subtype & 0x00FFFFFF)


def command_string(cmd, cmdsize, offset):
    if offset < 8 or offset >= cmdsize:
        raise VerifyError("invalid Mach-O load-command string offset")
    raw = cmd[offset:cmdsize].split(b"\0", 1)[0]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise VerifyError("non-UTF8 Mach-O dependency name")


def parse_thin(data):
    if len(data) < 28:
        raise VerifyError("truncated Mach-O header")
    raw_magic = data[:4]
    if raw_magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        endian = "<"
    elif raw_magic in (b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        endian = ">"
    else:
        raise VerifyError("not a supported Mach-O slice")
    magic = struct.unpack_from(endian + "I", data, 0)[0]
    is64 = magic in (0xFEEDFACF, 0xCFFAEDFE)
    hsize = 32 if is64 else 28
    if len(data) < hsize:
        raise VerifyError("truncated Mach-O header")
    fmt = endian + ("IiiIIIII" if is64 else "IiiIIII")
    fields = struct.unpack_from(fmt, data, 0)
    cpu, subtype, ncmds, sizeofcmds = fields[1], fields[2], fields[4], fields[5]
    cmd_end = hsize + sizeofcmds
    if cmd_end > len(data) or ncmds > 65535:
        raise VerifyError("invalid Mach-O load-command bounds")
    pos = hsize
    deps, min_versions, platforms = [], [], []
    signed = False
    for _ in range(ncmds):
        if pos + 8 > cmd_end:
            raise VerifyError("truncated Mach-O load command")
        cmd, cmdsize = struct.unpack_from(endian + "II", data, pos)
        if cmdsize < 8 or pos + cmdsize > cmd_end:
            raise VerifyError("invalid Mach-O load-command size")
        blob = data[pos:pos + cmdsize]
        basecmd = cmd & 0x7FFFFFFF
        if basecmd in DYLIB_COMMANDS:
            if cmdsize < 24:
                raise VerifyError("short dylib load command")
            nameoff = struct.unpack_from(endian + "I", blob, 8)[0]
            deps.append(command_string(blob, cmdsize, nameoff))
        elif basecmd == 0x1C:  # LC_RPATH | LC_REQ_DYLD
            if cmdsize >= 12:
                pathoff = struct.unpack_from(endian + "I", blob, 8)[0]
                deps.append(command_string(blob, cmdsize, pathoff))
        elif cmd == 0x32:  # LC_BUILD_VERSION
            if cmdsize < 24:
                raise VerifyError("short LC_BUILD_VERSION")
            _, _, platform, minos, _, _ = struct.unpack_from(endian + "IIIIII", blob, 0)
            platforms.append(platform)
            min_versions.append(version_tuple(minos))
        elif cmd == 0x24:  # LC_VERSION_MIN_IPHONEOS
            if cmdsize < 16:
                raise VerifyError("short LC_VERSION_MIN_IPHONEOS")
            minos = struct.unpack_from(endian + "I", blob, 8)[0]
            platforms.append(2)
            min_versions.append(version_tuple(minos))
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE
            signed = True
        pos += cmdsize
    if pos != cmd_end:
        raise VerifyError("Mach-O sizeofcmds does not match commands")
    return {"architecture": arch_name(cpu, subtype), "dependencies": deps,
            "min_versions": min_versions, "platforms": platforms,
            "code_signature": signed}


def parse_macho(data):
    if len(data) < 4:
        raise VerifyError("empty/truncated Mach-O")
    magic = data[:4]
    if magic not in FAT_MAGICS:
        return [parse_thin(data)]
    endian = ">" if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") else "<"
    is64 = magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
    if len(data) < 8:
        raise VerifyError("truncated fat Mach-O header")
    nfat = struct.unpack_from(endian + "I", data, 4)[0]
    entry_size = 32 if is64 else 20
    if not nfat or nfat > 64 or 8 + nfat * entry_size > len(data):
        raise VerifyError("invalid fat Mach-O architecture table")
    slices = []
    for i in range(nfat):
        pos = 8 + i * entry_size
        if is64:
            cpu, sub, off, size, _, _ = struct.unpack_from(endian + "iiQQII", data, pos)
        else:
            cpu, sub, off, size, _ = struct.unpack_from(endian + "iiIII", data, pos)
        if size <= 0 or off + size > len(data):
            raise VerifyError("fat Mach-O slice is out of bounds")
        item = parse_thin(data[off:off + size])
        if item["architecture"] != arch_name(cpu, sub):
            raise VerifyError("fat header disagrees with embedded Mach-O slice")
        slices.append(item)
    return slices


def is_macho_file(path):
    try:
        with open(path, "rb") as f:
            head = f.read(4)
        return head in FAT_MAGICS or head in THIN_MAGICS
    except OSError:
        return False


def parse_control(text):
    result, current = {}, None
    for line in text.splitlines():
        if not line:
            continue
        if line[:1] in (" ", "\t") and current:
            result[current] += "\n" + line[1:]
        elif ":" in line:
            key, value = line.split(":", 1)
            current = key
            result[key] = value.strip()
        else:
            raise VerifyError("malformed Debian control line")
    return result


def check_root_hide_dependencies(deps, require_substrate):
    errors = []
    for library in ("libsubstrate.dylib", "libroothide.dylib"):
        matching = {d for d in deps if d.rsplit("/", 1)[-1].lower() == library}
        expected = ROOTHIDE_REL + "usr/lib/" + library
        # Theos links libroothide for its API, not as a marker for every package.
        if (matching or (require_substrate and library == "libsubstrate.dylib")) and matching != {expected}:
            errors.append(library + " must resolve through " + expected)
    return errors


def check_control(control, control_dir, errors):
    expected = {"Package": PACKAGE, "Version": VERSION, "Architecture": ARCH,
                "Maintainer": "Tsangbaby", "Author": "Tsangbaby"}
    for key, value in expected.items():
        if control.get(key) != value:
            errors.append("control %s must be %r (got %r)" %
                          (key, value, control.get(key)))
    scripts = {"preinst", "postinst", "prerm", "postrm", "config"}
    if control_dir.exists():
        found = sorted(p.name for p in control_dir.iterdir() if p.name in scripts)
        if found:
            errors.append("maintainer scripts are forbidden: " + ", ".join(found))
    return {"fields": control, "maintainer_scripts": []}


def payload_files(root, errors):
    files, dirs = [], []
    for base, dirnames, filenames in os.walk(root, followlinks=False):
        for name in list(dirnames):
            path = Path(base) / name
            rel = path.relative_to(root).as_posix()
            dirs.append(rel)
            if path.is_symlink():
                errors.append("symlink in package data is forbidden: " + rel)
        for name in filenames:
            path = Path(base) / name
            rel = path.relative_to(root).as_posix()
            files.append(rel)
            if not stat.S_ISREG(path.lstat().st_mode):
                errors.append("non-regular package data is forbidden: " + rel)
            try:
                if b"/var/jb" in path.read_bytes():
                    errors.append("forbidden /var/jb reference in " + rel)
            except OSError as exc:
                errors.append("cannot read package member %s: %s" % (rel, exc))
    allowed_exact = {TWEAK, FILTER, PREF_ENTRY}
    bundle_prefix = PREFS + "/"
    required_dirs = set()
    for target in allowed_exact | {PREF_INFO}:
        parts = target.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            required_dirs.add("/".join(parts[:i]))
    for rel in files:
        if rel not in allowed_exact and not rel.startswith(bundle_prefix):
            errors.append("unexpected package data file: " + rel)
    for rel in dirs:
        if rel not in required_dirs and not rel.startswith(PREFS):
            errors.append("unexpected package data directory: " + rel)
    for target in sorted(allowed_exact | {PREF_INFO}):
        if not (root / target).is_file():
            errors.append("required package file missing: " + target)
    return sorted(files)


def check_plists(root, errors):
    filter_path = root / FILTER
    entry_path = root / PREF_ENTRY
    info_path = root / PREF_INFO
    filter_plist = plist(filter_path) if filter_path.is_file() else {}
    if not isinstance(filter_plist, dict) or set(filter_plist) != {"Filter"}:
        errors.append("Pandora.plist must contain only Filter")
    else:
        filt = filter_plist.get("Filter")
        if (not isinstance(filt, dict) or set(filt) != {"Bundles"} or
                filt.get("Bundles") != ["com.apple.springboard"]):
            errors.append("Filter must target only com.apple.springboard")
    entry_wrapper = plist(entry_path) if entry_path.is_file() else {}
    entry = entry_wrapper.get("entry") if isinstance(entry_wrapper, dict) else None
    if (not isinstance(entry, dict) or entry.get("bundle") != "PandoraPrefs" or
            entry.get("detail") != "PDProbeSettings" or entry.get("isController") is not True):
        errors.append("PreferenceLoader entry must select PDProbeSettings in PandoraPrefs")
    info = plist(info_path) if info_path.is_file() else {}
    executable = info.get("CFBundleExecutable") if isinstance(info, dict) else None
    if (not isinstance(executable, str) or not executable or "/" in executable or
            "\\" in executable):
        errors.append("PandoraPrefs Info.plist needs a safe CFBundleExecutable")
        executable = None
    exec_rel = PREFS + "/" + executable if executable else None
    if exec_rel and not (root / exec_rel).is_file():
        errors.append("Preference bundle executable missing: " + exec_rel)
    return {"filter": filter_plist, "preference_entry": entry,
            "prefs_executable": exec_rel}


def check_macho(root, files, prefs_exec, errors):
    macho_reports = {}
    for rel in files:
        path = root / rel
        if not is_macho_file(path):
            continue
        try:
            data = path.read_bytes()
            slices = parse_macho(data)
        except (OSError, VerifyError) as exc:
            errors.append("Mach-O parse failed for %s: %s" % (rel, exc))
            continue
        names = [s["architecture"] for s in slices]
        if set(names) != EXPECTED_ARCHES or len(names) != 2:
            errors.append("%s must contain exactly arm64 and arm64e (got %s)" %
                          (rel, ", ".join(names)))
        for index, item in enumerate(slices):
            versions = item["min_versions"]
            if not versions:
                errors.append("%s slice %s has no iOS minimum-version load command" %
                              (rel, names[index]))
            if any(v < (15, 0, 0) or v >= (16, 0, 0) for v in versions):
                errors.append("%s slice %s minimum iOS must be >=15.0 and <16.0" %
                              (rel, names[index]))
            if not item["platforms"] or any(p != 2 for p in item["platforms"]):
                errors.append("%s slice %s is not built for iOS device" %
                              (rel, names[index]))
            label = "%s slice %s" % (rel, names[index])
            errors.extend(label + ": " + error for error in
                          check_root_hide_dependencies(item["dependencies"], rel == TWEAK))
            if not item["code_signature"]:
                errors.append("%s lacks LC_CODE_SIGNATURE" % label)
        macho_reports[rel] = {"architectures": sorted(set(names)),
                              "minimum_ios": [{"architecture": s["architecture"],
                                               "versions": [list(v) for v in s["min_versions"]]}
                                              for s in slices],
                              "dependencies": sorted(set(d for s in slices
                                  for d in s["dependencies"])),
                              "all_slices_signed": all(s["code_signature"] for s in slices)}
    if TWEAK not in macho_reports:
        errors.append("Pandora.dylib is not a valid Mach-O")
    if prefs_exec and prefs_exec not in macho_reports:
        errors.append("PandoraPrefs executable is not a valid Mach-O")
    return macho_reports


def make_test_macho(cpu_subtype):
    build = struct.pack("<IIIIII", 0x32, 24, 2, 0x000F0000, 0x000F0000, 0)
    signature = struct.pack("<IIII", 0x1D, 16, 0, 0)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C,
                         cpu_subtype, 6, 2, len(build) + len(signature), 0, 0)
    return header + build + signature


def self_test():
    a, e = make_test_macho(0), make_test_macho(2)
    offset_a = 8 + 2 * 20
    offset_e = offset_a + len(a)
    fat = bytearray(struct.pack(">II", 0xCAFEBABE, 2))
    fat += struct.pack(">iiIII", 0x0100000C, 0, offset_a, len(a), 0)
    fat += struct.pack(">iiIII", 0x0100000C, 2, offset_e, len(e), 0)
    fat += a + e
    parsed = parse_macho(bytes(fat))
    assert {p["architecture"] for p in parsed} == EXPECTED_ARCHES
    assert all(p["code_signature"] and p["min_versions"] == [(15, 0, 0)]
               for p in parsed)
    substrate = ROOTHIDE_REL + "usr/lib/libsubstrate.dylib"
    roothide = ROOTHIDE_REL + "usr/lib/libroothide.dylib"
    assert not check_root_hide_dependencies([substrate], True)
    assert not check_root_hide_dependencies([substrate, roothide], True)
    assert check_root_hide_dependencies([], True)
    assert check_root_hide_dependencies([substrate, "/var/jb/usr/lib/libroothide.dylib"], True)
    assert check_root_hide_dependencies([substrate, "/usr/lib/libsubstrate.dylib"], True)
    assert parse_control("Package: x\nVersion: 1\n Description\n") == {
        "Package": "x", "Version": "1\nDescription"}
    print("verify_package self-tests: PASS")


def verify_package(deb, require_ldid):
    deb = Path(deb).resolve()
    report = {"schema": 1, "package_file": str(deb), "source_commit":
              os.environ.get("GITHUB_SHA"), "checks": {}, "errors": [], "success": False}
    errors = report["errors"]
    if not deb.is_file():
        errors.append("package file does not exist: " + str(deb))
        return report
    report["sha256"] = hashlib.sha256(deb.read_bytes()).hexdigest()
    dpkg = shutil.which("dpkg-deb")
    if not dpkg:
        errors.append("dpkg-deb is required to inspect this package")
        return report
    try:
        with tempfile.TemporaryDirectory(prefix="pandora-verify-") as tmp:
            root, control_dir = Path(tmp) / "data", Path(tmp) / "control"
            root.mkdir()
            run_capture([dpkg, "-e", str(deb), str(control_dir)])
            run_capture([dpkg, "-x", str(deb), str(root)])
            control_text = run_capture([dpkg, "-f", str(deb)])
            control = parse_control(control_text)
            report["checks"]["control"] = check_control(control, control_dir, errors)
            if b"/var/jb" in control_text.encode():
                errors.append("forbidden /var/jb reference in Debian control metadata")
            scripts = sorted(p.name for p in control_dir.iterdir()
                             if p.name in {"preinst", "postinst", "prerm", "postrm", "config"})
            report["checks"]["no_maintainer_scripts"] = not scripts

            files = payload_files(root, errors)
            report["checks"]["payload_files"] = files
            plists = check_plists(root, errors)
            filter_obj = plists.get("filter")
            filter_data = filter_obj.get("Filter") if isinstance(filter_obj, dict) else None
            springboard_only = (isinstance(filter_data, dict) and
                                filter_data.get("Bundles") == ["com.apple.springboard"])
            report["checks"]["plists"] = {k: v for k, v in plists.items()
                                           if k != "filter" and k != "preference_entry"}
            report["checks"]["plists"]["springboard_only"] = springboard_only
            report["checks"]["plists"]["prefs_entry"] = (
                isinstance(plists.get("preference_entry"), dict) and
                plists["preference_entry"].get("bundle") == "PandoraPrefs")
            macho = check_macho(root, files, plists.get("prefs_executable"), errors)
            report["checks"]["mach_o"] = macho
            tweak_path = root / TWEAK
            ldid = shutil.which("ldid")
            if not ldid:
                report["checks"]["ldid_entitlements_readable"] = "not-run"
                if require_ldid:
                    errors.append("ldid is required on CI for signature inspection")
            elif tweak_path.is_file() and TWEAK in macho:
                try:
                    run_capture([ldid, "-e", str(tweak_path)])
                    report["checks"]["ldid_entitlements_readable"] = True
                except VerifyError as exc:
                    errors.append("ldid -e rejected Pandora.dylib: " + str(exc))
                    report["checks"]["ldid_entitlements_readable"] = False
            else:
                report["checks"]["ldid_entitlements_readable"] = False
    except (VerifyError, OSError, ValueError) as exc:
        errors.append(str(exc))
    report["success"] = not errors
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("deb", nargs="?", help="RootHide Debian package to verify")
    parser.add_argument("--require-ldid", action="store_true",
                        help="fail if ldid -e cannot inspect the tweak")
    parser.add_argument("--json-out", help="also write the full report to this path")
    parser.add_argument("--self-test", action="store_true",
                        help="run stdlib-only parser tests")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.deb:
        parser.error("deb is required unless --self-test is used")
    report = verify_package(args.deb, args.require_ldid)
    output = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        out = Path(args.json_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(output, encoding="utf-8")
    sys.stdout.write(output)
    return 0 if report.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
