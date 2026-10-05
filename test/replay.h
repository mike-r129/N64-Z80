// Replay of an mvs64 owner trace (MVS64_Z80TRACE, see z80trace.h and
// mvs64 tools/z80trace-format.md) through a core under test.
#ifndef REPLAY_H
#define REPLAY_H

#include "zcore.h"

typedef struct {
  long runs, steps, io;   // RUN records, instructions (RUN + STEP), IN/OUT callbacks
  long bad;               // mismatches
  int ended;              // reached END (0: desync or truncated trace)
  uint64_t ticks;         // host COP0 Count ticks inside z80_run/z80_step (N64 only)
} replay_result;

// Replays `trace` (the whole file in memory) on `core`; prints at most
// `maxprint` mismatches.
replay_result replay(const zcore* core, const uint8_t* trace, size_t len, int maxprint);

#endif
