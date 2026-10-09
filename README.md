# fk-rv32

5-stage in-order **RV32IMA_Zicsr_Zifencei** core with **Sv32** virtual memory and
**M/S/U** privilege modes, written in SystemVerilog, plus a small simulation SoC.

- Passes the riscv-tests ISA suite: **139/139** (`rv32{ui,um,ua,mi,si}-p-*`, `rv32{ui,um,ua}-v-*`)
- Boots **Linux 6.6** on **OpenSBI 1.5.1** in Verilator: OpenSBI → kernel → userspace `/init` → power-off

```
$ cd sim && make && make test
...
passed: 139  failed: 0
$ cd ../sw && make && make run
...
*** fk-core userspace: hello from /init ***
uname: Linux 6.6.0+ riscv32
parent: child 15 exited, page=1234 (COW ok)
[    5.422869] reboot: Power down
PASS (70961074 cycles)
```

## Repository layout

| Path | Contents |
|------|----------|
| `rtl/core/` | the core: pipeline (`fk_core.sv`), decoder, ALU, divider, CSRs, TLB, page-table walker, I$/D$, AXI arbiter |
| `rtl/soc/`  | simulation SoC: AXI→register bridge, boot ROM/RAM, CLINT, PLIC, 16550 UART, test finisher (`fk_soc.sv`) |
| `sim/`      | Verilator testbench (`tb.cpp`), Makefile, riscv-tests runner |
| `sw/`       | device tree, Linux config fragment, freestanding `/init`, bare-metal `hello/`, Buildroot config (`buildroot/`), Makefile |
| `scripts/`  | `check-deps.sh` (requirements check), `fetch-src.sh` (pinned source fetch) |
| `build/`    | everything fetched or generated (created on demand, git-ignored) |

## Microarchitecture

| Stage | Work |
|-------|------|
| IF  | PC, ITLB lookup, I$ lookup (combinational hit), static not-taken |
| ID  | decode, register read with WB bypass |
| EX  | ALU, 1-cycle 32×32 multiplier, 33-cycle radix-2 divider (stalls EX), branch/jump resolve (2-cycle taken penalty) |
| MEM | DTLB + D$ access, AMO/LR/SC, CSRs, traps & interrupts, xRET, `sfence.vma`, `fence.i` — the commit point |
| WB  | register write |

- Full forwarding from MEM and WB into EX (including load data), so there is no load-use stall.
- Precise traps: every exception is carried to MEM and taken there; interrupts are taken on the
  instruction in MEM before it has side effects. CSR writes, xRET, `sfence.vma` and `fence.i` flush
  and refetch.
- **MMU**: 16-entry fully associative ITLB and DTLB (4 KiB + 4 MiB pages), one shared hardware
  page-table walker. The walker **updates A/D in hardware** through the D-cache (atomic: the D$
  is locked for the whole walk). `satp.ASID` is hardwired to 0, and `sfence.vma` flushes everything.
- **Caches**: 8 KiB direct-mapped I$ and D$, 32 B lines, physically indexed and tagged. The D$ is
  write-through and no-write-allocate; AMOs run inside the D$; MMIO is uncached with narrow AXI
  transfers.
- **Bus**: a single AXI4 master (I$ and D$ go through a serializing arbiter, one transaction in flight).
- **Privileged spec**: M/S/U, `medeleg`/`mideleg`, MPRV/SUM/MXR/TVM/TW/TSR, vectored `mtvec`/`stvec`,
  `cycle/time/instret` with `mcounteren`/`scounteren`. PMP is hardwired to 0 entries; Sdtrig has
  0 triggers.
- Misaligned loads and stores trap; OpenSBI emulates them.

### SoC (`rtl/soc`, simulation)

| Address | Device |
|---------|--------|
| `0x0000_1000` | boot ROM (sets a0 = hartid, a1 = DTB, jumps to entry) |
| `0x0010_0000` | test finisher: write 0x5555 = pass/power-off, 0x7777 = reset, 0x3333 = fail (`syscon-poweroff`/`syscon-reboot` in the DT) |
| `0x0200_0000` | CLINT |
| `0x0C00_0000` | PLIC (2 contexts: M, S; UART = source 10) |
| `0x1000_0000` | NS16550A UART |
| `0x8000_0000` | 128 MiB RAM |

## Usage

### Requirements

All tools are found through `PATH`. Run `scripts/check-deps.sh` to check them.

| Tool | Needed for | Tested with |
|------|------------|-------------|
| Verilator ≥ 5.0, C++ compiler, make | simulator (`sim/`) | Verilator 5.022, g++ 13.2 |
| `riscv64-unknown-elf-gcc` | riscv-tests, `/init` | GCC 13.2, binutils 2.42 |
| `riscv64-unknown-linux-gnu-gcc` | Linux kernel, OpenSBI | GCC 13.2, binutils 2.42 |
| `dtc` | device tree | 1.7.2 |
| git, flex, bison, bc, perl | fetching sources, kernel build | |
| Buildroot host tools: wget, rsync, cpio, unzip, file, patch, python3, a host gcc/g++ | `make shell` only (Buildroot builds its own rv32 toolchain) | Ubuntu 24.04, gcc 13.3 |

Notes:
- `make test` only needs the simulator tools, the bare-metal gcc and git. The Linux toolchain, `dtc`
  and the kernel host tools are only for `sw/`.
