// Differential test, ported from seed/harness/zdiff/main.c.
//
// Each case: random registers, flags and interrupt/halt state, a random 64 KB
// image with a prefix-biased opcode stream at PC, then one z80_run with a
// random budget (1 cycle = exactly one instruction, or up to 400 cycles).
// Compares the full state, every bus event (kind, address, value, cycle
// stamp), the memory image, the step count and last_pc.
//
// N64 speed: copying and comparing 3 x 64 KB per case would cost several ms.
// Instead the base image m0 is refilled every ZD_REFILL cases, and after each
// case only the pages a core wrote (through write_byte, or any direct page)
// are compared and restored. A full-image compare at every refill catches a
// core that writes memory behind the harness's back.
#include <string.h>
#include "zdiff.h"
#include "tlog.h"

#define ZD_REFILL 256

static uint64_t rs;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)rs; }

static uint8_t m0[65536] __attribute__((aligned(16)));
static uint8_t m1[65536] __attribute__((aligned(16)));
static uint8_t m2[65536] __attribute__((aligned(16)));
static uint8_t a1[65536] __attribute__((aligned(16)));   // split-mode mirrors of m1, m2
static uint8_t a2[65536] __attribute__((aligned(16)));
static Run ra, rb;


static void dump(const char* n, const St* s) {
  tlog("  %s pc=%04x sp=%04x af=%02x%02x bc=%02x%02x de=%02x%02x hl=%02x%02x ix=%04x iy=%04x wz=%04x"
       " i=%02x r=%02x cyc=%lu iff=%d%d dly=%d im=%d halt=%d intp=%d nmip=%d line=%d wr=%d/%d redel=%lu\n",
       n, s->pc, s->sp, s->a, s->f, s->b, s->c, s->d, s->e, s->h, s->l, s->ix, s->iy, s->mem_ptr, s->i, s->r,
       (unsigned long)s->cyc, s->iff1, s->iff2, s->iff_delay, s->im, s->halted, s->int_pending, s->nmi_pending,
       s->irq_line, s->wrote, s->wrote_any, (unsigned long)s->irq_redeliver);
}

static void filter_direct(Run* r) {
  int n = r->nev < ZD_EV_MAX ? r->nev : ZD_EV_MAX, k = 0;
  for (int i = 0; i < n; i++)
    if (!(r->ev[i].kind == 1 && zd_direct_page(r->ev[i].addr >> 8))) r->ev[k++] = r->ev[i];
  r->nev = k + (r->nev - n);
}

static void poke(uint16_t addr, uint8_t v) { m0[addr] = m1[addr] = m2[addr] = a1[addr] = a2[addr] = v; }

// Image restore: m1, m2 (and their mirrors) from m0, the whole image or one page.
static void restore(unsigned from, unsigned len) {
  memcpy(&m1[from], &m0[from], len);
  memcpy(&m2[from], &m0[from], len);
  memcpy(&a1[from], &m0[from], len);
  memcpy(&a2[from], &m0[from], len);
}

// Replays a mismatching case one instruction at a time (each core from its
// own previous state, on fresh copies of the image) and prints the first
// instruction after which the cores disagree. Leaves m1 = m2 = m0.
static Run ba, bb;
static void bisect(const zcore* ref, const zcore* cand, const St* s0, uint32_t until, int direct,
                   int split) {
  restore(0, sizeof m0);
  St sa = *s0, sb = *s0;
  for (int k = 0; k < 500 && (int32_t)(until - sa.cyc) > 0; k++) {
    memset(&ba, 0, sizeof ba); memset(&bb, 0, sizeof bb);
    ba.st = sa; bb.st = sb; ba.mem = m1; bb.mem = m2; ba.direct = bb.direct = direct;
    ba.alt = a1; bb.alt = a2; ba.split = bb.split = split;
    uint16_t pc = sa.pc;
    ref->diff_run(&ba, sa.cyc + 1);
    cand->diff_run(&bb, sb.cyc + 1);
    if (direct) { filter_direct(&ba); filter_direct(&bb); }
    int nev = ba.nev < ZD_EV_MAX ? ba.nev : ZD_EV_MAX;
    if (memcmp(&ba.st, &bb.st, sizeof ba.st) || ba.nev != bb.nev ||
        memcmp(ba.ev, bb.ev, sizeof(Ev) * nev) || memcmp(m1, m2, sizeof m1)) {
      tlog("  first divergence: instruction %d at %04x, bytes %02x %02x %02x %02x\n", k, pc,
           m0[pc], m0[(uint16_t)(pc + 1)], m0[(uint16_t)(pc + 2)], m0[(uint16_t)(pc + 3)]);
      dump("before", &sa); dump("ref", &ba.st); dump("new", &bb.st);
      for (int i = 0; (i < ba.nev || i < bb.nev) && i < ZD_EV_MAX; i++)
        tlog("    ev%d ref %d %04x %02x @%lu | new %d %04x %02x @%lu\n", i,
             ba.ev[i].kind, ba.ev[i].addr, ba.ev[i].val, (unsigned long)ba.ev[i].cyc,
             bb.ev[i].kind, bb.ev[i].addr, bb.ev[i].val, (unsigned long)bb.ev[i].cyc);
      break;
    }
    sa = ba.st; sb = bb.st;
  }
  restore(0, sizeof m0);
}

