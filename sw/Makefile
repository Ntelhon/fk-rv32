# fk-core software build: OpenSBI (fw_jump), RV32 Linux with initramfs, DTB
#   make            build everything into out/
#   make run        boot Linux in the Verilator model

CHIPYARD_ENV ?= /home/fkarabulut/Desktop/Rigoletto/chipyard/.conda-env
export PATH  := $(CHIPYARD_ENV)/bin:$(CHIPYARD_ENV)/riscv-tools/bin:$(PATH)

FIREMARSHAL ?= /home/fkarabulut/Desktop/Rigoletto/chipyard/software/firemarshal/boards/default
BUILD := build
OUT   := out
J     ?= $(shell nproc)

ELF_CC   := riscv64-unknown-elf-gcc
LINUX_CC := riscv64-unknown-linux-gnu-

all: $(OUT)/fw_jump.elf $(OUT)/Image $(OUT)/fk-soc.dtb

$(OUT):
	mkdir -p $@

# --- device tree ---
$(OUT)/fk-soc.dtb: fk-soc.dts | $(OUT)
	dtc -I dts -O dtb -o $@ $<

# --- OpenSBI ---
$(BUILD)/opensbi:
	mkdir -p $(BUILD) && git clone -q --shared $(FIREMARSHAL)/firmware/opensbi $@

$(OUT)/fw_jump.elf: | $(BUILD)/opensbi $(OUT)
	$(MAKE) -C $(BUILD)/opensbi -j$(J) O=../opensbi-out PLATFORM=generic \
	  PLATFORM_RISCV_XLEN=32 PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei PLATFORM_RISCV_ABI=ilp32 \
	  CROSS_COMPILE=riscv64-unknown-elf- FW_PAYLOAD=n FW_DYNAMIC=n
	cp $(BUILD)/opensbi-out/platform/generic/firmware/fw_jump.elf $@

# --- init ---
$(OUT)/init: init/init.c | $(OUT)
	$(ELF_CC) -march=rv32ima_zicsr -mabi=ilp32 -O2 -ffreestanding -fno-builtin -nostdlib -static \
	  -Wl,-e,_start -Wl,--build-id=none -o $@ $<

# --- Linux ---
$(BUILD)/linux:
	mkdir -p $(BUILD) && git clone -q --shared $(FIREMARSHAL)/linux $@

LINUX_OUT := $(abspath $(BUILD)/linux-out)

$(LINUX_OUT)/.config: linux.config | $(BUILD)/linux
	mkdir -p $(LINUX_OUT)
	$(MAKE) -C $(BUILD)/linux O=$(LINUX_OUT) ARCH=riscv CROSS_COMPILE=$(LINUX_CC) tinyconfig
	cd $(BUILD)/linux && ARCH=riscv CROSS_COMPILE=$(LINUX_CC) \
	  scripts/kconfig/merge_config.sh -m -O $(LINUX_OUT) $(LINUX_OUT)/.config $(abspath linux.config)
	$(BUILD)/linux/scripts/config --file $(LINUX_OUT)/.config --set-str INITRAMFS_SOURCE $(LINUX_OUT)/initramfs.list
	$(MAKE) -C $(BUILD)/linux O=$(LINUX_OUT) ARCH=riscv CROSS_COMPILE=$(LINUX_CC) olddefconfig

$(LINUX_OUT)/initramfs.list: $(OUT)/init
	printf 'dir /dev 755 0 0\nnod /dev/console 600 0 0 c 5 1\ndir /proc 755 0 0\ndir /sys 755 0 0\nfile /init %s 755 0 0\n' \
	  $(abspath $(OUT)/init) > $@

$(OUT)/Image: $(LINUX_OUT)/.config $(LINUX_OUT)/initramfs.list
	$(MAKE) -C $(BUILD)/linux O=$(LINUX_OUT) ARCH=riscv CROSS_COMPILE=$(LINUX_CC) -j$(J) Image
	cp $(LINUX_OUT)/arch/riscv/boot/Image $@

run: all
	../sim/obj_dir/Vfk_soc --no-tohost --max-cycles 0 \
	  --load $(OUT)/Image@0x80400000 --dtb $(OUT)/fk-soc.dtb@0x87f00000 $(OUT)/fw_jump.elf

clean:
	rm -rf $(OUT) $(BUILD)/linux-out $(BUILD)/opensbi-out

.PHONY: all run clean
