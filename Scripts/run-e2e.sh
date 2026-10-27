#!/usr/bin/env bash
set -euo pipefail

# Runs the local, screen-owning XCTest suite against a separate, team-signed
# Stampo identity. The user's build must never become a test host: sharing its
# bundle id would share preferences, archive paths and privacy permissions.
#
# Build Stampo normally, copy it, change only that copy's id, then sign nested
# code and the app with their original entitlements and Apple Development.
# Ad-hoc signing changes the privacy identity on every build. The explicit
# runner entitlement also matters: Xcode can enable its sandbox independently
# of ENABLE_APP_SANDBOX, preventing the tests from reading capture files.
#
# This command occupies the display, mouse and keyboard. Obtain the user's
# consent before the first UI run in a session. Only the explicit --take-over
# flag authorizes gently closing running copies and reopening their exact paths.
# Permissions and system password dialogs are always handled by the user.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if [ "${STAMPO_E2E_CAFFEINATED:-0}" != 1 ]; then
  exec caffeinate -d -i env STAMPO_E2E_CAFFEINATED=1 /bin/bash "$repo_root/Scripts/run-e2e.sh" "$@"
fi

build=1
build_only=0
take_over=0
only=""
iterations=1
seed="${STAMPO_E2E_SEED:-}"
fail() { echo "E2E: $*" >&2; exit 2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-only) build_only=1; shift ;;
    --no-build) build=0; shift ;;
    --take-over) take_over=1; shift ;;
    --only) [ "$#" -ge 2 ] || fail "--only needs Class[/method]"; only="$2"; shift 2 ;;
    --iterations) [ "$#" -ge 2 ] || fail "--iterations needs N"; iterations="$2"; shift 2 ;;
    --seed) [ "$#" -ge 2 ] || fail "--seed needs N"; seed="$2"; shift 2 ;;
    --help) echo "Usage: bash Scripts/run-e2e.sh [--build-only | --no-build] [--only Class[/method]] [--iterations N] [--seed N] [--take-over]"; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[ "$build_only:$build" != "1:0" ] || fail "Choose --build-only or --no-build, not both."
case "$iterations" in ''|*[!0-9]*|0) fail "Iterations must be a positive integer." ;; esac
case "$only" in -*|*' '*|*'('*|*')'*) fail "Use Class[/method], without parentheses." ;; esac
if [ -z "$seed" ]; then seed="$(python3 -c 'import secrets; print(secrets.randbits(32))')"; fi
case "$seed" in ''|*[!0-9]*) fail "Seed must be an unsigned integer." ;; esac
python3 - "$seed" <<'PY' || fail "Seed must fit UInt64."
import sys
assert 0 <= int(sys.argv[1]) <= 2**64-1
PY

# Do not confuse a failed process query with an empty process list.
set +e
running_pids="$(pgrep -x Stampo 2>&1)"
process_status=$?
set -e
[ "$process_status" -le 1 ] || fail "Cannot list Stampo processes: $running_pids"
if [ "$process_status" -eq 0 ] && [ "$take_over" -ne 1 ]; then
  fail "Stampo is running (PID $running_pids). Close it yourself: two copies share global hotkeys and the notch panel. Nothing was closed."
fi

# Root's console session records locking; CoreGraphics reports the display's
# actual sleep state. Neither query requests or changes a privacy permission.
python3 - <<'PY' || fail "Unlock and wake the display before E2E."
import ctypes, plistlib, subprocess, sys
root = plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-n','Root','-d1','-a']))
if isinstance(root, list): root = root[0]
sessions = root.get('IOConsoleUsers')
if not isinstance(sessions, list) or not sessions:
    sys.exit('Cannot verify the active console session.')
if root.get('IOConsoleLocked', False) or any(s.get('CGSSessionScreenIsLocked', False) for s in sessions):
    sys.exit('The screen is locked.')
cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cg.CGMainDisplayID.restype = ctypes.c_uint32
cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
cg.CGDisplayIsAsleep.restype = ctypes.c_bool
if cg.CGDisplayIsAsleep(cg.CGMainDisplayID()):
    sys.exit('The display is asleep.')
