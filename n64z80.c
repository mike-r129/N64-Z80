// C side of the n64z80 core: init and the interrupt request entry points,
// and in a debug build (N64Z80_C_FALLBACK=1) the C fallback that
// n64z80_asm.S can send table entries without an asm handler to.
//
// The fallback is the reference core itself: build/n64z80_ref.c is
// reference/z80.c with its write_byte / port_out call sites rewritten to the
// hooks below (Makefile), compiled here with its public symbols renamed.
// The hooks give the core its own `wrote` tracking (n64z80.h).
#ifndef N64Z80_C_FALLBACK
#define N64Z80_C_FALLBACK 0
#endif

#if N64Z80_C_FALLBACK
#include <stdio.h>

// The reference reports undefined opcodes on stderr; random code and the
// exercisers hit them constantly, and the report changes no state.
#define fprintf(...) ((void)0)

#define z80_hot          n64z80_ref_hot
#define z80_init         n64z80_ref_init
#define z80_step         n64z80_ref_step
#define z80_run          n64z80_ref_run
#define z80_gen_int      n64z80_ref_gen_int
#define z80_gen_nmi      n64z80_ref_gen_nmi
#define z80_debug_output n64z80_ref_debug_output
#include "z80.h"
#include "n64z80.h"   // checks the reference struct against n64z80_offsets.h

// Owned by n64z80_asm.S: the 1-based number of the instruction being
// executed in the current n64z80_run, and of the last one that wrote.
extern uint32_t n64z80_insn, n64z80_lastw;
// Fallback entries whose host fetch pointer disagreed with the rmap (a
// mapping bug in the asm; the testsuite requires 0).
uint32_t n64z80_fetch_mismatch;

static void n64z80_c_wb(z80* z, uint16_t addr, uint8_t val) {
  z->wrote = 1;
  n64z80_lastw = n64z80_insn;
  z->write_byte(z->userdata, addr, val);
}

static void n64z80_c_out(z80* z, uint16_t port, uint8_t val) {
  z->wrote = 1;
  n64z80_lastw = n64z80_insn;
  z->port_out(z, port, val);
}

// The reference's only N64 code is mvs64's dcache anchor in z80_init.
#pragma push_macro("N64")
#undef N64
#include "n64z80_ref.c"
#pragma pop_macro("N64")

// One instruction at z->pc, exactly the reference z80_run loop body (fetch,
// exec_main); interrupts, HALT and the stop test are the asm's. The struct
// is fully written back; `host` is the asm's fetch pointer for z->pc.
void n64z80_c_exec(z80* z, const uint8_t* host) {
  if (*host != rb(z, z->pc)) n64z80_fetch_mismatch++;
  exec_opcode(z, nextb(z));
}

#endif  // N64Z80_C_FALLBACK

#include <stddef.h>
#include "n64z80.h"

// The reference's z80_init, field by field (the testsuite compares them).
void n64z80_init(z80* z) {
  z->read_byte = NULL;
  z->rmap = NULL;
  z->write_byte = NULL;
  z->port_in = NULL;
  z->port_out = NULL;
  z->userdata = NULL;
  z->cyc = 0;
  z->pc = 0;
  z->sp = 0xFFFF;
  z->ix = 0;
  z->iy = 0;
  z->mem_ptr = 0;
  z->a = 0xFF;
  z->b = z->c = z->d = z->e = z->h = z->l = 0;
  z->a_ = z->b_ = z->c_ = z->d_ = z->e_ = z->h_ = z->l_ = z->f_ = 0;
  z->i = 0;
  z->r = 0;
  z->f = 0xFF;
  z->iff_delay = 0;
  z->interrupt_mode = 0;
  z->events = 0;
  z->ev_mask = 0;
  z->iff1 = 0;                      // set_iff1(z, 0)
  z->evm_int = z->evm_line = 0;
  z->iff2 = 0;
  z->halted = 0;
  z->int_pending = 0;
  z->nmi_pending = 0;
  z->int_data = 0;
}

void n64z80_gen_int(z80* z, uint8_t data) {
  z->int_pending = 1;
  z->int_data = data;
}

void n64z80_gen_nmi(z80* z) { z->nmi_pending = 1; }
