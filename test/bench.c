// N64 benchmarks. Times are COP0 Count ticks (TICKS_PER_SECOND = 46.875 MHz,
// half the 93.75 MHz CPU clock), reported as ns/instruction and VR4300
// cycles/instruction. The numbers belong to this ROM's code and data layout,
// which is not mvs64's: compare cores within one ROM, not against the game.
#include <libdragon.h>
#include <string.h>
#include "bench.h"
#include "tlog.h"

static uint8_t mem[0x10000] __attribute__((aligned(16)));
static uintptr_t map[256];

static uint8_t rb(void* ud, uint16_t addr) { (void)ud; return mem[addr]; }
static void wb(void* ud, uint16_t addr, uint8_t val) { mem[addr] = val; ((z80*)ud)->wrote = 1; }
static uint8_t in(z80* z, uint16_t port) { (void)z; (void)port; return 0xFF; }
static void out(z80* z, uint16_t port, uint8_t val) { (void)port; (void)val; z->wrote = 1; }

static z80* setup(const zcore* core, const uint8_t* prog, size_t len) {
  z80* z = core->cpu;
  core->init(z);
  memset(mem, 0, sizeof mem);
  memcpy(mem, prog, len);
  for (int i = 0; i < 256; i++) map[i] = (uintptr_t)mem;
  z->rmap = map; z->read_byte = rb; z->write_byte = wb; z->port_in = in; z->port_out = out;
  z->userdata = z;
  z->pc = 0;
  return z;
}

static void report(const char* core, const char* what, unsigned long n, uint32_t ticks) {
  unsigned long ns = (unsigned long)((uint64_t)ticks * 1000000000ull / TICKS_PER_SECOND / n);
  unsigned long cyc10 = (unsigned long)((uint64_t)ticks * 20 / n);   // CPU cycles x10
  tlog("[BENCH] %s %-28s %5lu ns/instr  %4lu.%lu cycles/instr  (%lu instr)\n",
       core, what, ns, cyc10 / 10, cyc10 % 10, n);
}

#define BENCH_N 400000

void bench_core(const zcore* core) {
  // The seed's in-cache table scan: LD HL,0; loop: LD A,(HL); AND A; INC HL; JR loop
  static const uint8_t scan[] = { 0x21, 0x00, 0x00, 0x7E, 0xA7, 0x23, 0x18, 0xFB };
  // Writes through write_byte: LD HL,F800; LD B,0; loop: LD (HL),A; INC L; DJNZ loop; JR 0
  static const uint8_t fill[] = { 0x21, 0x00, 0xF8, 0x06, 0x00, 0x77, 0x2C, 0x10, 0xFC, 0x18, 0xF5 };
  uint16_t pc0;
  unsigned long n;
  uint32_t t0;

  // As mvs64 drives it: until = far ahead, so each z80_run call ends at the
  // next loop edge (here every 4 instructions) and returns to the owner.
  z80* z = setup(core, scan, sizeof scan);
  n = 0; t0 = TICKS_READ();
  while (n < BENCH_N) n += core->run(z, z->cyc + 0x10000000, &pc0);
  report(core->name, "scan loop, z80_run batches", n, TICKS_SINCE(t0));

  z = setup(core, scan, sizeof scan);
  t0 = TICKS_READ();
  for (n = 0; n < BENCH_N; n++) core->step(z);
  report(core->name, "scan loop, z80_step", n, TICKS_SINCE(t0));

  z = setup(core, fill, sizeof fill);
  n = 0; t0 = TICKS_READ();
  while (n < BENCH_N) n += core->run(z, z->cyc + 0x10000000, &pc0);
  report(core->name, "fill loop, z80_run batches", n, TICKS_SINCE(t0));
}

static uint8_t rom[0x40000] __attribute__((aligned(16)));   // stands in for M_ROM

void bench_window_copy(void) {
  static const unsigned size[] = { 0x800, 0x1000, 0x2000, 0x4000 };
  uint8_t* img = mem;
  for (int i = 0; i < (int)sizeof rom; i++) rom[i] = (uint8_t)(i * 13 + 7);
  for (int s = 0; s < 4; s++) {
    unsigned sz = size[s];
    uint32_t cold = 0, warm = 0;
    const int trials = 8;
    for (int t = 0; t < trials; t++) {
      uint8_t* src = rom + ((t * 5 + 3) * sz) % (sizeof rom - sz);
      uint8_t* dst = img + 0x10000 - 0x4000;   // a window slot (bank 0 sits at 0x8000)
      data_cache_hit_writeback_invalidate(src, sz);
      data_cache_hit_writeback_invalidate(dst, 0x4000);
      uint32_t t0 = TICKS_READ();
      memcpy(dst, src, sz);
      uint32_t t1 = TICKS_READ();
      memcpy(dst, src, sz);
      uint32_t t2 = TICKS_READ();
      cold += TICKS_DISTANCE(t0, t1);
      warm += TICKS_DISTANCE(t1, t2);
    }
    tlog("[BENCH] window copy %2u KB: cold %4lu us, warm %4lu us  (mean of %d)\n", sz >> 10,
         (unsigned long)TICKS_TO_US(cold / trials), (unsigned long)TICKS_TO_US(warm / trials), trials);
  }
}
