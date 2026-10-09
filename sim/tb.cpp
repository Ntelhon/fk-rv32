// fk-core Verilator testbench
//
//   Vfk_soc [options] [program.elf]
//     --max-cycles N       stop after N cycles (default 10M, 0 = unlimited)
//     --load FILE@ADDR     load raw binary at physical address
//     --dtb FILE@ADDR      load device tree blob and pass its address in a1
//     --entry ADDR         jump target for the boot ROM (default: ELF entry or 0x80000000)
//     --no-tohost          ignore the ELF's tohost symbol
//     +trace_commit        print every committed instruction / trap
//
// UART: output goes to stdout, stdin feeds the UART receiver. When stdin is a
// terminal it is switched to raw mode (keys go straight to the guest, Ctrl-C
// included); press Ctrl-A x to quit, Ctrl-A Ctrl-A to send a literal Ctrl-A.
//
// Exit status: 0 on tohost == 1 (pass) or Ctrl-A x, 1 on test failure / timeout.

#include "Vfk_soc.h"
#include "Vfk_soc__Dpi.h"
#include "verilated.h"
#include "svdpi.h"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <elf.h>
#include <fcntl.h>
#include <string>
#include <csignal>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>
#include <vector>

static bool     g_done      = false;
static uint32_t g_tohost    = 0;
static bool     g_stdin_ok  = true;
static bool     g_quit      = false;   // Ctrl-A x
static bool     g_raw       = false;   // stdin terminal switched to raw mode
static bool     g_escape    = false;   // Ctrl-A seen
static struct termios g_saved_tio;

static void term_restore() {
  if (g_raw) {
    tcsetattr(0, TCSANOW, &g_saved_tio);
    g_raw = false;
  }
}

static void term_signal(int sig) {
  term_restore();
  signal(sig, SIG_DFL);
  raise(sig);
}

// Put an interactive stdin into raw mode so every key reaches the guest UART.
static void term_setup() {
  if (!isatty(0) || tcgetattr(0, &g_saved_tio) != 0) return;
  struct termios raw = g_saved_tio;
  raw.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
  raw.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
  raw.c_cflag |= CS8;
  raw.c_cc[VMIN]  = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(0, TCSANOW, &raw) != 0) return;
  g_raw = true;
  atexit(term_restore);
  signal(SIGTERM, term_signal);
  signal(SIGHUP, term_signal);
  signal(SIGQUIT, term_signal);
  fprintf(stderr, "[sim] interactive console: press Ctrl-A x to quit\r\n");
}

extern "C" void sim_tohost(unsigned int value) {
  g_done   = true;
  g_tohost = value;
}

extern "C" void uart_tx(unsigned char c) {
  fputc(c, stdout);
  fflush(stdout);
}

extern "C" int uart_rx() {
  if (!g_stdin_ok) return -1;
  fd_set fds;
  FD_ZERO(&fds);
  FD_SET(0, &fds);
  struct timeval tv = {0, 0};
  if (select(1, &fds, nullptr, nullptr, &tv) <= 0) return -1;
  unsigned char c;
  ssize_t n = read(0, &c, 1);
  if (n <= 0) { g_stdin_ok = false; return -1; }
  if (g_raw) {
    if (g_escape) {
      g_escape = false;
      if (c == 'x' || c == 'X') { g_quit = true; return -1; }
      if (c == 0x01) return 0x01;
      return c;                    // unknown escape: pass the key through
    }
    if (c == 0x01) { g_escape = true; return -1; }
  }
  return c;
}

static void mem_write_bytes(uint32_t addr, const uint8_t* data, size_t len) {
  size_t i = 0;
  while (i < len) {
    uint32_t a    = addr + i;
    uint32_t base = a & ~3u;
    uint32_t w    = soc_mem_read(base);
    for (uint32_t b = a & 3; b < 4 && i < len; b++, i++) {
      w &= ~(0xFFu << (8 * b));
      w |= uint32_t(data[i]) << (8 * b);
    }
    soc_mem_write(base, w);
  }
}

static std::vector<uint8_t> read_file(const std::string& path) {
  FILE* f = fopen(path.c_str(), "rb");
  if (!f) { fprintf(stderr, "cannot open %s: %s\n", path.c_str(), strerror(errno)); exit(2); }
  std::vector<uint8_t> buf;
  fseek(f, 0, SEEK_END);
  buf.resize(ftell(f));
  fseek(f, 0, SEEK_SET);
  if (!buf.empty() && fread(buf.data(), 1, buf.size(), f) != buf.size()) { fprintf(stderr, "read error\n"); exit(2); }
  fclose(f);
  return buf;
}

