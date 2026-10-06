// Trace replay: a port of mvs64's tools/z80replay.c onto the zcore
// interface. It behaves exactly as that reference owner:
//   - memory: fixed M1 ROM at 0x0000-0x7FFF, four banked windows (offsets
//     from the header / BANK records), 2 KB work RAM at 0xF800; writes below
//     0xF800 are ignored; every write and OUT sets cpu->wrote = 1; a core
//     with a write page map stores the work RAM directly (as mvs64 will);
//   - port_in returns the recorded value, port_out checks it; after either,
//     the IRQ/BANK records that follow are applied before the callback
//     returns;
//   - every RUN_END (steps, last_pc, state hash), STEP_END, IN/OUT (port,
//     value, cycle stamp), RAM CRC and the END state + RAM are checked.
#include <string.h>
#include "replay.h"
#include "z80trace.h"
#include "tlog.h"

// test/icache_pad.S: fixes this file's icache position (kept by the
// references below past --gc-sections).
extern const char replay_icache_pad0[], replay_icache_pad1[];

#ifdef N64
static uint32_t now32(void) { return TICKS_READ(); }
#else
static uint32_t now32(void) { return 0; }
#endif

static const uint32_t win_base[4] = { 0x8000, 0xC000, 0xE000, 0xF000 };
static const uint32_t win_size[4] = { 0x4000, 0x2000, 0x1000, 0x0800 };
// The owner data the core touches on every instruction, at a fixed dcache
// position: sets 0xA40 up, clear of the core's hot tables (n64z80_asm.S,
// N64Z80_DCACHE_ALIGN), as recommended for mvs64. The replay's own state,
// touched on every run and port callback, follows in the free sets after
// wmap, so no build's data layout moves the trace timings.
static struct {
  uint8_t pad[0xA40];
  uint8_t ram[0x800];
  uintptr_t rmap[256], wmap[256];
  const zcore* core;
  z80* cpu;
  const uint8_t *rom, *buf, *t, *tend;   // t = trace cursor
  uint32_t bank_off[4];
  replay_result res;
  int maxbad;
} hot __attribute__((aligned(8192)));

static void fail(const char* what) {
  if (hot.res.bad++ < hot.maxbad)
    tlog("    MISMATCH at trace offset %ld: %s (pc=%04x cyc=%lu)\n", (long)(hot.t - hot.buf), what,
         hot.cpu->pc, (unsigned long)hot.cpu->cyc);
}

static void map_fill(unsigned lo, unsigned hi, const uint8_t* base) {
  for (unsigned p = lo; p < hi; p++) hot.rmap[p] = (uintptr_t)base - ((uintptr_t)lo << 8);
}
static void map_window(int w) {
  map_fill(win_base[w] >> 8, (win_base[w] + win_size[w]) >> 8, hot.rom + hot.bank_off[w]);
}

static uint8_t rd(void* ud, uint16_t a) { (void)ud; return *(const uint8_t*)(hot.rmap[a >> 8] + a); }
static void wr(void* ud, uint16_t a, uint8_t v) {
  (void)ud;
  if (a >= 0xF800) hot.ram[a - 0xF800] = v;
  hot.cpu->wrote = 1;
}

static void apply_irq(uint8_t level) {
  hot.cpu->irq_line = level;
  if (level) hot.core->gen_int(hot.cpu, 0xFF); else hot.cpu->int_pending = 0;
}

// Apply the IRQ/BANK effect records that follow a callback record.
static void effects(void) {
  while (hot.t < hot.tend && (*hot.t == Z80T_IRQ || *hot.t == Z80T_BANK)) {
    if (*hot.t == Z80T_IRQ) { apply_irq(hot.t[1]); hot.t += 2; }
    else { hot.bank_off[hot.t[1] & 3] = z80t_get32(hot.t + 2); map_window(hot.t[1] & 3); hot.t += 6; }
  }
}

static int port_rec(uint8_t type, uint16_t port, uint8_t* val) {
  if (hot.t >= hot.tend || *hot.t != type) { fail(type == Z80T_IN ? "expected IN record" : "expected OUT record"); return 0; }
  if (z80t_get16(hot.t + 1) != port) fail("port address differs");
  if (z80t_get32(hot.t + 4) != (uint32_t)hot.cpu->cyc) fail("callback cycle stamp differs");
  if (type == Z80T_OUT && hot.t[3] != *val) fail("OUT value differs");
  *val = hot.t[3];
  hot.t += 8; hot.res.io++;
  return 1;
}
static uint8_t pin(z80* z, uint16_t port) {
  (void)z; uint8_t v = 0;
  if (port_rec(Z80T_IN, port, &v)) effects();
  return v;
}
static void pout(z80* z, uint16_t port, uint8_t val) {
  (void)z;
  hot.cpu->wrote = 1;
  if (port_rec(Z80T_OUT, port, &val)) effects();
}

