// Differential test: REF (reference core) vs NEW (candidate) on random states.
// Each case: random registers/flags/interrupt state, random 64 KB memory with
// a prefix-biased opcode stream at PC, then z80_run with a random budget
// (1 cycle = exactly one instruction, or up to 400 cycles). Compares the full
// state, every bus event (kind, address, value, cycle stamp), the memory
// image, the step count and last_pc.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "zdiff.h"
void REF_run(Run*, uint32_t);
void NEW_run(Run*, uint32_t);
static uint64_t rs = 88172645463325252ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)rs; }
static uint8_t m0[65536], m1[65536], m2[65536];
static void dump(const char* n, const St* s) {
  printf("  %s pc=%04x sp=%04x af=%02x%02x bc=%02x%02x de=%02x%02x hl=%02x%02x ix=%04x iy=%04x wz=%04x"
         " i=%02x r=%02x cyc=%u iff=%d%d dly=%d im=%d halt=%d intp=%d nmip=%d line=%d wr=%d/%d redel=%u\n",
    n, s->pc, s->sp, s->a, s->f, s->b, s->c, s->d, s->e, s->h, s->l, s->ix, s->iy, s->mem_ptr, s->i, s->r,
    s->cyc, s->iff1, s->iff2, s->iff_delay, s->im, s->halted, s->int_pending, s->nmi_pending, s->irq_line,
    s->wrote, s->wrote_any, s->irq_redeliver);
}
int main(int argc, char** argv) {
  long N = argc > 1 ? atol(argv[1]) : 1000000;
  if (argc > 2) rs ^= strtoull(argv[2], 0, 0) * 0x9E3779B97F4A7C15ull;
  static Run a, b;
  long bad = 0;
  for (long n = 0; n < N; n++) {
    for (int i = 0; i < 65536; i += 4) { uint32_t v = rnd(); memcpy(&m0[i], &v, 4); }
    St s;
    memset(&s, 0, sizeof s);
    uint8_t* p = (uint8_t*)&s;
    for (size_t i = 0; i < offsetof(St, iff_delay); i++) p[i] = rnd();
    uint32_t k = rnd();
    s.iff1 = k & 1; s.iff2 = (k >> 1) & 1; s.im = (k >> 2) % 3; s.halted = ((k >> 4) & 15) == 0;
    s.int_pending = ((k >> 8) & 7) == 0; s.nmi_pending = ((k >> 11) & 15) == 0;
    s.irq_line = ((k >> 15) & 7) == 0; s.iff_delay = ((k >> 18) & 7) == 0; s.int_data = 0xFF;
    s.cyc = rnd(); s.irq_redeliver = rnd() & 0xff;
    // Opcode stream at PC: prefixes and the DD/FD CB forms more often.
    static const uint8_t pre[] = { 0xDD, 0xFD, 0xCB, 0xED };
    uint16_t pc = s.pc;
    for (int i = 0; i < 4; i++) if ((rnd() & 3) == 0) m0[(uint16_t)(pc + i)] = pre[rnd() & 3];
    if ((rnd() & 7) == 0) { m0[pc] = 0xDD | (rnd() & 0x20); m0[(uint16_t)(pc + 1)] = 0xCB; }
    uint32_t until = s.cyc + ((rnd() & 1) ? 1 : 1 + rnd() % 400);
    memcpy(m1, m0, sizeof m0); memcpy(m2, m0, sizeof m0);
    memset(&a, 0, sizeof a); memset(&b, 0, sizeof b);
    a.st = s; b.st = s; a.mem = m1; b.mem = m2;
    REF_run(&a, until);
    NEW_run(&b, until);
    if (getenv("ZD_DIRECT")) {   // NEW stores these pages directly: no events
      for (Run* r = &a; r; r = r == &a ? &b : NULL) {
        int k = 0;
        for (int i = 0; i < r->nev; i++)
          if (!(r->ev[i].kind == 1 && ((r->ev[i].addr >> 8) >= 0xF8 ||
                ((r->ev[i].addr >> 8) >= 0x40 && (r->ev[i].addr >> 8) < 0x60))))
            r->ev[k++] = r->ev[i];
        r->nev = k;
      }
    }
    int memd = memcmp(m1, m2, sizeof m1) != 0;
    int diff = memcmp(&a.st, &b.st, sizeof a.st) || a.nev != b.nev ||
               memcmp(a.ev, b.ev, sizeof(Ev) * a.nev) || a.nsteps != b.nsteps ||
               a.last_pc != b.last_pc || memd;
    if (diff) {
      if (bad < 8) {
        printf("case %ld: bytes at pc %02x %02x %02x %02x %02x, until=+%u, steps %u/%u last_pc %04x/%04x ev %d/%d mem %s\n",
          n, m0[pc], m0[(uint16_t)(pc + 1)], m0[(uint16_t)(pc + 2)], m0[(uint16_t)(pc + 3)],
          m0[(uint16_t)(pc + 4)], until - s.cyc, a.nsteps, b.nsteps, a.last_pc, b.last_pc, a.nev, b.nev,
          memd ? "DIFF" : "same");
        dump("in ", &s); dump("ref", &a.st); dump("new", &b.st);
        for (int i = 0; i < a.nev || i < b.nev; i++)
          printf("    ev%d ref %d %04x %02x @%u | new %d %04x %02x @%u\n", i, a.ev[i].kind, a.ev[i].addr,
                 a.ev[i].val, a.ev[i].cyc, b.ev[i].kind, b.ev[i].addr, b.ev[i].val, b.ev[i].cyc);
      }
      bad++;
    }
  }
  printf("%ld cases, %ld mismatches\n", N, bad);
  return bad != 0;
}
