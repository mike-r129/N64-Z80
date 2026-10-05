// ZEXDOC/ZEXALL/prelim CP/M harness.
#ifndef ZEX_H
#define ZEX_H

#include "zcore.h"

typedef struct {
  int ok, err;          // "OK" / "ERROR" result lines
  int complete;         // "... complete" lines (the end of prelim and of the exercisers)
  uint64_t steps;       // instructions (z80_step mode) or z80_run return values summed
  uint64_t cycles;      // Z80 cycles, folded to 64 bits
  uint64_t ticks;       // host COP0 Count ticks (N64 only)
} zex_result;

// Number of test groups in a ZEXDOC/ZEXALL image (0 if it has no test table,
// like prelim.com), and the descriptive name of group g.
int zex_groups(const uint8_t* img, size_t len);
const char* zex_group_name(const uint8_t* img, size_t len, int g);

// Runs the CP/M program `img` on `core` until it warm-boots. group >= 0 runs
// that test group alone (the test table is patched); -1 runs everything.
// use_run drives the core through z80_run instead of z80_step. quiet prints
// only the program's ERROR lines instead of all of its console text.
zex_result zex_run(const zcore* core, const uint8_t* img, size_t len,
                   int group, int use_run, int quiet);

#endif
