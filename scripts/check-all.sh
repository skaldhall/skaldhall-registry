#!/bin/bash
# Validate every pipeline against its sample file. Exit non-zero if any
# fails. Used as the registry-side regression test before publishing.
set -e
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
FAIL_LIST=()

for p in pipelines/*.yaml; do
  src=$(basename "$p" .yaml)
  samples="samples/${src}.txt"
  if [ ! -f "$samples" ]; then
    echo "MISSING SAMPLE: $src"
    FAIL=$((FAIL+1))
    FAIL_LIST+=("$src")
    continue
  fi
  # Extract the VRL from the pipeline yaml. Use python so we don't need
  # yq installed.
  vrl_file=$(mktemp)
  python3 - <<PY
import yaml
print(yaml.safe_load(open("$p"))["vrl"], end="")
PY
  python3 - "$p" "$vrl_file" <<'PY'
import sys, yaml
in_path, out_path = sys.argv[1], sys.argv[2]
with open(out_path, "w") as fh:
    fh.write(yaml.safe_load(open(in_path))["vrl"])
PY
  if scripts/validate.sh "$src" "$samples" "$vrl_file" >/tmp/check.log 2>&1 ; then
    PASS=$((PASS+1))
    echo "PASS: $src"
  else
    FAIL=$((FAIL+1))
    FAIL_LIST+=("$src")
    echo "FAIL: $src"
    tail -5 /tmp/check.log
  fi
  rm -f "$vrl_file"
done

echo
echo "============================================"
echo "PASS=$PASS  FAIL=$FAIL"
if [ ${#FAIL_LIST[@]} -gt 0 ]; then
  printf 'FAIL: %s\n' "${FAIL_LIST[@]}"
  exit 1
fi
