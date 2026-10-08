#!/usr/bin/env bash
# Check that the tools needed to build and run fk-rv32 are available.
# Honours the same overrides as the Makefiles:
#   VERILATOR, RISCV_PREFIX/ELF_PREFIX, LINUX_PREFIX, OPENSBI_PREFIX, DTC
# Exit status is non-zero if a required tool is missing.

VERILATOR=${VERILATOR:-verilator}
ELF_PREFIX=${ELF_PREFIX:-${RISCV_PREFIX:-riscv64-unknown-elf-}}
LINUX_PREFIX=${LINUX_PREFIX:-riscv64-unknown-linux-gnu-}
OPENSBI_PREFIX=${OPENSBI_PREFIX:-$LINUX_PREFIX}
DTC=${DTC:-dtc}

missing=0

check() {  # check <what> <command> [version-args]
  local what=$1 cmd=$2 vargs=${3:---version}
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ok       %-34s %s\n" "$what" "$("$cmd" $vargs 2>&1 | grep -m1 .)"
  else
    printf "  MISSING  %-34s (%s)\n" "$what" "$cmd"
    missing=$((missing + 1))
  fi
}

echo "simulator (sim/):"
check "Verilator >= 5.0"          "$VERILATOR"
check "C++ compiler"              "${CXX:-g++}"
check "make"                      make
echo "riscv-tests and /init:"
check "bare-metal RISC-V gcc"     "${ELF_PREFIX}gcc"
check "git"                       git
echo "Linux, OpenSBI, DTB (sw/):"
check "Linux RISC-V gcc"          "${LINUX_PREFIX}gcc"
check "device tree compiler"      "$DTC"
check "flex"                      flex
check "bison"                     bison
check "bc"                        bc
check "perl"                      perl

# Recent OpenSBI (v1.5) must be linked as a PIE
if command -v "${OPENSBI_PREFIX}gcc" >/dev/null 2>&1; then
  if "${OPENSBI_PREFIX}gcc" -fPIE -nostdlib -Wl,-pie -x c /dev/null -o /dev/null >/dev/null 2>&1; then
    echo "  ok       OpenSBI linker supports -pie       (${OPENSBI_PREFIX}ld)"
  else
    echo "  MISSING  OpenSBI linker supports -pie       (${OPENSBI_PREFIX}ld: set OPENSBI_PREFIX to a Linux toolchain)"
    missing=$((missing + 1))
  fi
fi

echo
if [ $missing -eq 0 ]; then
  echo "all requirements found"
else
  echo "$missing requirement(s) missing (see README.md, 'Requirements')"
  exit 1
fi
