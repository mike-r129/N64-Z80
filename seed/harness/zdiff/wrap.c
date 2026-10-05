// One core wrapper: compiled once per core with -DPFX=<name>, everything but
// <PFX>_run hidden. Maps the neutral St onto the core's struct and runs
// z80_run(until) once.
#include <string.h>
#include "z80.c"
#include "zdiff.h"
#define CAT2(a, b) a##b
#define CAT(a, b) CAT2(a, b)
static Run* cur;
static uintptr_t map[256];
static void ev(int kind, uint16_t addr, uint8_t val) {
  if (cur->nev < 64) {
    Ev* e = &cur->ev[cur->nev++];
    e->kind = kind; e->addr = addr; e->val = val; e->cyc = (uint32_t)z80_hot.cpu.cyc;
  }
}
static void wbcb(void* ud, uint16_t addr, uint8_t val) {
  (void)ud; cur->mem[addr] = val; z80_hot.cpu.wrote = 1; ev(1, addr, val);
}
static uint8_t rbcb(void* ud, uint16_t addr) { (void)ud; return cur->mem[addr]; }
static uint8_t incb(z80* z, uint16_t port) {
  (void)z;
  uint8_t v = (uint8_t)(port * 7 + cur->nin++ * 13 + (z80_hot.cpu.cyc & 0xff));
  ev(3, port, v);
  return v;
}
static void outcb(z80* z, uint16_t port, uint8_t val) {
  (void)z; z80_hot.cpu.wrote = 1; ev(2, port, val);
}
__attribute__((visibility("default")))
void CAT(PFX, _run)(Run* r, uint32_t until) {
  z80* z = &z80_hot.cpu;
  cur = r;
  for (int i = 0; i < 256; i++) map[i] = (uintptr_t)r->mem;
  z->rmap = map; z->read_byte = rbcb; z->write_byte = wbcb;
  z->port_in = incb; z->port_out = outcb; z->userdata = 0;
#ifdef TEST_WDIRECT
  // Direct-write pages (see zd_direct in main.c): 0x40-0x5F and 0xF8-0xFF.
  memset(z->wdirect, 0, sizeof z->wdirect);
  z->wdirect[0x40 >> 5] = 0xFFFFFFFFu;
  z->wdirect[0xF8 >> 5] = 0xFFu << (0xF8 & 31);
#endif
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
