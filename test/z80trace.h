// Z80 owner trace format (MVS64_Z80TRACE): a recording of everything the
// sound owner (sound_neogeo.c) does to the Z80 core over a stretch of real
// game audio, so another core can replay it exactly and be checked against
// every recorded result. Shared by the recorder (sound_neogeo.c, PC build)
// and replay tools; it only needs the z80 struct's field names, so any core
// with mvs64's z80.h API can use it. Full description:
// tools/z80trace-format.md.
#ifndef Z80TRACE_H
#define Z80TRACE_H

#include <stdint.h>
#include <string.h>
#include "z80.h"

#define Z80T_MAGIC   "MVS64ZT1"   // 8 bytes, no terminator
#define Z80T_VERSION 1

// Record types. Every record is one type byte followed by a fixed payload;
// all multi-byte fields are little-endian.
enum {
  Z80T_RUN      = 0x01,  // u32 until                      -> z80_run(until)
  Z80T_RUN_END  = 0x02,  // u32 nsteps, u16 last_pc, u32 state hash
  Z80T_STEP     = 0x03,  // (none)                          -> z80_step()
  Z80T_STEP_END = 0x04,  // u32 state hash
  Z80T_IN       = 0x10,  // u16 port, u8 value, u32 cyc    (port_in callback)
  Z80T_OUT      = 0x11,  // u16 port, u8 value, u32 cyc    (port_out callback)
  Z80T_IRQ      = 0x20,  // u8 level  -> irq_line = level;
                         //              level ? z80_gen_int(0xFF) : int_pending = 0
  Z80T_GENINT   = 0x21,  // u8 data   -> z80_gen_int(data)
  Z80T_NMI      = 0x22,  // (none)    -> z80_gen_nmi()
  Z80T_SETCYC   = 0x23,  // u32 cyc   -> cyc = value (idle skip)
  Z80T_SETR     = 0x24,  // u8 r      -> r = value (idle skip)
  Z80T_BANK     = 0x25,  // u8 window (0=0x8000 16K, 1=0xC000 8K, 2=0xE000 4K,
                         //  3=0xF000 2K), u32 offset into the M1 ROM
  Z80T_RAMCRC   = 0x30,  // u32 CRC-32 of the 2 KB work RAM at this point
  Z80T_END      = 0x7F,  // state block (Z80T_STATE_SIZE) + 2 KB RAM
};

// The CPU state block: a fixed serialization of every architectural field,
// used for the start state, the end state and (hashed) after every RUN/STEP.
//   u16 pc, sp, ix, iy, mem_ptr(WZ)                               10 bytes
//   u8  a, f, b, c, d, e, h, l, a_, f_, b_, c_, d_, e_, h_, l_, i, r  18
//   u8  interrupt_mode, int_data, iff1, iff2, iff_delay, halted,
//       int_pending, nmi_pending, irq_line, wrote, wrote_any           11
//   u32 cyc (low 32 bits)                                              4
#define Z80T_STATE_SIZE 43

static inline void z80t_put16(uint8_t* p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static inline void z80t_put32(uint8_t* p, uint32_t v) {
  p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}
static inline unsigned z80t_get16(const uint8_t* p) { return p[0] | (p[1] << 8); }
static inline uint32_t z80t_get32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static inline void z80t_state_save(const z80* z, uint8_t* s) {
  z80t_put16(s + 0, z->pc); z80t_put16(s + 2, z->sp); z80t_put16(s + 4, z->ix);
  z80t_put16(s + 6, z->iy); z80t_put16(s + 8, z->mem_ptr);
  const uint8_t r8[18] = { z->a, z->f, z->b, z->c, z->d, z->e, z->h, z->l,
    z->a_, z->f_, z->b_, z->c_, z->d_, z->e_, z->h_, z->l_, z->i, z->r };
  memcpy(s + 10, r8, 18);
  const uint8_t m8[11] = { z->interrupt_mode, z->int_data, z->iff1, z->iff2,
    z->iff_delay, z->halted, z->int_pending, z->nmi_pending, z->irq_line,
    z->wrote, z->wrote_any };
  memcpy(s + 28, m8, 11);
  z80t_put32(s + 39, (uint32_t)z->cyc);
}

// Loads a state block. Interrupt flags go through plain field stores, so a
// core with derived state (e.g. an event mask) must rebuild it on entry to
// z80_run, as mvs64's core does.
static inline void z80t_state_load(z80* z, const uint8_t* s) {
  z->pc = z80t_get16(s + 0); z->sp = z80t_get16(s + 2); z->ix = z80t_get16(s + 4);
  z->iy = z80t_get16(s + 6); z->mem_ptr = z80t_get16(s + 8);
  z->a = s[10]; z->f = s[11]; z->b = s[12]; z->c = s[13]; z->d = s[14];
  z->e = s[15]; z->h = s[16]; z->l = s[17]; z->a_ = s[18]; z->f_ = s[19];
  z->b_ = s[20]; z->c_ = s[21]; z->d_ = s[22]; z->e_ = s[23]; z->h_ = s[24];
  z->l_ = s[25]; z->i = s[26]; z->r = s[27];
  z->interrupt_mode = s[28]; z->int_data = s[29]; z->iff1 = s[30]; z->iff2 = s[31];
  z->iff_delay = s[32]; z->halted = s[33]; z->int_pending = s[34];
  z->nmi_pending = s[35]; z->irq_line = s[36]; z->wrote = s[37]; z->wrote_any = s[38];
  z->cyc = z80t_get32(s + 39);
}

// FNV-1a 32 over the state block.
static inline uint32_t z80t_state_hash(const z80* z) {
  uint8_t s[Z80T_STATE_SIZE];
  z80t_state_save(z, s);
  uint32_t h = 2166136261u;
  for (int i = 0; i < Z80T_STATE_SIZE; i++) h = (h ^ s[i]) * 16777619u;
  return h;
}

// CRC-32 (IEEE, reflected, as zlib) for RAM checkpoints.
static inline uint32_t z80t_crc32(const uint8_t* p, unsigned n) {
  uint32_t c = 0xFFFFFFFFu;
  while (n--) {
    c ^= *p++;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
  }
  return ~c;
}

#endif