// Load an ELF32 image; returns entry point. Sets *tohost if the symbol exists.
static uint32_t load_elf(const std::string& path, uint32_t* tohost) {
  std::vector<uint8_t> img = read_file(path);
  if (img.size() < sizeof(Elf32_Ehdr) || memcmp(img.data(), ELFMAG, SELFMAG) != 0) {
    fprintf(stderr, "%s: not an ELF file\n", path.c_str()); exit(2);
  }
  auto* eh = reinterpret_cast<const Elf32_Ehdr*>(img.data());
  if (eh->e_ident[EI_CLASS] != ELFCLASS32) { fprintf(stderr, "%s: not ELF32\n", path.c_str()); exit(2); }

  for (int i = 0; i < eh->e_phnum; i++) {
    auto* ph = reinterpret_cast<const Elf32_Phdr*>(img.data() + eh->e_phoff + i * eh->e_phentsize);
    if (ph->p_type != PT_LOAD || ph->p_memsz == 0) continue;
    std::vector<uint8_t> seg(ph->p_memsz, 0);
    memcpy(seg.data(), img.data() + ph->p_offset, ph->p_filesz);
    mem_write_bytes(ph->p_paddr, seg.data(), seg.size());
  }

  *tohost = 0;
  for (int i = 0; i < eh->e_shnum; i++) {
    auto* sh = reinterpret_cast<const Elf32_Shdr*>(img.data() + eh->e_shoff + i * eh->e_shentsize);
    if (sh->sh_type != SHT_SYMTAB) continue;
    auto* strtab = reinterpret_cast<const Elf32_Shdr*>(img.data() + eh->e_shoff + sh->sh_link * eh->e_shentsize);
    const char* names = reinterpret_cast<const char*>(img.data() + strtab->sh_offset);
    for (size_t j = 0; j < sh->sh_size / sizeof(Elf32_Sym); j++) {
      auto* sym = reinterpret_cast<const Elf32_Sym*>(img.data() + sh->sh_offset + j * sizeof(Elf32_Sym));
      if (strcmp(names + sym->st_name, "tohost") == 0) *tohost = sym->st_value;
    }
  }
  return eh->e_entry;
}

static bool parse_file_at(const char* arg, std::string* file, uint32_t* addr) {
  const char* at = strrchr(arg, '@');
  if (!at) return false;
  *file = std::string(arg, at - arg);
  *addr = strtoul(at + 1, nullptr, 0);
  return true;
}

int main(int argc, char** argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(argc, argv);
  auto top = std::make_unique<Vfk_soc>(ctx.get());

  uint64_t    max_cycles = 10000000;
  std::string elf;
  uint32_t    entry = 0x80000000, dtb_addr = 0;
  bool        entry_set = false, use_tohost = true;
  std::vector<std::pair<std::string, uint32_t>> loads;

  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--max-cycles" && i + 1 < argc)      max_cycles = strtoull(argv[++i], nullptr, 0);
    else if (a == "--entry" && i + 1 < argc)      { entry = strtoul(argv[++i], nullptr, 0); entry_set = true; }
    else if (a == "--no-tohost")                  use_tohost = false;
    else if ((a == "--load" || a == "--dtb") && i + 1 < argc) {
      std::string f; uint32_t ad;
      if (!parse_file_at(argv[++i], &f, &ad)) { fprintf(stderr, "bad %s argument\n", a.c_str()); return 2; }
      loads.push_back({f, ad});
      if (a == "--dtb") dtb_addr = ad;
    }
    else if (a[0] == '+') continue;               // verilator plusargs
    else if (a[0] == '-') { fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
    else elf = a;
  }

  svSetScope(svGetScopeFromName("TOP.fk_soc"));

  // Reset first so that memory initialisation is not disturbed
  top->clk = 0;
  top->rst_n = 0;
  top->eval();

  uint32_t tohost = 0;
  if (!elf.empty()) {
    uint32_t e = load_elf(elf, &tohost);
    if (!entry_set) entry = e;
  }
  for (auto& l : loads) {
    std::vector<uint8_t> d = read_file(l.first);
    mem_write_bytes(l.second, d.data(), d.size());
  }
  if (use_tohost && tohost) soc_set_tohost(tohost);

  // Boot ROM at 0x1000: a0 = mhartid, a1 = dtb, jump to entry
  const uint32_t rom[] = {
    0x00000297,  // auipc t0, 0
    0x0202a583,  // lw    a1, 32(t0)
    0xf1402573,  // csrr  a0, mhartid
    0x0182a283,  // lw    t0, 24(t0)
    0x00028067,  // jr    t0
    0x00000000,
    entry,       // +24
    0x00000000,
    dtb_addr,    // +32
  };
  for (size_t i = 0; i < sizeof(rom) / 4; i++) soc_mem_write(0x1000 + 4 * i, rom[i]);

  uint64_t cycle = 0;
  for (int i = 0; i < 5; i++) {
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
  }
  top->rst_n = 1;
  term_setup();

  while (!ctx->gotFinish() && !g_done && !g_quit && (max_cycles == 0 || cycle < max_cycles)) {
    top->clk = 1; top->eval();
    top->clk = 0; top->eval();
    cycle++;
  }

  top->final();
  term_restore();

  if (g_quit) {
    fprintf(stderr, "\n[sim] quit by user after %lu cycles\n", (unsigned long)cycle);
    return 0;
  }

  if (g_done) {
    if (g_tohost == 1) {
      fprintf(stderr, "PASS (%lu cycles)\n", (unsigned long)cycle);
      return 0;
    }
    fprintf(stderr, "FAIL: tohost=0x%x (test %u) after %lu cycles\n", g_tohost, g_tohost >> 1, (unsigned long)cycle);
    return 1;
  }
  fprintf(stderr, "TIMEOUT after %lu cycles\n", (unsigned long)cycle);
  return 1;
}
