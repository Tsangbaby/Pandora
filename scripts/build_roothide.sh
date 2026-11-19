#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT/ci-artifacts}"
PIN="958fea4f779943505b15b93c88bb4db8d97b346d"
mkdir -p "$ARTIFACT_DIR"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

: "${THEOS:?THEOS must point to the pinned roothide/theos checkout}"
[ -d "$THEOS/.git" ] || fail "Theos checkout missing; initialize pinned roothide/theos first"
remote="$(git -C "$THEOS" remote get-url origin)"
case "$remote" in
  https://github.com/roothide/theos|https://github.com/roothide/theos.git|git@github.com:roothide/theos.git|ssh://git@github.com/roothide/theos.git) ;;
  *) fail "THEOS origin is not official roothide/theos: $remote" ;;
esac
actual="$(git -C "$THEOS" rev-parse HEAD)"
[ "$actual" = "$PIN" ] || fail "wrong Theos commit: expected $PIN, got $actual"
if ! git -C "$THEOS" submodule status --recursive > "$ARTIFACT_DIR/theos-submodules.txt"; then
  fail "Theos submodule status failed; toolchain/SDK dependencies may be incomplete"
fi
python3 - "$ARTIFACT_DIR/theos-submodules.txt" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
bad = [line for line in lines if line and line[0] in "-+U"]
if bad:
    print("ERROR: Theos recursive submodules are incomplete or mismatched:", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    raise SystemExit(1)
PY

: "${DEVELOPER_DIR:=/Applications/Xcode_16.4.app/Contents/Developer}"
export DEVELOPER_DIR
xcodebuild -version > "$ARTIFACT_DIR/xcode-version.txt"
python3 - "$ARTIFACT_DIR/xcode-version.txt" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
if not text.splitlines() or text.splitlines()[0].strip() != "Xcode 16.4":
    raise SystemExit("ERROR: expected Xcode 16.4 selected by DEVELOPER_DIR")
PY
xcrun --sdk iphoneos --show-sdk-version > "$ARTIFACT_DIR/sdk-version.txt"
xcrun --sdk iphoneos --show-sdk-path > "$ARTIFACT_DIR/sdk-path.txt"
SDK="$(cat "$ARTIFACT_DIR/sdk-path.txt")"
[ -d "$SDK" ] || fail "selected Xcode iPhoneOS SDK is missing: $SDK"
xcrun --find clang > "$ARTIFACT_DIR/clang-path.txt" || fail "Apple clang toolchain unavailable; no unknown toolchain download fallback"
command -v ldid >/dev/null || fail "ldid missing (install the declared Homebrew dependency)"
command -v dpkg-deb >/dev/null || fail "dpkg-deb missing (install the declared Homebrew dependency)"

MAKE_PREFIX="$(brew --prefix make)"
export PATH="$MAKE_PREFIX/libexec/gnubin:$PATH"
make --version > "$ARTIFACT_DIR/make-version.txt"
python3 - "$ARTIFACT_DIR/make-version.txt" <<'PY'
import sys
if "GNU Make" not in open(sys.argv[1], encoding="utf-8").read():
    raise SystemExit("ERROR: GNU make unavailable; refusing BSD make fallback")
PY

cd "$ROOT"
# The only supported package mode is RootHide; no rootless or device install path.
if ! make -j2 package SCHEME=roothide FINALPACKAGE=1 INSTALL=0 SYSROOT="$SDK"; then
  fail "RootHide package build failed; no unknown SDK/toolchain download fallback was attempted"
fi
shopt -s nullglob
debs=(packages/*.deb)
[ "${#debs[@]}" -eq 1 ] || fail "expected exactly one Pandora deb in packages/, found ${#debs[@]}"
PACKAGE_COPY="$ARTIFACT_DIR/$(basename "${debs[0]}")"
cp -p "${debs[0]}" "$PACKAGE_COPY"
printf '%s\n' "$PACKAGE_COPY" > "$ARTIFACT_DIR/deb-path.txt"
dpkg-deb -f "$PACKAGE_COPY" > "$ARTIFACT_DIR/control.txt"
dpkg-deb -c "$PACKAGE_COPY" > "$ARTIFACT_DIR/contents.txt"
printf 'Built package: %s\n' "$PACKAGE_COPY"
