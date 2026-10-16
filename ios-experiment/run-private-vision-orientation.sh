#!/usr/bin/env bash
# Run locally on macOS only. Do not commit or upload BOL photographs.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash ios-experiment/run-private-vision-orientation.sh /path/to/private-images" >&2
  exit 2
fi
dir="$1"
umask 077
# Swift validates the image count, unique identifiers, and regular files.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$repo/ios-experiment/vision-orientation-private-benchmark.swift" "$tmp/main.swift"
swiftc -o "$tmp/private-vision-benchmark" "$tmp/main.swift" \
  "$repo/ios-experiment/BOLAddressParserV8.swift" \
  "$repo/ios-experiment/BOLParserV9.swift"
count="${BOL_TEST_MODE:-30}"
if [[ "$count" != "30" && "$count" != "3" && "$count" != "4" && "$count" != "5" ]]; then
  echo "Unsupported private benchmark mode" >&2
  exit 2
fi
"$tmp/private-vision-benchmark" "$dir" "$count" > "$tmp/trials.json" 2> "$tmp/private-errors.log" || {
  echo "Private benchmark failed; private diagnostics suppressed" >&2
  exit 1
}
python3 - "$tmp/trials.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))
mode=int(__import__("os").environ.get("BOL_TEST_MODE","30"))
expected={f"BOL_{i:02d}" for i in ([14,18,27] if mode==3 else [3,14,18,27] if mode==4 else [9,12,17,22,29] if mode==5 else range(1,31))}
assert len(rows)==4*len(expected), "Unexpected rotation trial count"
assert {r["file"] for r in rows} == expected, "Unexpected document identifiers"
print(f"PRIVATE APPLE VISION ROTATION REPORT: {len(expected)} documents (no OCR text or addresses)")
for name in sorted(expected):
    group=sorted((r for r in rows if r["file"]==name),key=lambda r:r["score"],reverse=True)
    assert len(group)==4
    assert {r["rotationClockwise"] for r in group} == {0,90,180,270}, "Missing or repeated rotation trial"
    assert len({r["pixelFingerprint"] for r in group}) == 4, "Rotated image pixels are not distinct"
    assert all(r["lines"] > 0 and 0 <= r["meanConfidence"] <= 1 for r in group), "Invalid OCR trial"
    if not any(r["stateZIPLines"] > 0 for r in group):
        print(f"{name} WARNING: no state/ZIP evidence; manual review required")
    for r in sorted(group,key=lambda r:r["rotationClockwise"]):
        print(f'{name} {r["rotationClockwise"]:3}deg: '
              f'lines={r["lines"]} roles={r["roleHeadings"]} '
              f'stateZIP={r["stateZIPLines"]} confidence={r["meanConfidence"]:.3f} '
              f'score={r["score"]:.2f}')
    for r in sorted(group,key=lambda r:r["rotationClockwise"]):
        print(f'{name} {r["rotationClockwise"]:3}deg V9 candidates: pickup={int(r["pickupDetected"])} delivery={int(r["deliveryDetected"])} both={int(r["pickupDetected"] and r["deliveryDetected"])}')
    for r in sorted(group,key=lambda r:r["rotationClockwise"]):
        print(f'{name} {r["rotationClockwise"]:3}deg diagnostic: '
              f'V8pickup={int(r["v8PickupDetected"])} V8delivery={int(r["v8DeliveryDetected"])} '
              f'pickupAnchors={r["pickupAnchors"]} deliveryAnchors={r["deliveryAnchors"]} '
              f'pickupRegionLines={r["pickupNearbyLines"]} deliveryRegionLines={r["deliveryNearbyLines"]}')
    for r in sorted(group,key=lambda r:r["rotationClockwise"]):
        print(f'{name} {r["rotationClockwise"]:3}deg fallback reasons: '
              f'pickup={r["v8PickupFallbackReason"]} delivery={r["v8DeliveryFallbackReason"]}')
    for r in sorted(group,key=lambda r:r["rotationClockwise"]):
        print(f'{name} {r["rotationClockwise"]:3}deg patterns: '
              f'completeLines={r["completeLocationLines"]} '
              f'pickupRegionStateZIP={r["pickupRegionStateZIPLines"]} '
              f'deliveryRegionStateZIP={r["deliveryRegionStateZIPLines"]} '
              f'pickupRegionComplete={r["pickupRegionCompleteLines"]} '
              f'deliveryRegionComplete={r["deliveryRegionCompleteLines"]}')
    for r in sorted(group,key=lambda r:r["rotationClockwise"]):
        print(f'{name} {r["rotationClockwise"]:3}deg fragments: '
              f'zipTokens={r["zipTokenLines"]} stateTokens={r["stateTokenLines"]} '
              f'cityStateFragments={r["cityStateFragmentLines"]} '
              f'completePickupOnly={r["completeLocationPickupOnly"]} '
              f'completeDeliveryOnly={r["completeLocationDeliveryOnly"]} '
              f'completeBothRegions={r["completeLocationBothRegions"]} '
              f'completeOutside={r["completeLocationOutsideRegions"]}')
    for r in sorted(group,key=lambda r:r["rotationClockwise"]):
        print(f'{name} {r["rotationClockwise"]:3}deg safe-diagnostics: '
              f'pickupOrigin={r["pickupOrigin"]} deliveryOrigin={r["deliveryOrigin"]} '
              f'pickupHeadingOwned={r["pickupHeadingOwnedLines"]} '
              f'deliveryHeadingOwned={r["deliveryHeadingOwnedLines"]} '
              f'conflictingAddressFields={r["conflictingAddressFields"]} '
              f'ambiguousColumnBoundaries={r["ambiguousColumnBoundaries"]}')
    margin=group[0]["score"]-group[1]["score"]
    if group[0]["stateZIPLines"]>0 and margin>=5:
        print(f'{name} candidate orientation: {group[0]["rotationClockwise"]}deg (margin {margin:.2f})')
    else:
        print(f'{name} orientation: AMBIGUOUS (margin {margin:.2f}); manual review required')
    print()
