// Core-neutral interface shared by the test harnesses (differential test,
// ZEX, bench) and the per-core wrappers (zcore.c).
//
// Every core under test is linked into the same binary: the reference C core
// (REF), its unmodified copy (NEW: a harness self-check), the asm core (ASM,
// N64 only) and the planted-bug mutants (MUT1..). zcore.c is compiled once
// per core with -DPFX=<name>; it renames the core's public symbols to
// <PFX>_* and exports one `zcore` descriptor, <PFX>_core.
#ifndef ZCORE_H
#define ZCORE_H

#include <stdint.h>
#include <stddef.h>
#include "z80.h"

// Neutral CPU state: the harness builds and compares these, the wrapper maps
// them onto the core's struct.
typedef struct {
  uint16_t pc, sp, ix, iy, mem_ptr;
  uint8_t a, f, b, c, d, e, h, l, a_, f_, b_, c_, d_, e_, h_, l_, i, r;
  uint8_t iff_delay, im, int_data, iff1, iff2, halted, int_pending, nmi_pending;
  uint8_t irq_line, wrote, wrote_any;
  uint32_t cyc, irq_redeliver;
} St;

// One bus event: kind 1 = memory write, 2 = OUT, 3 = IN.
typedef struct {
  uint8_t kind, val;
  uint16_t addr;
  uint32_t cyc;
} Ev;

#define ZD_EV_MAX 128

// The pages the differential test's direct-write mode treats as direct
// (stored by a core's write page map instead of write_byte).
static inline int zd_direct_page(unsigned p) { return p >= 0xF8 || (p >= 0x40 && p < 0x60); }

// One differential case for one core: the state goes in and comes back out,
// `mem` is that core's private 64 KB image.
typedef struct {
  St st;
  uint8_t* mem;             // reads come from here, writes land here
  Ev ev[ZD_EV_MAX];         // the first ZD_EV_MAX events
  int nev;                  // events seen (may exceed ZD_EV_MAX)
  int nin;                  // IN calls; feeds the fake port value
  uint8_t dirty[256];       // pages written through the callback
  unsigned nsteps;
  uint16_t last_pc;
  int direct;               // direct-write mode (zdiff_cfg.direct)
  int split;                // split mapping (zdiff_cfg.split): odd pages read from alt
  uint8_t* alt;             // mirror of mem, kept equal by the harness and write_byte
} Run;

typedef struct {
  const char* name;
  z80* cpu;                                             // the core's CPU struct
  void (*init)(z80*);
  void (*step)(z80*);
  unsigned (*run)(z80*, unsigned long until, uint16_t* last_pc);
  void (*gen_int)(z80*, uint8_t data);
  void (*gen_nmi)(z80*);
  // Differential test: load r->st, z80_run(until) once, store r->st.
  void (*diff_run)(Run* r, uint32_t until);
  // Cores with a write page map (the asm core): pages with a nonzero entry
  // are stored directly, without write_byte. NULL for the C cores.
  void (*set_wmap)(const uintptr_t* wmap);
} zcore;

extern const zcore REF_core, NEW_core, ASM_core;
extern const zcore MUT1_core, MUT2_core, MUT3_core, MUT4_core;

#endif
