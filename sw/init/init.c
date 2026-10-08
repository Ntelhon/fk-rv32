// Minimal freestanding /init for fk-core (RV32, raw Linux syscalls, no libc).
// Prints a banner, exercises fork/COW/wait, then powers the machine off.

#define SYS_write   64
#define SYS_exit    93
#define SYS_uname   160
#define SYS_getpid  172
#define SYS_clone   220
#define SYS_waitid  95
#define SYS_reboot  142

static long sc(long n, long a0, long a1, long a2, long a3, long a4) {
  register long r0 asm("a0") = a0;
  register long r1 asm("a1") = a1;
  register long r2 asm("a2") = a2;
  register long r3 asm("a3") = a3;
  register long r4 asm("a4") = a4;
  register long r7 asm("a7") = n;
  asm volatile("ecall" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r7) : "memory");
  return r0;
}

static unsigned slen(const char* s) { unsigned n = 0; while (s[n]) n++; return n; }
static void puts_(const char* s) { sc(SYS_write, 1, (long)s, slen(s), 0, 0); }

static void putu(unsigned v) {
  char buf[12]; int i = 11; buf[i] = 0;
  do { buf[--i] = '0' + v % 10; v /= 10; } while (v);
  puts_(&buf[i]);
}

struct utsname { char f[6][65]; };

static volatile unsigned shared_page[1024];

void _start(void) {
  struct utsname u;
  puts_("\n*** fk-core userspace: hello from /init ***\n");
  if (sc(SYS_uname, (long)&u, 0, 0, 0, 0) == 0) {
    puts_("uname: "); puts_(u.f[0]); puts_(" "); puts_(u.f[2]); puts_(" "); puts_(u.f[4]); puts_("\n");
  }
  puts_("pid: "); putu(sc(SYS_getpid, 0, 0, 0, 0, 0)); puts_("\n");

  // fork (clone with SIGCHLD); child modifies a COW page
  shared_page[0] = 1234;
  long pid = sc(SYS_clone, 17 /* SIGCHLD */, 0, 0, 0, 0);
  if (pid == 0) {
    shared_page[0] = 5678;
    unsigned acc = 0;
    for (unsigned i = 1; i <= 1000; i++) acc += (i * i) % 7 + i / 3;
    puts_("child: pid "); putu(sc(SYS_getpid, 0, 0, 0, 0, 0));
    puts_(", page="); putu(shared_page[0]); puts_(", acc="); putu(acc); puts_("\n");
    sc(SYS_exit, 0, 0, 0, 0, 0);
  }
  char info[128];
  sc(SYS_waitid, 0 /* P_ALL */, 0, (long)info, 4 /* WEXITED */, 0);
  puts_("parent: child "); putu(pid); puts_(" exited, page="); putu(shared_page[0]);
  puts_(shared_page[0] == 1234 ? " (COW ok)\n" : " (COW BROKEN)\n");

  puts_("powering off\n");
  sc(SYS_reboot, 0xfee1dead, 672274793, 0x4321fedc, 0, 0);
  for (;;) ;
}
