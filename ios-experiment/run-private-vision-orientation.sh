#!/usr/bin/env bash
# Local aggregate-only macOS benchmark wrapper.
# This script does not download, decrypt, or expose fixture data.
set -euo pipefail
umask 077
if [[ "$#" -ne 1 || ! -d "$1" ]]; then
  printf '%s\n' 'Usage: run-private-vision-orientation.sh PRIVATE_IMAGE_DIRECTORY' >&2
  exit 2
fi
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
cp "$repo/ios-experiment/aggregate-vision-benchmark.swift" "$tmp/main.swift"
swiftc -o "$tmp/aggregate-vision" \
  "$tmp/main.swift" \
  "$repo/ios-experiment/BOLAddressParserV8.swift" \
  "$repo/ios-experiment/BOLParserV9.swift"
# Buffer stdout in owner-only temporary storage; do not print partial diagnostic output.
# Suppress private image-related failure details and paths from the public log.
if ! "$tmp/aggregate-vision" "$1" 30 > "$tmp/aggregate.txt" 2>/dev/null; then
  printf '%s\n' 'Aggregate benchmark failed; private diagnostics suppressed' >&2
  exit 1
fi
# Strictly validate six numeric aggregate lines; unexpected text is never printed.
if ! python3 - "$tmp/aggregate.txt" <<'PY'
import pathlib
import re
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
patterns = [
    r"AGGREGATE_V9_BENCHMARK documents=30 rotations=120",
    r"AGGREGATE_SELECTION v9_score_best_both=\d+ v9_any_both=\d+ v8_any_both=\d+ consolidated_both=\d+",
    r"AGGREGATE_REVIEW no_both_any_rotation=\d+ no_state_zip_evidence=\d+ pickup_conflicts=\d+ delivery_conflicts=\d+",
    r"AGGREGATE_DIAGNOSTICS heading_owned=\d+ conflicting_fields=\d+ ambiguous_columns=\d+",
    r"AGGREGATE_ORIGINS none=\d+ region=\d+ split-region=\d+ layout=\d+ v8-fallback=\d+",
    r"UNVERIFIED: Candidate detection is not ground-truth accuracy\.",
]
valid = len(lines) == len(patterns) and all(
    re.fullmatch(pattern, line, flags=re.ASCII) for pattern, line in zip(patterns, lines)
)
if valid:
    origins = [int(x) for x in re.findall(r"=(\d+)", lines[4])]
    selections = [int(x) for x in re.findall(r"=(\d+)", lines[1])]
    reviews = [int(x) for x in re.findall(r"=(\d+)", lines[2])]
    valid = (
        sum(origins) == 240
        and all(0 <= x <= 30 for x in selections + reviews)
        and selections[0] <= selections[1]
        and selections[1] + reviews[0] == 30
    )
if not valid:
    raise SystemExit(1)
PY
then
  printf '%s\n' 'Aggregate output validation failed' >&2
  exit 1
fi
cat "$tmp/aggregate.txt"
