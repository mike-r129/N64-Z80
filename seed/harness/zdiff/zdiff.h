// Neutral CPU state shared by the differential harness and both core wrappers.
#include <stdint.h>
#include <stddef.h>
typedef struct {
  uint16_t pc, sp, ix, iy, mem_ptr;
  uint8_t a, f, b, c, d, e, h, l, a_, f_, b_, c_, d_, e_, h_, l_, i, r;
  uint8_t iff_delay, im, int_data, iff1, iff2, halted, int_pending, nmi_pending;
  uint8_t irq_line, wrote, wrote_any;
  uint32_t cyc, irq_redeliver;
} St;
typedef struct {            // one bus event: kind 1 = write, 2 = out, 3 = in
  uint8_t kind, val; uint16_t addr; uint32_t cyc;
} Ev;
typedef struct {
  St st;
  uint8_t* mem;             // 64 KB, reads come from here, writes land here
  Ev ev[64]; int nev, nin;
  unsigned nsteps; uint16_t last_pc;
} Run;
