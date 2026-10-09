// Reset entry: set up a stack and jump to main.
  .section .text.start
  .globl _start
_start:
  la   sp, _stack_top
  call main
1:
  j    1b
