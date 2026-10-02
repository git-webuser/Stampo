#!/usr/bin/env bash
set -euo pipefail

# Builds the Debug app from this checkout and launches exactly that copy, so a
# hand check always runs the code that was just changed.
#
#   bash Scripts/run-dev.sh            build, quit any Stampo, launch this one
#   bash Scripts/run-dev.sh --demo     same, with the demo archive filled in
#   bash Scripts/run-dev.sh --no-build relaunch the last build without building
#   bash Scripts/run-dev.sh --restore  quit the dev build, reopen the copy that
#                                      was running before it
#
# Why a script and not "press ⌘R" or "open Stampo.app":
#
#   Several copies of Stampo.app share one bundle id — a DerivedData one per
#   checkout (every worktree gets its own), build/export, the archive, old ones
#   in the Trash. Launching by name, Dock or Spotlight lets LaunchServices pick
#   any of them, and an old build looks exactly like a fix that did not work.
#   So the path comes from xcodebuild itself, the launch is by that full path,
#   and the result is checked against the running processes.
#
#   Signing is left as the project sets it (Apple Development). The ad-hoc
#   identity run-tests.sh uses would make every build a new app to macOS, and
#   Screen Recording would be asked for again after each one.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_file="${TMPDIR:-/tmp}/stampo-run-dev-previous"

build=1
demo=0
restore=0
for arg in "$@"; do
  case "$arg" in
    --demo) demo=1 ;;
    --no-build) build=0 ;;
    --restore) restore=1 ;;
    *) echo "Unknown option: $arg (use --demo, --no-build or --restore)"; exit 2 ;;
  esac
done

running_paths() {
  # One line per running Stampo: the .app path, from the executable's path.
  ps -Ao args= | sed -n 's|^\(/.*/Stampo\.app\)/Contents/MacOS/Stampo.*|\1|p' | sort -u
}

quit_all() {
  pkill -x Stampo 2>/dev/null || true
  for _ in $(seq 50); do
    pgrep -x Stampo >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -x Stampo 2>/dev/null || true
  sleep 0.3
}

if [ "$restore" -eq 1 ]; then
  previous="$(cat "$state_file" 2>/dev/null || true)"
  [ -n "$previous" ] || previous="/Applications/Stampo.app"
  quit_all
  if [ -d "$previous" ]; then
    open "$previous"
    echo "Restored: $previous"
  else
    echo "Quit the dev build. Nothing to reopen: $previous does not exist."
  fi
  exit 0
fi

settings="$(xcodebuild -showBuildSettings -json \
  -project "$repo_root/Stampo.xcodeproj" -scheme Stampo -configuration Debug \
  -destination 'platform=macOS' 2>/dev/null)"
app="$(printf '%s' "$settings" | python3 -c '
import json, sys
for target in json.load(sys.stdin):
    s = target["buildSettings"]
    if s.get("WRAPPER_EXTENSION") == "app":
        print(s["BUILT_PRODUCTS_DIR"] + "/" + s["FULL_PRODUCT_NAME"])
        break
')"
if [ -z "$app" ]; then
  echo "xcodebuild did not report where the Debug app is built."
  exit 1
fi

# run-tests.sh builds the same app into the same DerivedData, signed ad-hoc.
# Launched like that, it is a stranger to the privacy settings, and macOS asks
# for Screen Recording again. A normal build signs it back, so --no-build
# gives way to one when it finds that signature.
team_signed() {
  codesign -dv "$app" 2>&1 | grep '^TeamIdentifier=[A-Z0-9]' >/dev/null
}
if [ "$build" -eq 0 ] && [ -d "$app" ] && ! team_signed; then
  echo "The last build is ad-hoc signed (run-tests.sh), building to sign it again."
  build=1
fi

if [ "$build" -eq 1 ]; then
  log="$(mktemp -t stampo-run-dev)"
  trap 'rm -f "$log"' EXIT
  echo "Building Debug from $repo_root …"
  set +e
  xcodebuild build \
    -project "$repo_root/Stampo.xcodeproj" \
    -scheme Stampo \
    -configuration Debug \
    -destination 'platform=macOS' \
    > "$log" 2>&1
  build_status=$?
  set -e
  if [ "$build_status" -ne 0 ]; then
    grep -E 'error:' "$log" | sort -u | head -30 || true
    echo "xcodebuild failed with status ${build_status}."
    exit "$build_status"
  fi
fi

if [ ! -d "$app" ]; then
  echo "No build at $app — run without --no-build first."
  exit 1
fi
if ! team_signed; then
  echo "$app is not signed with the project's team; not launching it, macOS would ask for permissions again."
  exit 1
fi

# Remember what was running before, so --restore can bring it back. Only a
# copy outside DerivedData counts: a dev build — this checkout's or another
# worktree's — is never the one to return to.
while IFS= read -r path; do
  case "$path" in
    */DerivedData/*) ;;
    ?*) printf '%s\n' "$path" > "$state_file" ;;
  esac
done < <(running_paths)

quit_all

if [ "$demo" -eq 1 ]; then
  open "$app" --args -StampoDemoArchive
else
  open "$app"
fi

for _ in $(seq 100); do
  running_paths | grep -qxF "$app" && break
  sleep 0.1
done

others="$(running_paths | grep -vxF "$app" || true)"
if ! running_paths | grep -qxF "$app"; then
  echo "Launched $app, but it is not running."
  [ -n "$others" ] && echo "Running instead: $others"
  exit 1
fi
if [ -n "$others" ]; then
  echo "Another copy is running alongside: $others"
  exit 1
fi

# The passport: which code is on screen. In Debug the real code sits in
# Stampo.debug.dylib next to a small stub, so the newest file in MacOS/ is the
# one that says when the build last changed.
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
sha="$(git -C "$repo_root" rev-parse --short HEAD)"
dirty=""
[ -n "$(git -C "$repo_root" status --porcelain)" ] && dirty=" + uncommitted changes"
newest="$(ls -t "$app/Contents/MacOS" | head -1)"
built="$(stat -f '%Sm' -t '%d.%m %H:%M:%S' "$app/Contents/MacOS/$newest")"
mode=""
[ "$demo" -eq 1 ] && mode=" · demo archive"

echo "Running: $app · branch $branch · $sha$dirty · built $built$mode"