long zdiff(const zcore* ref, const zcore* cand, const zdiff_cfg* cfg) {
  rs = 88172645463325252ull ^ (cfg->seed * 0x9E3779B97F4A7C15ull);
  long bad = 0;
  int overflow = 0;
  for (long n = 0; n < cfg->cases; n++) {
    if (n % ZD_REFILL == 0) {
      if (n && memcmp(m1, m2, sizeof m1)) {
        tlog("case %ld: memory images differ outside the tracked pages\n", n);
        bad++;
      }
      for (int i = 0; i < 65536; i += 4) { uint32_t v = rnd(); memcpy(&m0[i], &v, 4); }
      restore(0, sizeof m0);
    }
    St s;
    memset(&s, 0, sizeof s);
    uint8_t* p = (uint8_t*)&s;
    for (size_t i = 0; i < offsetof(St, iff_delay); i++) p[i] = rnd();
    uint32_t k = rnd();
    s.iff1 = k & 1; s.iff2 = (k >> 1) & 1; s.im = (k >> 2) % 3; s.halted = ((k >> 4) & 15) == 0;
    s.int_pending = ((k >> 8) & 7) == 0; s.nmi_pending = ((k >> 11) & 15) == 0;
    s.irq_line = ((k >> 15) & 7) == 0; s.iff_delay = ((k >> 18) & 7) == 0; s.int_data = 0xFF;
    s.cyc = rnd(); s.irq_redeliver = rnd() & 0xff;
    if (cfg->split && (rnd() & 1)) s.pc = (s.pc & 0xFF00) | (0xF9 + rnd() % 7);
    // Opcode stream at PC: prefixes and the DD/FD CB forms more often.
    static const uint8_t pre[] = { 0xDD, 0xFD, 0xCB, 0xED };
    uint16_t pc = s.pc;
    for (int i = 0; i < 4; i++) if ((rnd() & 3) == 0) poke(pc + i, pre[rnd() & 3]);
    if ((rnd() & 7) == 0) { poke(pc, 0xDD | (rnd() & 0x20)); poke(pc + 1, 0xCB); }
    uint8_t code[5];
    for (int i = 0; i < 5; i++) code[i] = m0[(uint16_t)(pc + i)];
    uint32_t until = s.cyc + ((rnd() & 1) ? 1 : 1 + rnd() % 400);

    memset(&ra, 0, sizeof ra); memset(&rb, 0, sizeof rb);
    ra.direct = rb.direct = cfg->direct;
    ra.split = rb.split = cfg->split; ra.alt = a1; rb.alt = a2;
    ra.st = s; rb.st = s; ra.mem = m1; rb.mem = m2;
    ref->diff_run(&ra, until);
    cand->diff_run(&rb, until);
    if (ra.nev > ZD_EV_MAX || rb.nev > ZD_EV_MAX) overflow++;
    if (cfg->direct) { filter_direct(&ra); filter_direct(&rb); }

    int memd = 0;
    for (int pg = 0; pg < 256; pg++) {
      if (!(ra.dirty[pg] | rb.dirty[pg] | (cfg->direct && zd_direct_page(pg)))) continue;
      if (memcmp(&m1[pg << 8], &m2[pg << 8], 256)) memd = 1;
      restore(pg << 8, 256);
    }
    int nev = ra.nev < ZD_EV_MAX ? ra.nev : ZD_EV_MAX;
    int diff = memcmp(&ra.st, &rb.st, sizeof ra.st) || ra.nev != rb.nev ||
               memcmp(ra.ev, rb.ev, sizeof(Ev) * nev) || ra.nsteps != rb.nsteps ||
               ra.last_pc != rb.last_pc || memd;
    if (diff) {
      if (bad < cfg->max_report) {
        tlog("case %ld: bytes at pc %02x %02x %02x %02x %02x, until=+%lu, steps %u/%u last_pc %04x/%04x ev %d/%d mem %s\n",
             n, code[0], code[1], code[2], code[3], code[4], (unsigned long)(until - s.cyc),
             ra.nsteps, rb.nsteps, ra.last_pc, rb.last_pc, ra.nev, rb.nev, memd ? "DIFF" : "same");
        dump("in ", &s); dump("ref", &ra.st); dump("new", &rb.st);
        for (int i = 0; (i < ra.nev || i < rb.nev) && i < ZD_EV_MAX; i++)
          tlog("    ev%d ref %d %04x %02x @%lu | new %d %04x %02x @%lu\n", i,
               ra.ev[i].kind, ra.ev[i].addr, ra.ev[i].val, (unsigned long)ra.ev[i].cyc,
               rb.ev[i].kind, rb.ev[i].addr, rb.ev[i].val, (unsigned long)rb.ev[i].cyc);
        bisect(ref, cand, &s, until, cfg->direct, cfg->split);
      }
      bad++;
    }
  }
  if (memcmp(m1, m2, sizeof m1)) {
    tlog("end: memory images differ outside the tracked pages\n");
    bad++;
  }
  if (overflow) tlog("warning: %d cases logged more than %d bus events\n", overflow, ZD_EV_MAX);
  return bad;
}
