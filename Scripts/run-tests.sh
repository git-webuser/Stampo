#!/usr/bin/env bash
set -euo pipefail

# Runs the whole test suite the way this project's environment needs it, so CI
# and a local check are the same command rather than two lists of flags that
# drift apart.
#
# Two settings are not preference:
#
#   -parallel-testing-enabled NO   With parallel testing on, the run hangs on
#                                  "waiting for workers to materialize" here
#                                  and never reports. Off, the suite finishes
#                                  in seconds.
#
#   CODE_SIGN_IDENTITY="-"         StampoTests is a *hosted* bundle
#                                  (TEST_HOST = Stampo.app), so the app must
#                                  launch for any test to run, and on arm64 an
#                                  unsigned bundle will not launch. Ad-hoc is
#                                  the smallest signature that does: no team,
#                                  no provisioning profile, no keychain.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log="$(mktemp -t stampo-tests)"
trap 'rm -f "$log"' EXIT

set +e
xcodebuild test \
  -project "$repo_root/Stampo.xcodeproj" \
  -scheme Stampo \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM="" \
  "$@" \
  | tee "$log"
test_status=${PIPESTATUS[0]}
set -e

# Swift Testing's own summary line, e.g. "Test run with 525 tests in 60 suites
# passed after 11.2 seconds." Printed back unconditionally: a run that builds,
# executes nothing and exits 0 is otherwise indistinguishable from a green one,
# and that is exactly the failure a test job exists to catch.
summary="$(grep -E 'Test run with [0-9]+ test' "$log" | tail -1 || true)"
count="$(printf '%s' "$summary" | sed -n 's/.*Test run with \([0-9][0-9]*\) test.*/\1/p')"

echo
if [ -z "$count" ]; then
  echo "No test-run summary in the log — the suite did not report how many tests ran."
  exit "${test_status:-1}"
fi
echo "Tests reported: ${count}"

if [ "$test_status" -ne 0 ]; then
  echo "xcodebuild test failed with status ${test_status}."
  exit "$test_status"
fi

if [ "$count" -eq 0 ]; then
  echo "The run executed zero tests, which is a failure however green it looks."
  exit 1
fi
