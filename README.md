# fk-core

5-stage in-order **RV32IMA_Zicsr_Zifencei** core with **Sv32** virtual memory and
**M/S/U** privilege modes, written in SystemVerilog. Passes the riscv-tests ISA
suite and boots Linux 6.6 (OpenSBI → kernel → userspace) in Verilator.

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
| `0x0010_0000` | test finisher (`sifive,test1`) |
| `0x0200_0000` | CLINT |
| `0x0C00_0000` | PLIC (2 contexts: M, S; UART = source 10) |
| `0x1000_0000` | NS16550A UART |
| `0x8000_0000` | 128 MiB RAM |

## Usage

Tools come from a Chipyard conda env (Verilator 5.x, riscv64 elf/linux gcc, dtc). Point the Makefiles at
yours with `CHIPYARD_ENV=/path/to/chipyard/.conda-env`; `sw/Makefile` also takes `FIREMARSHAL=` for the
Linux and OpenSBI sources (or edit the defaults).

```sh
cd sim
make                 # build obj_dir/Vfk_soc
make test            # riscv-tests: rv32{ui,um,ua,mi,si}-p-*, rv32{ui,um,ua}-v-*  -> 134/134 pass

cd ../sw
make                 # OpenSBI fw_jump (rv32), Linux 6.6 tinyconfig + initramfs, DTB
make run             # boot Linux (~66M cycles, ~40 s)
```

Simulator options: `--max-cycles N`, `--load FILE@ADDR`, `--dtb FILE@ADDR`, `--entry ADDR`,
`--no-tohost`, `+trace_commit` (prints every committed instruction and trap).

## Known limitations / next steps

- Cache and TLB arrays use **combinational reads**. That's fine for Verilator, but FPGA/ASIC needs
  synchronous SRAM reads, which means an extra fetch stage and a MEM-stage tag pipeline.
- Stores are blocking write-through (each one waits for the AXI B response). IPC is about 0.47 on the
  Linux boot. A store buffer and a write-back D$ are the biggest performance wins.
- Single hart, no ASIDs, no PMP entries, no hardware misaligned access, no Sstc.
- There is no rv32 libc in the toolchain, so `/init` is a freestanding program using raw syscalls.
  A busybox userspace needs an rv32 glibc or musl toolchain.
