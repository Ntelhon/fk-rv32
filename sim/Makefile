# fk-core Verilator build
#   make            build obj_dir/Vfk_soc
#   make test       run the riscv-tests suite
#   make lint       lint only

CHIPYARD_ENV ?= /home/fkarabulut/Desktop/Rigoletto/chipyard/.conda-env
VERILATOR    ?= $(CHIPYARD_ENV)/bin/verilator
RISCV        ?= $(CHIPYARD_ENV)/riscv-tools
export PATH  := $(CHIPYARD_ENV)/bin:$(PATH)

RTL_DIR := ../rtl
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

test: obj_dir/Vfk_soc
	./run_tests.sh

clean:
	rm -rf obj_dir

.PHONY: lint test clean
