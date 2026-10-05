// Z80 CPU core — vendored from superzazu/z80 (https://github.com/superzazu/z80).
// Copyright (c) 2019 Nicolas Allemand. MIT License — see z80.LICENSE.
#ifndef Z80_Z80_H_
#define Z80_Z80_H_

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

typedef struct z80 z80;
struct z80 {
  uint8_t (*read_byte)(void*, uint16_t);
  void (*write_byte)(void*, uint16_t, uint8_t);
  // MVS64: widened port to 16-bit so the full I/O address (high byte = B for
  // IN/OUT (C), or A for IN/OUT (n)) reaches the handler. NeoGeo Z80 bank
  // switching encodes the bank number in the high byte of the port address.
  uint8_t (*port_in)(z80*, uint16_t);
  void (*port_out)(z80*, uint16_t, uint8_t);
  void* userdata;

  unsigned long cyc; // cycle count (t-states)

  uint16_t pc, sp, ix, iy; // special purpose registers
  uint16_t mem_ptr; // "wz" register
  uint8_t a, b, c, d, e, h, l; // main registers
  uint8_t a_, b_, c_, d_, e_, h_, l_, f_; // alternate registers
  uint8_t i, r; // interrupt vector, memory refresh

  // flags in the Z80 F register layout: S Z Y H X P/V N C (bit 7..0); see
  // FLAG_* in z80.c
  uint8_t f;

  uint8_t interrupt_mode;
  uint8_t int_data;
  bool iff1, iff2;
  // Everything that can make z80_run leave its fast path, in one aligned
  // word: an EI delay, a pending INT or NMI, the level IRQ input (see
  // irq_line below) and HALT. `ev_mask` has 0xFF in the lanes that matter
  // right now: INT and the IRQ line only while IFF1 is set (the core keeps
  // it in sync; z80_run also rebuilds it on entry). While events & ev_mask
  // is 0 no interrupt logic can apply, so z80_run tests one word per
  // instruction instead of the full predicates.
  union {
    uint64_t events;
    struct {
      uint8_t iff_delay;
      bool int_pending, nmi_pending;
      uint8_t irq_line;
      bool halted;
    };
  };
  union {
    uint64_t ev_mask;
    struct {
      uint8_t evm_iff_delay, evm_int, evm_nmi, evm_line, evm_halted;
    };
  };
  // MVS64 read page map: byte at addr = *(uint8_t*)(rmap[addr >> 8] + addr).
  // Entries are host pointers pre-biased by the page's Z80 base address, so
  // every memory READ (opcode/operand fetch, data) is a branchless inline
  // table lookup instead of the read_byte callback. The owner keeps it in
  // sync with its memory map (bank switches); read_byte must still be set
  // for owners that call it directly. Writes stay on write_byte.
  const uintptr_t* rmap;

  // MVS64 batch-run support (z80_run). The owner's write/port callbacks set
  // `wrote`; z80_run clears it before each instruction, so after a run it
  // tells whether the LAST instruction wrote, and `wrote_any` whether any
  // instruction of the run did. `irq_line` (in `events` above) is a
  // level-triggered IRQ input: while it is nonzero, z80_run re-asserts the
  // maskable interrupt (with the last int_data) before any instruction where
  // IFF1 is set and none is pending; `irq_redeliver` counts those
  // re-assertions.
  uint8_t wrote, wrote_any;
  unsigned long irq_redeliver;
};

// MVS64: the Z80 per-step working set in one contiguous, 16-byte aligned
// block (~3.9 KB): the owner's CPU struct, the opcode cycle tables, the read
// page map and the 2 KB work RAM (NeoGeo 0xF800-0xFFFF). Contiguous objects
// smaller than the 8 KB direct-mapped dcache cannot evict each other, so no
// relink can make the Z80 loop ping-pong between its own tables.
struct z80_hot {
  z80 cpu;
  uint8_t cyc_00[256], cyc_ed[256], cyc_ddfd[256];
  uint8_t sz53p[256];   // S Z Y X P/V flags of each result byte (z80.c)
  uintptr_t rmap[256];
  uint8_t ram[0x800];
};
extern struct z80_hot z80_hot;

void z80_init(z80* const z);
void z80_step(z80* const z);
void z80_debug_output(z80* const z);
void z80_gen_nmi(z80* const z);
void z80_gen_int(z80* const z, uint8_t data);

// Run instructions until z->cyc reaches `until` (at least one), stopping
// early after any instruction that ends on a loop edge (the new PC is at or
// below that instruction's own address: backward branches, self-jumps,
// repeating block ops, interrupt entry to a lower vector) or leaves the CPU
// halted. Those are the only points where an owner's idle-loop detection has
// anything to look at, so it runs once per batch instead of per instruction.
// Returns the number of instructions executed; *last_pc receives the address
// of the last one. Behaves exactly like calling z80_step() in a loop with the
// irq_line re-assertion (see struct z80) before each step.
unsigned z80_run(z80* const z, unsigned long until, uint16_t* last_pc);

#endif // Z80_Z80_H_