# Independently consolidate pickup and delivery from all four rotations.
# Only safe booleans and conflict flags leave the private runner.
combined_both=0
for name in sorted(expected):
    group=[r for r in rows if r["file"]==name]
    assert len({(r["consolidatedPickupDetected"], r["consolidatedDeliveryDetected"],
                 r["consolidatedPickupConflict"], r["consolidatedDeliveryConflict"],
                 r["consolidatedPickupDisagreement"], r["consolidatedDeliveryDisagreement"]) for r in group})==1
    item=group[0]
    pickup=item["consolidatedPickupDetected"]
    delivery=item["consolidatedDeliveryDetected"]
    if pickup and delivery: combined_both+=1
    allowed={"consistent","insufficient-evidence","city-only","state-only","zip-only","multiple-fields"}
    assert item["consolidatedPickupDisagreement"] in allowed
    assert item["consolidatedDeliveryDisagreement"] in allowed
    print(f'{name} cross-rotation: pickup={int(pickup)} delivery={int(delivery)} '
          f'both={int(pickup and delivery)} pickupConflict={int(item["consolidatedPickupConflict"])} '
          f'deliveryConflict={int(item["consolidatedDeliveryConflict"])} '
          f'pickupDifference={item["consolidatedPickupDisagreement"]} '
          f'deliveryDifference={item["consolidatedDeliveryDisagreement"]}')
print(f'CROSS-ROTATION CONSOLIDATED: both={combined_both}/{len(expected)}; '
      'candidate detections require photograph verification')
# Experimental selection comparison; candidates are unverified and never auto-accepted.
docs=[sorted((r for r in rows if r["file"]==name),key=lambda r:r["score"],reverse=True) for name in sorted(expected)]
ocr_top=sum(bool(g[0]["pickupDetected"] and g[0]["deliveryDetected"]) for g in docs)
any_both=sum(any(r["pickupDetected"] and r["deliveryDetected"] for r in g) for g in docs)
v8_any=sum(any(r["v8PickupDetected"] and r["v8DeliveryDetected"] for r in g) for g in docs)
needs_review=[name for name,g in zip(sorted(expected),docs) if not any(r["pickupDetected"] and r["deliveryDetected"] for r in g)]
print(f"EXPERIMENTAL SELECTION: OCR-score-best V9 both={ocr_top}/{len(expected)}; any-rotation V9 both={any_both}/{len(expected)}; any-rotation V8 both={v8_any}/{len(expected)}")
print("V9 not-both document IDs: " + (", ".join(needs_review) if needs_review else "none"))
print("Cross-rotation value conflicts checked privately; only conflict flags reported. Never auto-accept these detections.")
origin_counts={}
for r in rows:
    for key in ("pickupOrigin", "deliveryOrigin"):
        origin_counts[r[key]]=origin_counts.get(r[key],0)+1
print("SAFE_DIAGNOSTIC_ORIGINS: " + " ".join(f"{k}={origin_counts[k]}" for k in sorted(origin_counts)))
print("SAFE_DIAGNOSTIC_TOTALS: "
      f"rotation_conflict_pickup={sum(bool(r['consolidatedPickupConflict']) for r in rows)//4} "
      f"rotation_conflict_delivery={sum(bool(r['consolidatedDeliveryConflict']) for r in rows)//4} "
      f"no_both_all_rotations={sum(not any(r['pickupDetected'] and r['deliveryDetected'] for r in [x for x in rows if x['file']==name]) for name in expected)} "
      f"heading_owned_lines={sum(r['pickupHeadingOwnedLines']+r['deliveryHeadingOwnedLines'] for r in rows)} "
      f"conflicting_address_fields={sum(r['conflictingAddressFields'] for r in rows)} "
      f"ambiguous_column_boundaries={sum(r['ambiguousColumnBoundaries'] for r in rows)}")
print("SAFE_DIAGNOSTIC_FIELDS: aggregate-only origin, heading ownership, field conflicts, and column-boundary ambiguity")
print(f"All {len(expected)} documents and {len(rows)} rotation trials passed structural, pixel fingerprint, and OCR output checks; review state/ZIP warnings above.")
print("These are OCR detection diagnostics, not verified address accuracy.")
PY


