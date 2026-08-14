#!/usr/bin/env bash
set -euo pipefail

# Swift 5 remains the source language for this staged migration. This build
# turns on the complete concurrency checker so application-owned diagnostics are
# visible in CI before the project switches its language mode to Swift 6.
#
# xcodebuild exits 0 when the only findings are warnings, and complete
# concurrency checking reports exactly that in Swift 5 mode — so the build
# status alone gates nothing. The log is scanned instead: a diagnostic whose
# file path is inside this checkout is ours and fails the job; toolchain notices
# that carry no source location (AppIntents metadata extraction, for one) are
# not ours to fix.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log="$(mktemp -t stampo-strict-concurrency)"
# A private, always-cold derived data directory. Incremental builds do not
# re-emit warnings for files they skip, so a warm cache would report a clean
# scan for code that has never been checked. It also keeps the strict-
# concurrency setting out of the DerivedData that Xcode.app is using.
derived_data="$(mktemp -d -t stampo-strict-concurrency-dd)"
trap 'rm -f "$log"; rm -rf "$derived_data"' EXIT

set +e
xcodebuild build \
  -project "$repo_root/Stampo.xcodeproj" \
  -scheme Stampo \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  | tee "$log"
build_status=${PIPESTATUS[0]}
set -e

if [ "$build_status" -ne 0 ]; then
  echo "xcodebuild failed with status ${build_status}."
  exit "$build_status"
fi

# Compiler diagnostics are "<path>:<line>:<col>: warning: <text>".
all_warnings="$(grep -E ':[0-9]+:[0-9]+: warning:' "$log" | sort -u || true)"
owned_warnings="$(printf '%s\n' "$all_warnings" | grep -F "${repo_root}/" || true)"

# Printed unconditionally: if the path filter ever stops matching, a run that
# scanned many warnings and owned none is visible in the job output instead of
# passing as a silent green.
echo "Located warnings: $(printf '%s' "$all_warnings" | grep -c . || true) total, \
$(printf '%s' "$owned_warnings" | grep -c . || true) inside ${repo_root}/"

if [ -n "$owned_warnings" ]; then
  echo
  echo "Application-owned warnings under complete concurrency checking:"
  printf '%s\n' "$owned_warnings"
  exit 1
fi
