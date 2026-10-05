// ZEXDOC/ZEXALL CP/M harness for the mvs64 Z80 core (after superzazu's
// z80_tests.c). -DUSE_RUN drives the core through z80_run instead of
// z80_step. usage: zextest <file.com|.cim> <expected cycles>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "z80.h"

static uint8_t memory[0x10000];
static uintptr_t map[256];
static int done;

static uint8_t rb(void* ud, uint16_t addr) { (void)ud; return memory[addr]; }
static void wb(void* ud, uint16_t addr, uint8_t val) {
  (void)ud; memory[addr] = val;
#ifdef USE_RUN
  z80_hot.cpu.wrote = 1;
#endif
}
static uint8_t in(z80* z, uint16_t port) {
  (void)port;
  if (z->c == 2) putchar(z->e);
  else if (z->c == 9) {
    uint16_t addr = (z->d << 8) | z->e;
    do putchar(memory[addr++]); while (memory[addr] != '$');
  }
  fflush(stdout);
  return 0xFF;
}
static void out(z80* z, uint16_t port, uint8_t val) { (void)z; (void)port; (void)val; done = 1; }

int main(int argc, char** argv) {
  z80* z = &z80_hot.cpu;
  z80_init(z);
  for (int i = 0; i < 256; i++) map[i] = (uintptr_t)memory;
  z->rmap = map; z->read_byte = rb; z->write_byte = wb; z->port_in = in; z->port_out = out;
  FILE* f = fopen(argv[1], "rb");
  if (!f) return 2;
  fread(&memory[0x100], 1, 0x10000 - 0x100, f); fclose(f);
  memory[0] = 0xD3; memory[1] = 0x00;                       // out (0),a: stop
  memory[5] = 0xDB; memory[6] = 0x00; memory[7] = 0xC9;     // in a,(0); ret: BDOS
  z->pc = 0x100;
  unsigned long n = 0;
  while (!done) {
#ifdef USE_RUN
    uint16_t pc0;
    n += z80_run(z, z->cyc + 100000, &pc0);
#else
    z80_step(z); n++;
#endif
  }
  unsigned long exp = strtoul(argv[2], 0, 10);
  printf("\n*** %lu instructions, %lu cycles (expected %lu)\n", n, z->cyc, exp);
  return z->cyc != exp;
}