print('Display: awake and unlocked')
PY
mkdir -p "$repo_root/build"
available_kb="$(df -Pk "$repo_root/build" | awk 'NR==2 {print $4}')"
[ -n "$available_kb" ] && [ "$available_kb" -ge 5242880 ] || fail "At least 5 GB must be free on the build volume."
identity="$(security find-identity -v -p codesigning | sed -n '/"Apple Development:/{s/.*) \([A-F0-9]*\) .*/\1/p;}' | head -1)"
[ -n "$identity" ] || fail "Apple Development signing identity is unavailable; ad-hoc подпись сбросит права."

e2e_root="$repo_root/build/e2e"
derived_data="$e2e_root/DerivedData"
app_path="$e2e_root/Stampo-E2E.app"
runner_path="$derived_data/Build/Products/Debug/StampoE2ETests-Runner.app"
mkdir -p "$e2e_root/artifacts"
artifacts="$(mktemp -d "$e2e_root/artifacts/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
export STAMPO_E2E_APP_PATH="$app_path" STAMPO_E2E_ARTIFACTS="$artifacts" STAMPO_E2E_SEED="$seed"

# The main checkout is where the user's normal Xcode build settings resolve.
# An explicit path is useful if that build was made elsewhere; neither path
# is built, launched, or signed by this script.
dev_app="${STAMPO_E2E_DEV_APP_PATH:-}"
if [ -z "$dev_app" ]; then
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
  primary_root="$(dirname "$common_dir")"
  dev_app="$(xcodebuild -project "$primary_root/Stampo.xcodeproj" -scheme Stampo -configuration Debug -destination 'platform=macOS' -showBuildSettings -json 2> "$artifacts/dev-settings.stderr" | python3 -c 'import json,sys; s=next(t["buildSettings"] for t in json.load(sys.stdin) if t["target"]=="Stampo"); print(s["BUILT_PRODUCTS_DIR"]+"/"+s["FULL_PRODUCT_NAME"])')"
fi
[ -d "$dev_app" ] || fail "Dev copy not found at $dev_app. Set STAMPO_E2E_DEV_APP_PATH to verify it."
codesign -dvv "$dev_app" 2> "$artifacts/dev-signature-before.txt"
defaults export com.hex000.Stampo - | shasum > "$artifacts/dev-defaults-before.sha1"
: > "$artifacts/restore-paths.txt"
owned_started=0
restore_armed=0
passport=""