- rv32 multilibs are **not** needed: everything rv32 is built `-nostdlib` with `-march=rv32… -mabi=ilp32`,
  so a stock riscv64 toolchain works.
- OpenSBI 1.5 is linked as a PIE. Bare-metal (`-elf`) linkers usually can't do that, which is why
  OpenSBI is built with the Linux toolchain by default.
- If your tools have other names or locations, override them: `VERILATOR=`, `RISCV_PREFIX=` (sim);
  `ELF_PREFIX=`, `LINUX_PREFIX=`, `OPENSBI_PREFIX=`, `DTC=` (sw). For example, with the Debian/Ubuntu
  cross packages (untested): `make LINUX_PREFIX=riscv64-linux-gnu-`.
- Builds need network access the first time, to fetch riscv-tests, OpenSBI and Linux (the shallow
  Linux v6.6 fetch is the largest, a few hundred MB).

### Build and run

```sh
cd sim
make                 # build obj_dir/Vfk_soc
make test            # fetch + build riscv-tests (pinned), run them: 139/139 pass

cd ../sw
make                 # fetch OpenSBI v1.5.1 + Linux v6.6, build fw_jump.bin, Image (with initramfs), DTB
make run             # boot Linux (~75M cycles, ~50 s); exits when Linux powers off
make run-hello       # bare-metal hello world (no OpenSBI/Linux, 593 cycles)
make shell           # interactive Linux login on the console (~2.5 min to the prompt, see below)
```

Everything that is fetched or generated goes into the top-level `build/` directory (ignored by git).
Sources are shallow-fetched at pinned versions by `scripts/fetch-src.sh`. To reuse what you already
have, point at it instead:

- `RISCV_TESTS_DIR=/path/to/riscv-tests/isa make test`: a prebuilt rv32 suite.
- `OPENSBI_SRC=/path/to/opensbi LINUX_SRC=/path/to/linux make`: existing source trees. The Linux tree
  must be clean, because it's built out of tree with `O=`.

The test runner skips `rv32ui-p-ma_data` (needs hardware misaligned access) and `rv32mi-p-pmpaddr`
(needs at least one PMP entry). Everything else passes.

### Interactive Linux shell

`make shell` boots the same kernel with a Buildroot root filesystem (busybox + musl) as an initrd
and gives you a login prompt on the simulated UART, in your terminal:

```
Welcome to fk-rv32 (RV32IMA, Sv32) - log in as root, no password
fk-rv32 login: root
# uname -a
Linux fk-rv32 6.6.0+ #1 Thu Oct  8 16:30:35 +03 2026 riscv32 GNU/Linux
# cat /proc/cpuinfo
processor	: 0
hart		: 0
isa		: rv32ima_zicntr_zicsr_zifencei
mmu		: sv32
```

- Log in as `root` with no password. Busybox provides the usual commands (`ls`, `cat`, `ps`, `top`,
  `vi`, `free`, `dmesg`, …).
- Press **Ctrl-A x** to quit the simulator. Ctrl-C goes to Linux; Ctrl-A Ctrl-A sends a literal Ctrl-A.
- The first `make shell` fetches Buildroot and builds an rv32ima/ilp32 musl toolchain and the rootfs
  (about 15 min on a 40-core machine, longer on smaller ones; about 6 GB in `build/`). Later runs reuse
  it. `make rootfs` builds it without booting.
- It's an RTL simulation running at about 1.6M cycles per second, so it takes about 2.5 minutes to reach the login
  prompt, and each command takes a few seconds.
- Buildroot is configured by `sw/buildroot/fk_rv32_defconfig`. If another toolchain in your `PATH`
  confuses Buildroot's host build, run `make shell BR_PATH=/usr/bin:/bin`.

Simulator (`sim/obj_dir/Vfk_soc [options] [program.elf]`) options:

| Option | Meaning |
|--------|---------|
| `--max-cycles N` | stop after N cycles (default 10M, 0 = unlimited) |
| `--load FILE@ADDR` | load a raw binary at a physical address (repeatable) |
| `--dtb FILE@ADDR` | load a DTB and pass its address in `a1` |
| `--entry ADDR` | where the boot ROM jumps (default: ELF entry, else `0x80000000`) |
| `--no-tohost` | ignore the ELF's `tohost` symbol (riscv-tests pass/fail channel) |
| `+trace_commit` | print every committed instruction and trap |

The simulator exits 0 on pass (`tohost` = 1 or a power-off write) and 1 on failure or timeout. It
prints cycles, instructions retired and IPC at the end. UART output goes to stdout, and stdin is fed
to the UART receiver; when stdin is a terminal it's put in raw mode and Ctrl-A x quits.

## Known limitations / next steps

- Cache and TLB arrays use **combinational reads**. That's fine for Verilator, but FPGA/ASIC needs
  synchronous SRAM reads, which means an extra fetch stage and a MEM-stage tag pipeline.
- Stores are blocking write-through (each one waits for the AXI B response). IPC is about 0.47 on the
  Linux boot. A store buffer and a write-back D$ are the biggest performance wins.
- Single hart, no ASIDs, no PMP entries, no hardware misaligned access, no Sstc.
- No networking or block devices in the kernel config; the root filesystem lives in RAM.

## License

MIT, see [LICENSE](LICENSE). This covers the files in this repository only; the sources fetched into
`build/` (Linux, OpenSBI, Buildroot, riscv-tests) keep their own licenses.