replay_result replay(const zcore* c, const uint8_t* trace, size_t len, int maxprint) {
  __asm__ volatile("" :: "r"(replay_icache_pad0), "r"(replay_icache_pad1));
  memset(&hot.res, 0, sizeof hot.res);
  hot.core = c; hot.cpu = c->cpu; hot.maxbad = maxprint;
  hot.buf = hot.t = trace; hot.tend = trace + len;
  if (len < 12 + Z80T_STATE_SIZE + 0x800 + 20 || memcmp(hot.t, Z80T_MAGIC, 8) ||
      z80t_get32(hot.t + 8) != Z80T_VERSION) {
    tlog("    bad trace header\n");
    hot.res.bad = 1;
    return hot.res;
  }
  hot.t += 12;
  hot.core->init(hot.cpu);
  z80t_state_load(hot.cpu, hot.t); hot.t += Z80T_STATE_SIZE;
  memcpy(hot.ram, hot.t, 0x800); hot.t += 0x800;
  for (int w = 0; w < 4; w++) { hot.bank_off[w] = z80t_get32(hot.t); hot.t += 4; }
  uint32_t rom_size = z80t_get32(hot.t); hot.t += 4;
  hot.rom = hot.t; hot.t += rom_size;
  map_fill(0x00, 0x80, hot.rom);
  for (int w = 0; w < 4; w++) map_window(w);
  map_fill(0xF8, 0x100, hot.ram);
  hot.cpu->rmap = hot.rmap; hot.cpu->read_byte = rd; hot.cpu->write_byte = wr;
  hot.cpu->port_in = pin; hot.cpu->port_out = pout; hot.cpu->userdata = NULL;
  if (hot.core->set_wmap) {
    for (int p = 0; p < 256; p++) hot.wmap[p] = p >= 0xF8 ? (uintptr_t)hot.ram - 0xF800 : 0;
    hot.core->set_wmap(hot.wmap);
  }

  while (hot.t < hot.tend && !hot.res.ended) {
    uint8_t type = *hot.t++;
    switch (type) {
    case Z80T_RUN: {
      unsigned long until = z80t_get32(hot.t); hot.t += 4;
      uint16_t last_pc;
      uint32_t t0 = now32();
      unsigned n = hot.core->run(hot.cpu, until, &last_pc);
      hot.res.ticks += (uint32_t)(now32() - t0);
      if (hot.t >= hot.tend || *hot.t != Z80T_RUN_END) { fail("expected RUN_END (callback records left over?)"); goto out; }
      if (z80t_get32(hot.t + 1) != n) fail("RUN step count differs");
      if (z80t_get16(hot.t + 5) != last_pc) fail("RUN last_pc differs");
      if (z80t_get32(hot.t + 7) != z80t_state_hash(hot.cpu)) fail("RUN end-state hash differs");
      hot.t += 11; hot.res.runs++; hot.res.steps += n;
    } break;
    case Z80T_STEP: {
      uint32_t t0 = now32();
      hot.core->step(hot.cpu);
      hot.res.ticks += (uint32_t)(now32() - t0);
      if (hot.t >= hot.tend || *hot.t != Z80T_STEP_END) { fail("expected STEP_END"); goto out; }
      if (z80t_get32(hot.t + 1) != z80t_state_hash(hot.cpu)) fail("STEP end-state hash differs");
      hot.t += 5; hot.res.steps++;
    } break;
    case Z80T_IRQ: apply_irq(*hot.t++); break;
    case Z80T_GENINT: hot.core->gen_int(hot.cpu, *hot.t++); break;
    case Z80T_NMI: hot.core->gen_nmi(hot.cpu); break;
    case Z80T_SETCYC: hot.cpu->cyc = z80t_get32(hot.t); hot.t += 4; break;
    case Z80T_SETR: hot.cpu->r = *hot.t++; break;
    case Z80T_BANK: hot.bank_off[hot.t[0] & 3] = z80t_get32(hot.t + 1); map_window(hot.t[0] & 3); hot.t += 5; break;
    case Z80T_RAMCRC:
      if (z80t_get32(hot.t) != z80t_crc32(hot.ram, 0x800)) fail("RAM CRC differs");
      hot.t += 4; break;
    case Z80T_END: {
      uint8_t s[Z80T_STATE_SIZE];
      z80t_state_save(hot.cpu, s);
      if (memcmp(s, hot.t, Z80T_STATE_SIZE)) fail("END state differs");
      if (memcmp(hot.ram, hot.t + Z80T_STATE_SIZE, 0x800)) fail("END RAM differs");
      hot.t += Z80T_STATE_SIZE + 0x800; hot.res.ended = 1;
    } break;
    default:
      hot.t--;
      fail("unknown or misplaced record");
      goto out;
    }
  }
out:
  if (hot.core->set_wmap) hot.core->set_wmap(NULL);
  return hot.res;
}
