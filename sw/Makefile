# fk-core software build: OpenSBI (fw_jump), RV32 Linux with initramfs, DTB
#   make            fetch sources (first time) and build everything into ../build/out
#   make run        boot Linux in the Verilator model (build ../sim first)
#   make run-hello  run the bare-metal hello world (no OpenSBI/Linux needed)
#   make shell      boot Linux with a Buildroot/busybox rootfs and an interactive
#                   login on the console (first build takes 30-60 min)
#
# Tools are taken from PATH. Overridable variables:
#   ELF_PREFIX      bare-metal cross prefix   (default riscv64-unknown-elf-)
#   LINUX_PREFIX    Linux cross prefix        (default riscv64-unknown-linux-gnu-)
#   OPENSBI_PREFIX  OpenSBI cross prefix      (default $(LINUX_PREFIX); needs a PIE-capable linker)
#   OPENSBI_SRC     existing OpenSBI tree     (default: fetch $(OPENSBI_REF) into ../build)
#   LINUX_SRC       existing clean Linux tree (default: fetch $(LINUX_REF) into ../build)
#   BUILDROOT_SRC   existing Buildroot tree   (default: fetch $(BUILDROOT_REF) into ../build)
#   BR_PATH         PATH used for the Buildroot build (default: $(PATH)); set it to plain
#                   system directories if other toolchains in PATH confuse Buildroot

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
BUILDROOT_URL ?= https://gitlab.com/buildroot.org/buildroot.git
BUILDROOT_REF ?= 2025.02.18
BUILDROOT_SRC ?= $(BUILD)/buildroot
BR_PATH       ?= $(PATH)

# initrd (Buildroot rootfs) location; must end below the DTB at 0x87f00000
INITRD_ADDR := 0x86000000
INITRD_MAX  := 0x87f00000

OPENSBI_OUT := $(BUILD)/opensbi-out
BUILDROOT_OUT := $(BUILD)/buildroot-out
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

$(BUILD)/buildroot:
	$(FETCH) $(BUILDROOT_URL) $(BUILDROOT_REF) $@

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

# --- bare-metal hello world ---
$(OUT)/hello.elf: hello/start.S hello/hello.c hello/link.ld | $(OUT)
	$(ELF_PREFIX)gcc -march=rv32ima_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib -static \
	  -T hello/link.ld -o $@ hello/start.S hello/hello.c

hello: $(OUT)/hello.elf

shell: $(OUT)/fw_jump.bin $(OUT)/Image $(OUT)/rootfs.cpio $(OUT)/fk-soc-shell.dtb
	$(ROOT)/sim/obj_dir/Vfk_soc --no-tohost --max-cycles 0 --entry 0x80000000 \
	  --load $(OUT)/fw_jump.bin@0x80000000 --load $(OUT)/Image@0x80400000 \
	  --load $(OUT)/rootfs.cpio@$(INITRD_ADDR) --dtb $(OUT)/fk-soc-shell.dtb@0x87f00000

run-hello: $(OUT)/hello.elf
	$(ROOT)/sim/obj_dir/Vfk_soc $<

# --- Buildroot: rv32 musl toolchain + busybox rootfs (for 'make shell') ---
# Buildroot is run as a separate, non-parallel top-level make (it parallelises internally).
BR_MAKE := env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL PATH="$(BR_PATH)" \
           make -C $(BUILDROOT_SRC) O=$(BUILDROOT_OUT) FK_RV32_SW=$(abspath .)

$(BUILDROOT_OUT)/.config: buildroot/fk_rv32_defconfig | $(BUILDROOT_SRC)
	$(BR_MAKE) BR2_DEFCONFIG=$(abspath buildroot/fk_rv32_defconfig) defconfig

$(OUT)/rootfs.cpio: $(BUILDROOT_OUT)/.config buildroot/post-build.sh | $(OUT)
	$(BR_MAKE)
	cp $(BUILDROOT_OUT)/images/rootfs.cpio $@

rootfs: $(OUT)/rootfs.cpio

# DTB that tells the kernel where the initrd is
$(OUT)/fk-soc-shell.dtb: fk-soc.dts $(OUT)/rootfs.cpio
	@size=$$(wc -c < $(OUT)/rootfs.cpio); end=$$(( $(INITRD_ADDR) + size )); \
	if [ $$end -gt $$(( $(INITRD_MAX) )) ]; then \
	  echo "rootfs.cpio ($$size bytes) does not fit below $(INITRD_MAX)"; exit 1; fi; \
	sed "s|bootargs = .*;|& linux,initrd-start = <$(INITRD_ADDR)>; linux,initrd-end = <$$(printf 0x%x $$end)>;|" \
	  fk-soc.dts | $(DTC) -I dts -O dtb -o $@ -

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

.PHONY: all run hello run-hello rootfs shell clean