process_path() {
  ps -ww -p "$1" -o command= | sed -n 's|^\(/.*\.app\)/Contents/MacOS/Stampo\( .*\)\{0,1\}$|\1|p'
}
finish() {
  local result=$?
  trap - EXIT
  set +e
  if [ "$owned_started" -eq 1 ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if [ "$(process_path "$pid")" = "$app_path" ]; then kill -TERM "$pid"; fi
    done < <(pgrep -x Stampo)
  fi
  if [ "$restore_armed" -eq 1 ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      open "$path" || result=1
      echo "Restored: $path"
    done < "$artifacts/restore-paths.txt"
  fi
  defaults export com.hex000.Stampo - | shasum > "$artifacts/dev-defaults-after.sha1"
  codesign -dvv "$dev_app" 2> "$artifacts/dev-signature-after.txt"
  if cmp -s "$artifacts/dev-defaults-before.sha1" "$artifacts/dev-defaults-after.sha1" && cmp -s "$artifacts/dev-signature-before.txt" "$artifacts/dev-signature-after.txt"; then
    echo "dev-копия не тронута"
  else
    echo "WARNING: DEV COPY CHANGED — preferences or signature differ. Inspect $artifacts" >&2
    result=1
  fi
  [ -z "$passport" ] || echo "$passport"
  echo "Artifacts: $artifacts"
  exit "$result"
}
trap finish EXIT

if [ "$process_status" -eq 0 ]; then
  # Resolve every path before touching any process. A failed resolution must
  # leave all copies running; there is deliberately no kill-by-name fallback.
  while IFS= read -r pid; do
    path="$(process_path "$pid")"
    [ -d "$path" ] || fail "Cannot resolve app path for Stampo PID $pid; nothing was closed."
    printf '%s\n' "$path" >> "$artifacts/restore-paths.txt"
  done <<< "$running_pids"
  sort -u "$artifacts/restore-paths.txt" -o "$artifacts/restore-paths.txt"
  restore_armed=1
  while IFS= read -r pid; do kill -TERM "$pid"; done <<< "$running_pids"
  for _ in $(seq 50); do
    remaining=0
    while IFS= read -r pid; do kill -0 "$pid" 2>/dev/null && remaining=1; done <<< "$running_pids"
    [ "$remaining" -eq 1 ] || break
    sleep 0.1
  done
  [ "$remaining" -eq 0 ] || fail "Stampo did not close gently in 5 seconds; no force quit was sent."
  echo "Take-over: closed the recorded Stampo copies gently."
fi

source_fingerprint() {
  python3 - <<'PY'
import hashlib, pathlib, subprocess
paths = subprocess.check_output(['git','ls-files','-z','--cached','--others','--exclude-standard','--','Stampo','StampoE2ETests','Stampo.xcodeproj','Scripts/run-e2e.sh']).split(b'\0')
h = hashlib.sha256()
for path in sorted(set(p for p in paths if p)):
    file = pathlib.Path(path.decode())
    if file.is_file(): h.update(path+b'\0'+file.read_bytes()+b'\0')
print(h.hexdigest())
PY
}
fingerprint="$(source_fingerprint)"
verify_team_signature() {
  local target="$1" output="$2"
  codesign -dvv "$target" 2> "$output" || fail "Cannot inspect signature: $target"
  grep -q '^TeamIdentifier=[A-Z0-9]' "$output" || fail "ad-hoc подпись сбросит права: $target"
  grep -q '^Authority=Apple Development:' "$output" || fail "Apple Development signature required: $target"
  codesign --verify --deep --strict "$target" || fail "Invalid code signature: $target"
}
if [ "$build" -eq 1 ]; then
  xcodebuild build -project Stampo.xcodeproj -scheme Stampo -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived_data" > "$artifacts/app-build.log" 2>&1 || { tail -n 35 "$artifacts/app-build.log"; exit 1; }
  source_app="$derived_data/Build/Products/Debug/Stampo.app"
  rm -rf "$app_path"
  ditto "$source_app" "$app_path"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.hex000.Stampo.e2e' "$app_path/Contents/Info.plist"
  codesign -d --entitlements :- "$source_app" > "$artifacts/app-entitlements.plist" 2> "$artifacts/source-signature.txt"
  while IFS= read -r -d '' nested; do
    relative="${nested#"$app_path/"}"
    entitlements="$artifacts/$(basename "$nested").entitlements.plist"
    codesign -d --entitlements :- "$source_app/$relative" > "$entitlements" 2> "$artifacts/$(basename "$nested").signature.txt"
    if [ -s "$entitlements" ]; then
      codesign --force --sign "$identity" --options runtime --entitlements "$entitlements" "$nested"
    else
      codesign --force --sign "$identity" --options runtime "$nested"
    fi
  done < <(find "$app_path/Contents" -depth -type f -name '*.dylib' -print0)
  codesign --force --sign "$identity" --options runtime --entitlements "$artifacts/app-entitlements.plist" "$app_path"
  xcodebuild build-for-testing -project Stampo.xcodeproj -scheme StampoE2E -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived_data" > "$artifacts/runner-build.log" 2>&1 || { tail -n 35 "$artifacts/runner-build.log"; exit 1; }
else
  [ -f "$e2e_root/source-fingerprint.txt" ] && [ "$(cat "$e2e_root/source-fingerprint.txt")" = "$fingerprint" ] || fail "Sources changed or no verified build exists; run without --no-build."
fi
verify_team_signature "$app_path" "$artifacts/e2e-signature.txt"
verify_team_signature "$runner_path" "$artifacts/runner-signature.txt"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" = com.hex000.Stampo.e2e ] || fail "Wrong E2E bundle id."
codesign -d --entitlements :- "$runner_path" > "$artifacts/runner-entitlements.plist" 2> "$artifacts/runner-entitlements.stderr"
python3 - "$artifacts/runner-entitlements.plist" <<'PY' || fail "Runner App Sandbox must be explicitly false; UI tests were not started."
import plistlib, sys
with open(sys.argv[1],'rb') as f: e=plistlib.load(f)
assert e.get('com.apple.security.app-sandbox') is False
print('UI runner App Sandbox: NO')
PY
if [ "$build" -eq 1 ]; then
  printf '%s\n' "$fingerprint" > "$e2e_root/source-fingerprint.txt"
  authority="$(sed -n 's/^Authority=Apple Development:/Apple Development:/p' "$artifacts/e2e-signature.txt")"
  passport="E2E: $app_path · id com.hex000.Stampo.e2e · подпись $authority · $(git rev-parse --abbrev-ref HEAD) · $(git rev-parse --short HEAD) · сборка $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -z "$(git status --porcelain)" ] || passport="$passport · uncommitted changes"
  printf '%s\n' "$passport" > "$e2e_root/build-passport.txt"
else
  passport="$(cat "$e2e_root/build-passport.txt")"
fi
printf '%s\n' "$passport" > "$artifacts/passport.txt"
if [ "$build_only" -eq 1 ]; then echo "Build and signature checks passed. No UI tests were run."; exit 0; fi

set +e
pgrep -x Stampo > "$artifacts/processes-before-ui.txt" 2> "$artifacts/processes-before-ui.stderr"
process_status=$?
set -e
[ "$process_status" -eq 1 ] || fail "A Stampo copy appeared during the build, or the process check failed. Close it yourself before retrying."
args=(-project Stampo.xcodeproj -scheme StampoE2E -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived_data" -parallel-testing-enabled NO -resultBundlePath "$artifacts/result.xcresult")
[ -z "$only" ] || args+=("-only-testing:StampoE2ETests/$only")
[ "$iterations" -le 1 ] || args+=(-test-iterations "$iterations")
action=test
if [ "$build" -eq 0 ]; then
  # xctestrun stores the previous run's expanded environment. Rebind a copy
  # for this run, and expand TESTROOT before moving it beside the artifacts.
  python3 - "$derived_data/Build/Products" "$artifacts" "$app_path" "$seed" <<'PYRUN'
import pathlib, plistlib, sys
products, artifacts = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
files = list(products.glob('StampoE2E_*.xctestrun'))
if len(files) != 1: sys.exit('Expected exactly one StampoE2E xctestrun; build again.')
state = plistlib.loads(files[0].read_bytes())
values = dict(STAMPO_E2E_APP_PATH=sys.argv[3], STAMPO_E2E_ARTIFACTS=str(artifacts), STAMPO_E2E_SEED=sys.argv[4])
def rebind(node):
    if isinstance(node, dict):
        result = {k: rebind(v) for k,v in node.items()}
        if 'TestBundlePath' in result:
            result.setdefault('EnvironmentVariables', {}).update(values)
        return result
    if isinstance(node, list): return [rebind(v) for v in node]
    if isinstance(node, str): return node.replace('__TESTROOT__', str(products))
    return node
(artifacts/'StampoE2E.xctestrun').write_bytes(plistlib.dumps(rebind(state)))
PYRUN
  args=(-xctestrun "$artifacts/StampoE2E.xctestrun" -destination 'platform=macOS' -parallel-testing-enabled NO -resultBundlePath "$artifacts/result.xcresult")
  [ -z "$only" ] || args+=("-only-testing:StampoE2ETests/$only")
  [ "$iterations" -le 1 ] || args+=(-test-iterations "$iterations")
  action=test-without-building
fi
owned_started=1
set +e
xcodebuild "$action" "${args[@]}" STAMPO_E2E_APP_PATH="$app_path" STAMPO_E2E_ARTIFACTS="$artifacts" STAMPO_E2E_SEED="$seed" 2>&1 | tee "$artifacts/test.log"
test_status=${PIPESTATUS[0]}
set -e
xcrun xcresulttool get test-results summary --path "$artifacts/result.xcresult" > "$artifacts/summary.json"
set +e
python3 - "$artifacts/summary.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f: s=json.load(f)
total, failed = s.get('totalTestCount',0), s.get('failedTests',0)
print(f'E2E tests reported: {total}, failed {failed}')
if not isinstance(total,int) or total <= 0 or failed or s.get('passedTests',0) <= 0 or s.get('skippedTests',0) or s.get('result') != 'Passed': sys.exit(1)
PY
summary_status=$?
set -e
[ "$test_status" -eq 0 ] || exit "$test_status"
exit "$summary_status"
