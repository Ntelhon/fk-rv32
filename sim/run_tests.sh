#!/usr/bin/env bash
# Run the riscv-tests ISA suite on fk-core.
#   ./run_tests.sh [glob ...]       e.g. ./run_tests.sh 'rv32ui-p-*'
set -u
cd "$(dirname "$0")"

CHIPYARD_ENV=${CHIPYARD_ENV:-/home/fkarabulut/Desktop/Rigoletto/chipyard/.conda-env}
ISA_DIR=${ISA_DIR:-$CHIPYARD_ENV/riscv-tools/riscv64-unknown-elf/share/riscv-tests/isa}
SIM=./obj_dir/Vfk_soc

# Tests that require features this core intentionally does not implement:
#   ma_data: hardware misaligned load/store support (we trap; SBI emulates)
SKIP_RE='-ma_data$'

if [ $# -eq 0 ]; then
  set -- 'rv32ui-p-*' 'rv32um-p-*' 'rv32ua-p-*' 'rv32mi-p-*' 'rv32si-p-*' \
         'rv32ui-v-*' 'rv32um-v-*' 'rv32ua-v-*'
fi

pass=0; fail=0; failed=()
for pat in "$@"; do
  for t in $ISA_DIR/$pat; do
    case "$t" in *.dump) continue;; esac
    name=$(basename "$t")
    if [[ "$name" =~ $SKIP_RE ]]; then continue; fi
    if out=$($SIM --max-cycles 2000000 "$t" 2>&1); then
      pass=$((pass+1)); printf "  %-28s PASS\n" "$name"
    else
      fail=$((fail+1)); failed+=("$name")
      printf "  %-28s FAIL  %s\n" "$name" "$(echo "$out" | tail -1)"
    fi
  done
done

echo "passed: $pass  failed: $fail"
[ $fail -eq 0 ] || { printf '  %s\n' "${failed[@]}"; exit 1; }
