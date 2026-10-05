// N64 benchmarks (COP0 Count).
#ifndef BENCH_H
#define BENCH_H

#include "zcore.h"

// Synthetic Z80 loops on `core`, in us/instruction.
void bench_core(const zcore* core);

// Cost of copying a Neo Geo bank window (2/4/8/16 KB) into a flat 64 KB
// image, cold and warm dcache: the per-switch price of PLAN.md §4.2 option A.
void bench_window_copy(void);

#endif
