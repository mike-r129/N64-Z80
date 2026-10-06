// n64z80: an optimized Zilog Z80 core for Nintendo 64 (MIPS assembly).
//
// The CPU struct is the same as mvs64's z80.h (reference/z80.h): same fields,
// same layout (n64z80_offsets.h, static-asserted), so owner code that reads
// and writes the fields directly works unchanged. If reference/z80.h was
// included first, its definition is used; both are checked against the same
// offsets.
//
// Behaviour is bit-exact with reference/z80.c (registers, flags, WZ, R,
// cycle counts, bus accesses and their cycle stamps, z80_run's stop points),
// with one documented difference: the core manages `wrote` / `wrote_any`
// itself (every memory write and every OUT sets them; interrupt-accept
// pushes count), so owner callbacks no longer need to set `wrote`.
#ifndef N64Z80_H
#define N64Z80_H

#include <stdint.h>
#include <stdbool.h>
#include "n64z80_offsets.h"

#ifndef Z80_Z80_H_   // reference/z80.h's guard: one definition of struct z80
#define Z80_Z80_H_
typedef struct z80 z80;
struct z80 {
  uint8_t (*read_byte)(void*, uint16_t);       // only for owners that call it
  void (*write_byte)(void*, uint16_t, uint8_t);
  uint8_t (*port_in)(z80*, uint16_t);          // 16-bit port: high byte = A or B
  void (*port_out)(z80*, uint16_t, uint8_t);
  void* userdata;

  unsigned long cyc;  // cycle count (t-states); wraps, compare with signed distance

  uint16_t pc, sp, ix, iy;
  uint16_t mem_ptr;   // WZ
  uint8_t a, b, c, d, e, h, l;
  uint8_t a_, b_, c_, d_, e_, h_, l_, f_;
  uint8_t i, r;
  uint8_t f;          // S Z Y H X P/V N C (bit 7..0)

  uint8_t interrupt_mode;
  uint8_t int_data;
  bool iff1, iff2;
  // Everything that can end the fast path, one byte each (see reference/z80.h).
  union {
    uint64_t events;
    struct {
      uint8_t iff_delay;
      bool int_pending, nmi_pending;
      uint8_t irq_line;  // level IRQ input: z80_run re-asserts INT while it is set
      bool halted;
    };
  };
  union {
    uint64_t ev_mask;   // maintained by the core
    struct {
      uint8_t evm_iff_delay, evm_int, evm_nmi, evm_line, evm_halted;
    };
  };
  // Read page map: byte at addr = *(uint8_t*)(rmap[addr >> 8] + addr).
  // Owner-managed; may change inside callbacks (bank switches).
  const uintptr_t* rmap;

  uint8_t wrote, wrote_any;     // last / any instruction of the run wrote (or OUT)
  unsigned long irq_redeliver;  // irq_line re-assertions
};
#endif

#if defined(N64)
N64Z80_CHECK_LAYOUT();
#endif

// Same contracts as mvs64's z80_init / z80_step / z80_run / z80_gen_int /
// z80_gen_nmi (PLAN.md §3).
void n64z80_init(z80* z);
void n64z80_step(z80* z);
unsigned n64z80_run(z80* z, unsigned long until, uint16_t* last_pc);
void n64z80_gen_int(z80* z, uint8_t data);
void n64z80_gen_nmi(z80* z);

// Optional write page map, the write-side twin of z->rmap: for a page with a
// nonzero entry, a memory write is stored at *(uint8_t*)(wmap[addr >> 8] +
// addr) instead of calling write_byte (`wrote` still counts it). Use it only
// for pages whose write_byte would do nothing but that store (work RAM).
// NULL (the default) sends every write to write_byte. The core keeps the
// pointer; the owner may change the entries between runs or in callbacks.
void n64z80_set_wmap(const uintptr_t* wmap);

#endif
