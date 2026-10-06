// Differential test: one core against another on random states.
#ifndef ZDIFF_H
#define ZDIFF_H

#include "zcore.h"

typedef struct {
  long cases;
  uint64_t seed;
  // Direct-write mode: memory-write events to the direct pages (0x40-0x5F,
  // 0xF8-0xFF) are dropped from both logs before comparing, because a core
  // with a write page map stores there without calling write_byte.
  int direct;
  // Split mapping: odd pages are read from a mirror copy of the image, so no
  // two neighbouring pages are contiguous in host memory and instructions
  // straddle mapping boundaries; half the cases start near a page end.
  int split;
  int max_report;   // mismatches printed in full
} zdiff_cfg;

// Returns the number of mismatching cases.
long zdiff(const zcore* ref, const zcore* cand, const zdiff_cfg* cfg);

#endif
