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
# Restrict permitted output to known aggregate prefixes.
if grep -Ev '^(AGGREGATE_(V9_BENCHMARK|SELECTION|REVIEW|DIAGNOSTICS|ORIGINS) |UNVERIFIED: )' "$tmp/aggregate.txt" | grep -q .; then
  printf '%s\n' 'Aggregate output validation failed' >&2
  exit 1
fi
[[ "$(wc -l < "$tmp/aggregate.txt" | tr -d ' ')" == "6" ]] || {
  printf '%s\n' 'Aggregate output validation failed' >&2
  exit 1
}
cat "$tmp/aggregate.txt"
