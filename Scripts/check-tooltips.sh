#!/usr/bin/env bash
# Every tooltip written out in the sources has a Russian translation.
#
# A gate rather than a test: `hoverTip` keys can only be found by reading the
# sources, and the test bundle is hosted by the app — which is not always
# allowed to read the folder the checkout is in. When it is not, a read does
# not fail, it waits; one sat for thirty-five minutes and took the suite with
# it. The shell that owns the checkout has no such problem.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOGUE="$ROOT/Stampo/Localizable.xcstrings"

if [[ ! -f "$CATALOGUE" ]]; then
  echo "error: no string catalogue at $CATALOGUE"
  exit 1
fi

python3 - "$ROOT" "$CATALOGUE" <<'PY'
import json, os, re, sys

root, catalogue = sys.argv[1], sys.argv[2]
strings = json.load(open(catalogue))["strings"]
translated = {
    key for key, entry in strings.items()
    if entry.get("localizations", {}).get("ru", {}).get("stringUnit", {}).get("value")
}
if len(translated) < 100:
    print(f"error: the catalogue reads as {len(translated)} translated keys — is it the right file?")
    sys.exit(1)

found = set()
for folder, _, files in os.walk(os.path.join(root, "Stampo")):
    for name in files:
        if not name.endswith(".swift"):
            continue
        text = open(os.path.join(folder, name), encoding="utf-8").read()
        found |= set(re.findall(r'hoverTip\(\s*"((?:[^"\\]|\\.)+)"', text))

if len(found) < 20:
    print(f"error: only {len(found)} tooltips found — has hoverTip been renamed?")
    sys.exit(1)

missing = sorted(found - translated)
if missing:
    print("Tooltips with no Russian:")
    for key in missing:
        print(f"  {key}")
    sys.exit(1)

print(f"Tooltips: {len(found)} written out, every one translated.")
PY
