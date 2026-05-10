#!/bin/bash
# Validate a candidate VRL against its samples file.
# Usage: validate.sh <source-id> <samples-file> <vrl-file>
# Exits 0 if every sample produced an output record AND none of those
# records contains an `unmapped` key. Exits non-zero otherwise.
set -e

SRC=${1:?source-id}
SAMPLES=${2:?samples-file}
VRL=${3:?vrl-file}

VECTOR=${VECTOR:-/home/jradikk/OpenSIEM/bin/vector}
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Strip leading `# source: ...` comments from the samples file.
grep -v '^#' "$SAMPLES" | grep -v '^$' > "$TMP/in.txt" || true
N_IN=$(wc -l < "$TMP/in.txt")

if [ "$N_IN" -eq 0 ]; then
  echo "FAIL($SRC): no samples"
  exit 2
fi

cat > "$TMP/config.yaml" <<EOF
data_dir: $TMP/data
api: {enabled: false}
sources:
  in:
    type: file
    include: ["$TMP/in.txt"]
    read_from: beginning
    ignore_older_secs: 600
transforms:
  envelope:
    type: remap
    inputs: [in]
    source: |
      .source_id = "$SRC"
      .vector_host = "test"
      .observed_at = now()
  parse:
    type: remap
    inputs: [envelope]
    drop_on_abort: false
    drop_on_error: false
    reroute_dropped: false
    source: |
$(sed 's/^/      /' "$VRL")
sinks:
  out:
    type: file
    inputs: [parse]
    path: "$TMP/out.ndjson"
    encoding:
      codec: json
EOF
mkdir -p "$TMP/data"

# Compile-time validation
if ! "$VECTOR" validate --no-environment "$TMP/config.yaml" >"$TMP/validate.log" 2>&1; then
  echo "FAIL($SRC): vector validate failed"
  cat "$TMP/validate.log"
  exit 3
fi

# Run for ~10s to flush samples through
timeout 12 "$VECTOR" --quiet --config "$TMP/config.yaml" >"$TMP/run.log" 2>&1 || true

if [ ! -s "$TMP/out.ndjson" ]; then
  echo "FAIL($SRC): no output produced"
  echo "--- runlog ---"
  tail -30 "$TMP/run.log"
  exit 4
fi

N_OUT=$(wc -l < "$TMP/out.ndjson")

# Inspect for unmapped fields and required OCSF fields.
python3 - <<PY
import json, sys
out_path = "$TMP/out.ndjson"
errs = []
miss_required = 0
unmapped_count = 0
with open(out_path) as fh:
    n = 0
    for line in fh:
        n += 1
        try:
            d = json.loads(line)
        except Exception as e:
            errs.append(f"line {n}: bad JSON: {e}")
            continue
        if "unmapped" in d:
            unmapped_count += 1
            # Show only the first occurrence
            if unmapped_count == 1:
                errs.append(f"line {n}: unmapped present: keys={list(d.get('unmapped',{}).keys())[:8]}")
        # Required OCSF fields
        for k in ("class_uid", "time", "severity_id", "metadata"):
            if k not in d or d[k] in (None, "", []):
                if miss_required < 3:
                    errs.append(f"line {n}: required field missing: {k}")
                miss_required += 1
                break
print(f"records: {n}")
print(f"unmapped_lines: {unmapped_count}")
print(f"required_missing_lines: {miss_required}")
if errs:
    for e in errs[:10]:
        print("ERR:", e)
sys.exit(0 if (unmapped_count == 0 and miss_required == 0 and n > 0) else 5)
PY
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL($SRC): unmapped or missing-required (out=$TMP/out.ndjson)"
  echo "--- 1st output line ---"
  head -1 "$TMP/out.ndjson"
  exit 5
fi

echo "OK($SRC): records=$N_OUT in=$N_IN"
exit 0
