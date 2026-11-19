#!/usr/bin/env python3
"""Commit-bound SHA-256 manifest for tracked Pandora source and artifacts."""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def tree_digest(commit, entries):
    h = hashlib.sha256()
    h.update(b"Pandora tracked-source manifest v1\0")
    h.update(commit.lower().encode("ascii") + b"\0")
    for entry in entries:
        path = entry["_path_bytes"]
        h.update(len(path).to_bytes(8, "big"))
        h.update(path)
        for key in ("mode", "git_object_type", "sha256", "submodule_commit"):
            value = entry.get(key) or ""
            raw = value.encode("ascii")
            h.update(len(raw).to_bytes(4, "big"))
            h.update(raw)
    return h.hexdigest()


def build_manifest(root, requested_commit=None):
    root = Path(root).resolve()
    head = git(root, "rev-parse", "HEAD").decode().strip().lower()
    commit = (requested_commit or os.environ.get("GITHUB_SHA") or head).lower()
    if not commit or head != commit:
        raise ValueError("GITHUB_SHA/commit must exactly match checked-out HEAD")
    raw = git(root, "ls-tree", "-r", "-z", "--full-tree", commit)
    entries = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        try:
            meta, path = record.split(b"\t", 1)
            mode, kind, oid = meta.decode("ascii").split()
        except Exception as exc:
            raise ValueError("cannot parse git tree entry: %s" % exc)
        item = {"path": os.fsdecode(path), "mode": mode,
                "git_object_type": kind, "sha256": None,
                "submodule_commit": None, "_path_bytes": path}
        if kind == "blob":
            blob = git(root, "cat-file", "blob", oid)
            item["sha256"] = hashlib.sha256(blob).hexdigest()
        elif kind == "commit":
            item["submodule_commit"] = oid
        else:
            raise ValueError("unexpected tracked tree object type: " + kind)
        entries.append(item)
    entries.sort(key=lambda e: e["_path_bytes"])
    digest = tree_digest(commit, entries)
    for entry in entries:
        del entry["_path_bytes"]
    return {"schema": 1, "repository": "Tsangbaby/Pandora",
            "commit": commit, "binding": "GITHUB_SHA == checked-out HEAD",
            "hash_algorithm": "SHA-256", "source_tree_sha256": digest,
            "tracked_entries": len(entries), "entries": entries}


def write_artifact_sums(directory, output):
    directory = Path(directory).resolve()
    if not directory.is_dir():
        raise ValueError("artifact directory does not exist: " + str(directory))
    items = []
    for base, dirnames, filenames in os.walk(directory, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not (Path(base) / d).is_symlink())
        for name in filenames:
            path = Path(base) / name
            if name == "SHA256SUMS" or path.is_symlink() or not path.is_file():
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            items.append((path.relative_to(directory).as_posix(), digest))
    items.sort()
    text = "".join("%s  %s\n" % (digest, name) for name, digest in items)
    out = Path(output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print("SHA256SUMS: %d artifact files" % len(items))


def self_test():
    entries = [{"_path_bytes": b"Sources/a.swift", "mode": "100644",
                "git_object_type": "blob", "sha256": "ab" * 32,
                "submodule_commit": None}]
    first = tree_digest("0123456789abcdef", entries)
    assert first == tree_digest("0123456789abcdef", entries)
    assert first != tree_digest("fedcba9876543210", entries)
    changed = [dict(entries[0], sha256="cd" * 32)]
    assert first != tree_digest("0123456789abcdef", changed)
    print("manifest self-tests: PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--commit", help="expected commit; defaults to GITHUB_SHA then HEAD")
    parser.add_argument("--output", default="ci-artifacts/manifest.json")
    parser.add_argument("--hash-artifacts-dir", help="write standard sums for this directory")
    parser.add_argument("--output-sums", default="ci-artifacts/SHA256SUMS")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    try:
        if args.hash_artifacts_dir:
            write_artifact_sums(args.hash_artifacts_dir, args.output_sums)
        else:
            result = build_manifest(args.root, args.commit)
            out = Path(args.output)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n",
                           encoding="utf-8")
            print("manifest: %d tracked entries; SHA-256 %s" %
                  (result["tracked_entries"], result["source_tree_sha256"]))
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        print("manifest error: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
