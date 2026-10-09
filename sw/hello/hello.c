// Bare-metal "hello world" for fk-rv32: runs in M-mode straight from reset
// (boot ROM -> 0x80000000), prints through the 16550 UART and powers off.
#include <stdint.h>

#define UART_BASE   0x10000000u
#define UART_THR    (*(volatile uint8_t *)(UART_BASE + 0))
#define UART_LSR    (*(volatile uint8_t *)(UART_BASE + 5))
#define LSR_THRE    0x20

#define FINISHER    (*(volatile uint32_t *)0x00100000u)
#define FINISH_PASS 0x5555u

static void uart_putc(char c) {
  while (!(UART_LSR & LSR_THRE)) ;
  UART_THR = (uint8_t)c;
}

static void uart_puts(const char *s) {
  while (*s) {
    if (*s == '\n') uart_putc('\r');
    uart_putc(*s++);
  }
}

void main(void) {
  uart_puts("Hello, world! (from fk-rv32)\n");
  FINISHER = FINISH_PASS;
  for (;;) ;
}
