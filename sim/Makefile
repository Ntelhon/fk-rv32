# fk-core Verilator build
#   make                build obj_dir/Vfk_soc
#   make riscv-tests    fetch and build the rv32 riscv-tests ISA suite
#   make test           run the riscv-tests suite (builds it first if needed)
#   make lint           lint only
#
# Tools are taken from PATH; override with e.g. VERILATOR=/opt/verilator/bin/verilator
# or RISCV_PREFIX=/opt/riscv/bin/riscv64-unknown-elf-

VERILATOR    ?= verilator
RISCV_PREFIX ?= riscv64-unknown-elf-

ROOT      := $(abspath ..)
BUILD_DIR := $(ROOT)/build

RISCV_TESTS_URL ?= https://github.com/riscv-software-src/riscv-tests.git
RISCV_TESTS_REF ?= 87b04f07a51f57b134a935c6157222bbd35905d9
RISCV_TESTS_SRC := $(BUILD_DIR)/riscv-tests
# Directory holding the built rv32* test ELFs; point it at a prebuilt suite to skip building
RISCV_TESTS_DIR ?= $(RISCV_TESTS_SRC)/isa

RTL_DIR := $(ROOT)/rtl
SRCS := $(RTL_DIR)/core/fk_pkg.sv \
        $(RTL_DIR)/core/fk_decode.sv \
        $(RTL_DIR)/core/fk_alu.sv \
        $(RTL_DIR)/core/fk_div.sv \
        $(RTL_DIR)/core/fk_csr.sv \
        $(RTL_DIR)/core/fk_tlb.sv \
        $(RTL_DIR)/core/fk_ptw.sv \
        $(RTL_DIR)/core/fk_icache.sv \
        $(RTL_DIR)/core/fk_dcache.sv \
        $(RTL_DIR)/core/fk_axi_arb.sv \
        $(RTL_DIR)/core/fk_core.sv \
        $(RTL_DIR)/soc/fk_axi2simple.sv \
        $(RTL_DIR)/soc/fk_clint.sv \
        $(RTL_DIR)/soc/fk_plic.sv \
        $(RTL_DIR)/soc/fk_uart.sv \
        $(RTL_DIR)/soc/fk_soc.sv

VFLAGS := --cc --exe --build -j 0 -O3 --top-module fk_soc \
          -Wall -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-DECLFILENAME \
          -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
          --x-assign fast --x-initial fast \
          -CFLAGS "-O2" $(EXTRA_VFLAGS)

obj_dir/Vfk_soc: $(SRCS) tb.cpp
	$(VERILATOR) $(VFLAGS) $(SRCS) tb.cpp

lint:
	$(VERILATOR) --lint-only -Wall --top-module fk_soc $(SRCS)

$(RISCV_TESTS_SRC):
	$(ROOT)/scripts/fetch-src.sh $(RISCV_TESTS_URL) $(RISCV_TESTS_REF) $@

$(RISCV_TESTS_SRC)/isa/rv32ui-p-add: | $(RISCV_TESTS_SRC)
	$(MAKE) -C $(RISCV_TESTS_SRC)/isa XLEN=32 RISCV_PREFIX=$(RISCV_PREFIX) \
	  rv32ui rv32um rv32ua rv32mi rv32si

riscv-tests: $(RISCV_TESTS_SRC)/isa/rv32ui-p-add

# Only build the suite when using the default location
TEST_DEPS := obj_dir/Vfk_soc
ifeq ($(RISCV_TESTS_DIR),$(RISCV_TESTS_SRC)/isa)
TEST_DEPS += riscv-tests
endif

test: $(TEST_DEPS)
	RISCV_TESTS_DIR=$(RISCV_TESTS_DIR) ./run_tests.sh

clean:
	rm -rf obj_dir

.PHONY: lint riscv-tests test clean
