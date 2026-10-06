// One core wrapper. Compiled once per core with -DPFX=<name> and the core's
// source directory first on the include path (reference/, or a mutant copy
// in build/). The core's public symbols are renamed to <PFX>_* so several
// copies link side by side; everything else in z80.c is static. With
// -DZCORE_ASM it wraps the asm core (n64z80.h) instead.
//
// Port of seed/harness/zdiff/wrap.c, plus the zcore descriptor and dirty-page
// tracking (the N64 harness restores and compares only touched pages).
#include <string.h>
#include <stdio.h>

// The reference reports undefined opcodes on stderr, which on N64 is the
// ISViewer log; random code hits them constantly. (stdio.h is included
// first, so its fprintf declaration is not affected.)
#define fprintf(...) ((void)0)

#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)

#ifdef ZCORE_ASM
// The asm core (n64z80.h), which takes any owner struct.
#include "n64z80.h"
static z80 asm_cpu;
#define CPU         asm_cpu
#define z80_init    n64z80_init
#define z80_step    n64z80_step
#define z80_run     n64z80_run
#define z80_gen_int n64z80_gen_int
#define z80_gen_nmi n64z80_gen_nmi
#else
#define z80_hot          CAT(PFX, _z80_hot)
#define z80_init         CAT(PFX, _z80_init)
#define z80_step         CAT(PFX, _z80_step)
#define z80_run          CAT(PFX, _z80_run)
#define z80_gen_int      CAT(PFX, _z80_gen_int)
#define z80_gen_nmi      CAT(PFX, _z80_gen_nmi)
#define z80_debug_output CAT(PFX, _z80_debug_output)
#include "z80.c"
#define CPU z80_hot.cpu
#endif
#include "zcore.h"

static Run* cur;
static uintptr_t map[256];

static void ev(int kind, uint16_t addr, uint8_t val) {
  if (cur->nev < ZD_EV_MAX) {
    Ev* e = &cur->ev[cur->nev];
    e->kind = kind; e->addr = addr; e->val = val; e->cyc = (uint32_t)CPU.cyc;
  }
  cur->nev++;
}

static void wbcb(void* ud, uint16_t addr, uint8_t val) {
  (void)ud;
  cur->mem[addr] = val;
  cur->dirty[addr >> 8] = 1;
  CPU.wrote = 1;
  ev(1, addr, val);
}

static uint8_t rbcb(void* ud, uint16_t addr) { (void)ud; return cur->mem[addr]; }

// The value depends on the port, the number of IN calls and the cycle stamp,
// never on the number of logged events (those differ in direct-write mode).
static uint8_t incb(z80* z, uint16_t port) {
  (void)z;
  uint8_t v = (uint8_t)(port * 7 + cur->nin++ * 13 + (CPU.cyc & 0xff));
  ev(3, port, v);
  return v;
}

static void outcb(z80* z, uint16_t port, uint8_t val) {
  (void)z;
  CPU.wrote = 1;
  ev(2, port, val);
}

static void diff_run(Run* r, uint32_t until) {
  z80* z = &CPU;
  cur = r;
  for (int i = 0; i < 256; i++) map[i] = (uintptr_t)r->mem;
  z->rmap = map; z->read_byte = rbcb; z->write_byte = wbcb;
  z->port_in = incb; z->port_out = outcb; z->userdata = 0;
  St* s = &r->st;
  z->pc = s->pc; z->sp = s->sp; z->ix = s->ix; z->iy = s->iy; z->mem_ptr = s->mem_ptr;
  z->a = s->a; z->f = s->f; z->b = s->b; z->c = s->c; z->d = s->d; z->e = s->e; z->h = s->h; z->l = s->l;
  z->a_ = s->a_; z->f_ = s->f_; z->b_ = s->b_; z->c_ = s->c_; z->d_ = s->d_; z->e_ = s->e_; z->h_ = s->h_; z->l_ = s->l_;
  z->i = s->i; z->r = s->r; z->iff_delay = s->iff_delay; z->interrupt_mode = s->im; z->int_data = s->int_data;
  z->iff1 = s->iff1; z->iff2 = s->iff2; z->halted = s->halted;
  z->int_pending = s->int_pending; z->nmi_pending = s->nmi_pending;
  z->irq_line = s->irq_line; z->wrote = s->wrote; z->wrote_any = s->wrote_any;
  z->cyc = s->cyc; z->irq_redeliver = s->irq_redeliver;
  r->nsteps = z80_run(z, until, &r->last_pc);
  s->pc = z->pc; s->sp = z->sp; s->ix = z->ix; s->iy = z->iy; s->mem_ptr = z->mem_ptr;
  s->a = z->a; s->f = z->f; s->b = z->b; s->c = z->c; s->d = z->d; s->e = z->e; s->h = z->h; s->l = z->l;
  s->a_ = z->a_; s->f_ = z->f_; s->b_ = z->b_; s->c_ = z->c_; s->d_ = z->d_; s->e_ = z->e_; s->h_ = z->h_; s->l_ = z->l_;
  s->i = z->i; s->r = z->r; s->iff_delay = z->iff_delay; s->im = z->interrupt_mode; s->int_data = z->int_data;
  s->iff1 = z->iff1; s->iff2 = z->iff2; s->halted = z->halted;
  s->int_pending = z->int_pending; s->nmi_pending = z->nmi_pending;
  s->irq_line = z->irq_line; s->wrote = z->wrote; s->wrote_any = z->wrote_any;
  s->cyc = (uint32_t)z->cyc; s->irq_redeliver = (uint32_t)z->irq_redeliver;
}

#define STR2(x) #x
#define STR(x) STR2(x)
const zcore CAT(PFX, _core) = {
  .name = STR(PFX),
  .cpu = &CPU,
  .init = z80_init,
  .step = z80_step,
  .run = z80_run,
  .gen_int = z80_gen_int,
  .gen_nmi = z80_gen_nmi,
  .diff_run = diff_run,
};
