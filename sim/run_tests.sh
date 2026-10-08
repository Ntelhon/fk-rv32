#!/usr/bin/env bash
# Run the riscv-tests ISA suite on fk-core.
#   ./run_tests.sh [glob ...]       e.g. ./run_tests.sh 'rv32ui-p-*'
set -u
cd "$(dirname "$0")"

# Directory with built rv32 riscv-tests (see 'make riscv-tests')
ISA_DIR=${RISCV_TESTS_DIR:-../build/riscv-tests/isa}
SIM=./obj_dir/Vfk_soc

if [ ! -x "$SIM" ]; then
  echo "error: $SIM not found; run 'make' first" >&2; exit 2
fi
if ! ls "$ISA_DIR"/rv32ui-p-add >/dev/null 2>&1; then
  echo "error: no riscv-tests in '$ISA_DIR'" >&2
  echo "       run 'make riscv-tests', or set RISCV_TESTS_DIR to a prebuilt isa/ directory" >&2
  exit 2
fi

# Tests that require features this core intentionally does not implement:
#   ma_data: hardware misaligned load/store support (we trap; SBI emulates)
#   pmpaddr: requires at least one PMP entry (this core implements zero, which the spec allows)
SKIP_RE='-(ma_data|pmpaddr)$'

if [ $# -eq 0 ]; then
  set -- 'rv32ui-p-*' 'rv32um-p-*' 'rv32ua-p-*' 'rv32mi-p-*' 'rv32si-p-*' \
         'rv32ui-v-*' 'rv32um-v-*' 'rv32ua-v-*'
fi

pass=0; fail=0; failed=()
for pat in "$@"; do
  for t in $ISA_DIR/$pat; do
    [ -f "$t" ] || continue
    case "$t" in *.dump|*.o) continue;; esac
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
