# fk-core software build: OpenSBI (fw_jump), RV32 Linux with initramfs, DTB
#   make            fetch sources (first time) and build everything into ../build/out
#   make run        boot Linux in the Verilator model (build ../sim first)
#
# Tools are taken from PATH. Overridable variables:
#   ELF_PREFIX      bare-metal cross prefix   (default riscv64-unknown-elf-)
#   LINUX_PREFIX    Linux cross prefix        (default riscv64-unknown-linux-gnu-)
#   OPENSBI_PREFIX  OpenSBI cross prefix      (default $(LINUX_PREFIX); needs a PIE-capable linker)
#   OPENSBI_SRC     existing OpenSBI tree     (default: fetch $(OPENSBI_REF) into ../build)
#   LINUX_SRC       existing clean Linux tree (default: fetch $(LINUX_REF) into ../build)

ELF_PREFIX   ?= riscv64-unknown-elf-
LINUX_PREFIX ?= riscv64-unknown-linux-gnu-
OPENSBI_PREFIX ?= $(LINUX_PREFIX)
DTC          ?= dtc
J            ?= $(shell nproc)

ROOT  := $(abspath ..)
BUILD := $(ROOT)/build
OUT   := $(BUILD)/out
FETCH := $(ROOT)/scripts/fetch-src.sh

OPENSBI_URL ?= https://github.com/riscv-software-src/opensbi.git
OPENSBI_REF ?= v1.5.1
OPENSBI_SRC ?= $(BUILD)/opensbi
LINUX_URL   ?= https://github.com/torvalds/linux.git
LINUX_REF   ?= v6.6
LINUX_SRC   ?= $(BUILD)/linux

OPENSBI_OUT := $(BUILD)/opensbi-out
LINUX_OUT   := $(BUILD)/linux-out
KMAKE       := $(MAKE) -C $(LINUX_SRC) O=$(LINUX_OUT) ARCH=riscv CROSS_COMPILE=$(LINUX_PREFIX)

all: $(OUT)/fw_jump.bin $(OUT)/Image $(OUT)/fk-soc.dtb

$(OUT) $(LINUX_OUT):
	mkdir -p $@

# --- sources (fetched only when not overridden and not yet present) ---
$(BUILD)/opensbi:
	$(FETCH) $(OPENSBI_URL) $(OPENSBI_REF) $@

$(BUILD)/linux:
	$(FETCH) $(LINUX_URL) $(LINUX_REF) $@

# --- device tree ---
$(OUT)/fk-soc.dtb: fk-soc.dts | $(OUT)
	$(DTC) -I dts -O dtb -o $@ $<

# --- OpenSBI ---
# fw_jump.bin is loaded raw at 0x80000000 (recent OpenSBI builds are PIEs linked at 0)
$(OUT)/fw_jump.bin: | $(OPENSBI_SRC) $(OUT)
	$(MAKE) -C $(OPENSBI_SRC) -j$(J) O=$(OPENSBI_OUT) PLATFORM=generic \
	  PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei PLATFORM_RISCV_ABI=ilp32 \
	  CROSS_COMPILE=$(OPENSBI_PREFIX) FW_PAYLOAD=n FW_DYNAMIC=n
	cp $(OPENSBI_OUT)/platform/generic/firmware/fw_jump.bin $@

# --- init (freestanding, no libc needed) ---
$(OUT)/init: init/init.c | $(OUT)
	$(ELF_PREFIX)gcc -march=rv32ima_zicsr -mabi=ilp32 -O2 -ffreestanding -fno-builtin -nostdlib -static \
	  -Wl,-e,_start -Wl,--build-id=none -o $@ $<

# --- Linux ---
$(LINUX_OUT)/.config: linux.config | $(LINUX_SRC) $(LINUX_OUT)
	$(KMAKE) tinyconfig
	cd $(LINUX_SRC) && ARCH=riscv CROSS_COMPILE=$(LINUX_PREFIX) \
	  scripts/kconfig/merge_config.sh -m -O $(LINUX_OUT) $(LINUX_OUT)/.config $(abspath linux.config)
	$(LINUX_SRC)/scripts/config --file $(LINUX_OUT)/.config --set-str INITRAMFS_SOURCE $(LINUX_OUT)/initramfs.list
	$(KMAKE) olddefconfig

$(LINUX_OUT)/initramfs.list: $(OUT)/init | $(LINUX_OUT)
	printf 'dir /dev 755 0 0\nnod /dev/console 600 0 0 c 5 1\ndir /proc 755 0 0\ndir /sys 755 0 0\nfile /init %s 755 0 0\n' \
	  $(OUT)/init > $@

$(OUT)/Image: $(LINUX_OUT)/.config $(LINUX_OUT)/initramfs.list
	$(KMAKE) -j$(J) Image
	cp $(LINUX_OUT)/arch/riscv/boot/Image $@

run: all
	$(ROOT)/sim/obj_dir/Vfk_soc --no-tohost --max-cycles 0 --entry 0x80000000 \
	  --load $(OUT)/fw_jump.bin@0x80000000 --load $(OUT)/Image@0x80400000 \
	  --dtb $(OUT)/fk-soc.dtb@0x87f00000

clean:
	rm -rf $(OUT) $(LINUX_OUT) $(OPENSBI_OUT)

.PHONY: all run clean
