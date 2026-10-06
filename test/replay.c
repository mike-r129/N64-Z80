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

#ifdef N64
static uint32_t now32(void) { return TICKS_READ(); }
#else
static uint32_t now32(void) { return 0; }
#endif

static const zcore* core;
static z80* cpu;
static const uint8_t *rom, *buf, *t, *tend;   // t = trace cursor
static uint8_t ram[0x800] __attribute__((aligned(16)));
static uint32_t bank_off[4];
static const uint32_t win_base[4] = { 0x8000, 0xC000, 0xE000, 0xF000 };
static const uint32_t win_size[4] = { 0x4000, 0x2000, 0x1000, 0x0800 };
static uintptr_t rmap[256], wmap[256];
static replay_result res;
static int maxbad;

static void fail(const char* what) {
  if (res.bad++ < maxbad)
    tlog("    MISMATCH at trace offset %ld: %s (pc=%04x cyc=%lu)\n", (long)(t - buf), what,
         cpu->pc, (unsigned long)cpu->cyc);
}

static void map_fill(unsigned lo, unsigned hi, const uint8_t* base) {
  for (unsigned p = lo; p < hi; p++) rmap[p] = (uintptr_t)base - ((uintptr_t)lo << 8);
}
static void map_window(int w) {
  map_fill(win_base[w] >> 8, (win_base[w] + win_size[w]) >> 8, rom + bank_off[w]);
}

static uint8_t rd(void* ud, uint16_t a) { (void)ud; return *(const uint8_t*)(rmap[a >> 8] + a); }
static void wr(void* ud, uint16_t a, uint8_t v) {
  (void)ud;
  if (a >= 0xF800) ram[a - 0xF800] = v;
  cpu->wrote = 1;
}

static void apply_irq(uint8_t level) {
  cpu->irq_line = level;
  if (level) core->gen_int(cpu, 0xFF); else cpu->int_pending = 0;
}

// Apply the IRQ/BANK effect records that follow a callback record.
static void effects(void) {
  while (t < tend && (*t == Z80T_IRQ || *t == Z80T_BANK)) {
    if (*t == Z80T_IRQ) { apply_irq(t[1]); t += 2; }
    else { bank_off[t[1] & 3] = z80t_get32(t + 2); map_window(t[1] & 3); t += 6; }
  }
}

static int port_rec(uint8_t type, uint16_t port, uint8_t* val) {
  if (t >= tend || *t != type) { fail(type == Z80T_IN ? "expected IN record" : "expected OUT record"); return 0; }
  if (z80t_get16(t + 1) != port) fail("port address differs");
  if (z80t_get32(t + 4) != (uint32_t)cpu->cyc) fail("callback cycle stamp differs");
  if (type == Z80T_OUT && t[3] != *val) fail("OUT value differs");
  *val = t[3];
  t += 8; res.io++;
  return 1;
}
static uint8_t pin(z80* z, uint16_t port) {
  (void)z; uint8_t v = 0;
  if (port_rec(Z80T_IN, port, &v)) effects();
  return v;
}
static void pout(z80* z, uint16_t port, uint8_t val) {
  (void)z;
  cpu->wrote = 1;
  if (port_rec(Z80T_OUT, port, &val)) effects();
}

replay_result replay(const zcore* c, const uint8_t* trace, size_t len, int maxprint) {
  memset(&res, 0, sizeof res);
  core = c; cpu = c->cpu; maxbad = maxprint;
  buf = t = trace; tend = trace + len;
  if (len < 12 + Z80T_STATE_SIZE + 0x800 + 20 || memcmp(t, Z80T_MAGIC, 8) ||
      z80t_get32(t + 8) != Z80T_VERSION) {
    tlog("    bad trace header\n");
    res.bad = 1;
    return res;
  }
  t += 12;
  core->init(cpu);
  z80t_state_load(cpu, t); t += Z80T_STATE_SIZE;
  memcpy(ram, t, 0x800); t += 0x800;
  for (int w = 0; w < 4; w++) { bank_off[w] = z80t_get32(t); t += 4; }
  uint32_t rom_size = z80t_get32(t); t += 4;
  rom = t; t += rom_size;
  map_fill(0x00, 0x80, rom);
  for (int w = 0; w < 4; w++) map_window(w);
  map_fill(0xF8, 0x100, ram);
  cpu->rmap = rmap; cpu->read_byte = rd; cpu->write_byte = wr;
  cpu->port_in = pin; cpu->port_out = pout; cpu->userdata = NULL;
  if (core->set_wmap) {
    for (int p = 0; p < 256; p++) wmap[p] = p >= 0xF8 ? (uintptr_t)ram - 0xF800 : 0;
    core->set_wmap(wmap);
  }

  while (t < tend && !res.ended) {
    uint8_t type = *t++;
    switch (type) {
    case Z80T_RUN: {
      unsigned long until = z80t_get32(t); t += 4;
      uint16_t last_pc;
      uint32_t t0 = now32();
      unsigned n = core->run(cpu, until, &last_pc);
      res.ticks += (uint32_t)(now32() - t0);
      if (t >= tend || *t != Z80T_RUN_END) { fail("expected RUN_END (callback records left over?)"); goto out; }
      if (z80t_get32(t + 1) != n) fail("RUN step count differs");
      if (z80t_get16(t + 5) != last_pc) fail("RUN last_pc differs");
      if (z80t_get32(t + 7) != z80t_state_hash(cpu)) fail("RUN end-state hash differs");
      t += 11; res.runs++; res.steps += n;
    } break;
    case Z80T_STEP: {
      uint32_t t0 = now32();
      core->step(cpu);
      res.ticks += (uint32_t)(now32() - t0);
      if (t >= tend || *t != Z80T_STEP_END) { fail("expected STEP_END"); goto out; }
      if (z80t_get32(t + 1) != z80t_state_hash(cpu)) fail("STEP end-state hash differs");
      t += 5; res.steps++;
    } break;
    case Z80T_IRQ: apply_irq(*t++); break;
    case Z80T_GENINT: core->gen_int(cpu, *t++); break;
    case Z80T_NMI: core->gen_nmi(cpu); break;
    case Z80T_SETCYC: cpu->cyc = z80t_get32(t); t += 4; break;
    case Z80T_SETR: cpu->r = *t++; break;
    case Z80T_BANK: bank_off[t[0] & 3] = z80t_get32(t + 1); map_window(t[0] & 3); t += 5; break;
    case Z80T_RAMCRC:
      if (z80t_get32(t) != z80t_crc32(ram, 0x800)) fail("RAM CRC differs");
      t += 4; break;
    case Z80T_END: {
      uint8_t s[Z80T_STATE_SIZE];
      z80t_state_save(cpu, s);
      if (memcmp(s, t, Z80T_STATE_SIZE)) fail("END state differs");
      if (memcmp(ram, t + Z80T_STATE_SIZE, 0x800)) fail("END RAM differs");
      t += Z80T_STATE_SIZE + 0x800; res.ended = 1;
    } break;
    default:
      t--;
      fail("unknown or misplaced record");
      goto out;
    }
  }
out:
  if (core->set_wmap) core->set_wmap(NULL);
  return res;
}
