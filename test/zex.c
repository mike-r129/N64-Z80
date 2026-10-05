// ZEXDOC/ZEXALL CP/M harness (after seed/harness/zextest.c and superzazu's
// z80_tests.c). BDOS is stubbed at 0x0005 with IN A,(0); RET, so the console
// calls (C=2 putchar E, C=9 print the '$'-terminated string at DE) happen in
// port_in, which reads C, D and E from the CPU struct. The warm boot at
// 0x0000 executes OUT (0),A, which ends the run.
#include <string.h>
#include "zex.h"
#include "tlog.h"

#ifdef N64
static uint32_t now32(void) { return TICKS_READ(); }
#else
static uint32_t now32(void) { return 0; }
#endif

static uint8_t memory[0x10000] __attribute__((aligned(16)));
static uintptr_t map[256];
static int done, quiet;
static zex_result* res;
static char line[160];
static int linelen;

static uint16_t rdw(const uint8_t* m, unsigned a) { return m[a] | m[a + 1] << 8; }

// Address of the test table in a ZEXDOC/ZEXALL image loaded at 0x100, or 0.
// The program starts with JP start, and start: is
//   LD HL,(6); LD SP,HL; LD DE,msg1; LD C,9; CALL bdos; LD HL,tests
static unsigned tests_table(const uint8_t* m) {
  if (m[0x100] != 0xC3) return 0;
  unsigned start = rdw(m, 0x101);
  static const uint8_t pro[] = { 0x2A, 0x06, 0x00, 0xF9, 0x11 };
  if (start > 0xFF00 || memcmp(&m[start], pro, sizeof pro) || m[start + 12] != 0x21) return 0;
  return rdw(m, start + 13);
}

static void load(const uint8_t* img, size_t len) {
  memset(memory, 0, sizeof memory);
  if (len > sizeof memory - 0x100) len = sizeof memory - 0x100;
  memcpy(&memory[0x100], img, len);
  memory[0] = 0xD3; memory[1] = 0x00;                       // out (0),a: stop
  memory[5] = 0xDB; memory[6] = 0x00; memory[7] = 0xC9;     // in a,(0); ret: BDOS
}

int zex_groups(const uint8_t* img, size_t len) {
  load(img, len);
  unsigned t = tests_table(memory);
  int n = 0;
  if (t) while (rdw(memory, t + 2 * n)) n++;
  return n;
}

const char* zex_group_name(const uint8_t* img, size_t len, int g) {
  static char name[40];
  load(img, len);
  unsigned t = tests_table(memory);
  if (!t) return "?";
  unsigned d = rdw(memory, t + 2 * g) + 65;   // descriptor: mask, 3 x 20-byte vectors, crc, message
  int i = 0;
  while (i < (int)sizeof name - 1 && memory[(uint16_t)(d + i)] != '$' && memory[(uint16_t)(d + i)] != '.') {
    name[i] = memory[(uint16_t)(d + i)];
    i++;
  }
  name[i] = 0;
  return name;
}

static void flush_line(void) {
  line[linelen] = 0;
  if (strstr(line, "ERROR")) res->err++;
  else if (strstr(line, "OK")) res->ok++;
  if (strstr(line, "complete")) res->complete++;
  if (linelen && (!quiet || strstr(line, "ERROR"))) tlog("%s\n", line);
  linelen = 0;
}

static void con(uint8_t ch) {
  if (ch == '\r') return;
  if (ch == '\n' || linelen == (int)sizeof line - 1) { flush_line(); if (ch == '\n') return; }
  line[linelen++] = ch;
}

static uint8_t rb(void* ud, uint16_t addr) { (void)ud; return memory[addr]; }
static void wb(void* ud, uint16_t addr, uint8_t val) { memory[addr] = val; ((z80*)ud)->wrote = 1; }
static uint8_t in(z80* z, uint16_t port) {
  (void)port;
  if (z->c == 2) con(z->e);
  else if (z->c == 9) {
    uint16_t addr = (z->d << 8) | z->e;
    do con(memory[addr++]); while (memory[addr] != '$');
  }
  return 0xFF;
}
static void out(z80* z, uint16_t port, uint8_t val) { (void)port; (void)val; z->wrote = 1; done = 1; }

zex_result zex_run(const zcore* core, const uint8_t* img, size_t len, int group, int use_run, int q) {
  static zex_result r;
  memset(&r, 0, sizeof r);
  res = &r; quiet = q; done = 0; linelen = 0;
  load(img, len);
  if (group >= 0) {
    unsigned t = tests_table(memory);
    if (!t || group >= zex_groups(img, len)) { tlog("zex: no test group %d\n", group); r.err = 1; return r; }
    load(img, len);
    memory[t] = memory[t + 2 * group]; memory[t + 1] = memory[t + 2 * group + 1];
    memory[t + 2] = memory[t + 3] = 0;
  }
  z80* z = core->cpu;
  core->init(z);
  for (int i = 0; i < 256; i++) map[i] = (uintptr_t)memory;
  z->rmap = map; z->read_byte = rb; z->write_byte = wb; z->port_in = in; z->port_out = out;
  z->userdata = z;
  z->pc = 0x100;
  // Fold the 32-bit cycle counter and COP0 Count every chunk so long runs
  // (the full exercisers are ~46.7G cycles, hours of N64 time) don't wrap.
  unsigned long c0 = z->cyc;
  uint32_t t0 = now32();
  while (!done) {
    if (use_run) {
      uint16_t pc0;
      for (int i = 0; i < 64 && !done; i++) r.steps += core->run(z, z->cyc + 100000, &pc0);
    } else {
      for (int i = 0; i < 65536 && !done; i++) { core->step(z); r.steps++; }
    }
    uint32_t t1 = now32();
    r.cycles += (uint32_t)(z->cyc - c0); c0 = z->cyc;
    r.ticks += (uint32_t)(t1 - t0); t0 = t1;
  }
  if (linelen) flush_line();
  return r;
}
